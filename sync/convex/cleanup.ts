import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { LIMITS } from "./model";

/** `keyId` of rows that no key opens (tombstones and cleared rows of an account without a key). */
export const NO_KEY = "0".repeat(32);

/**
 * Moves a library's expiry forward because one of its devices was just seen. Writes at most once per
 * `LIMITS.libraryRefreshMs`, so heartbeats don't rewrite the library row every 30 s.
 */
export async function touchLibrary(ctx: MutationCtx, libraryId: Id<"libraries">, now: number): Promise<void> {
  const library = await ctx.db.get(libraryId);
  if (library === null) return;
  const target = now + LIMITS.libraryIdleTtlMs;
  if (library.expiresAt === undefined || target - library.expiresAt >= LIMITS.libraryRefreshMs) {
    await ctx.db.patch(library._id, { expiresAt: target });
  }
}

/**
 * Moves the library's `keyRevision` on. Every mutation that changes the account's key state calls it (in the same
 * transaction, so a reader sees the new revision exactly when it sees the change). Calling it for a change that
 * turns out to change nothing is harmless: the revision only has to grow, not count.
 */
export async function bumpKeyRevision(ctx: MutationCtx, libraryId: Id<"libraries">): Promise<void> {
  const library = await ctx.db.get(libraryId);
  if (library === null) return;
  await ctx.db.patch(library._id, { keyRevision: (library.keyRevision ?? 0) + 1 });
}

/** The library's retired fingerprints with `keyId` added (newest last, bounded). */
export function retiredWith(library: Doc<"libraries">, keyId: string | undefined): string[] | undefined {
  if (keyId === undefined) return library.retiredKeyIds;
  const kept = (library.retiredKeyIds ?? []).filter((k) => k !== keyId);
  return [...kept, keyId].slice(-LIMITS.maxRetiredKeys);
}

export function isRetired(library: Doc<"libraries">, keyId: string): boolean {
  return (library.retiredKeyIds ?? []).includes(keyId);
}

/** The record that refuses `tokenHash` for `owner` (`cancelledRegistrations`), if there is one. */
export async function refusalOf(ctx: MutationCtx, tokenHash: string, owner: string): Promise<Doc<"cancelledRegistrations"> | null> {
  return await ctx.db
    .query("cancelledRegistrations")
    .withIndex("by_tokenHash_owner", (q) => q.eq("tokenHash", tokenHash).eq("owner", owner))
    .first();
}

/**
 * Records that a device token whose device is gone never registers again for its user (`retired`). A device token is
 * single-use for its lifetime: every path that deletes a device calls this in the same transaction (`deleteDevice`,
 * and `retireLibrary` for the devices a retired library still has), so a copy of its registration that arrives later
 * is refused instead of creating a device nobody has the token or key of. Never limited: there is one record per
 * device the user ever registered, which the registration rate limit bounds. A withdrawal of the same token becomes a
 * retirement, kept for the full time from now.
 */
export async function retireToken(ctx: MutationCtx, retired: { tokenHash: string; owner: string; now: number }): Promise<void> {
  const expiresAt = retired.now + LIMITS.cancelledRegistrationTtlMs;
  const existing = await refusalOf(ctx, retired.tokenHash, retired.owner);
  if (existing !== null) {
    await ctx.db.patch(existing._id, { reason: "retired", expiresAt: Math.max(existing.expiresAt, expiresAt) });
    return;
  }
  await ctx.db.insert("cancelledRegistrations", {
    tokenHash: retired.tokenHash,
    owner: retired.owner,
    reason: "retired",
    createdAt: retired.now,
    expiresAt,
  });
}

/**
 * Deletes a device with its playback, queue, commands and key row, and retires its token (`retireToken`). The last
 * device out takes the library along (`retireLibrary`). A device that could open the vault leaving makes the
 * remaining holders replace the key, or, when it was the last one able to open it, resets the vault key (see
 * `afterDeviceLeft`).
 */
export async function deleteDevice(ctx: MutationCtx, deviceId: Id<"devices">, libraryId: Id<"libraries">): Promise<void> {
  const [device, library] = await Promise.all([ctx.db.get(deviceId), ctx.db.get(libraryId)]);
  if (device !== null && library?.owner !== undefined) {
    await retireToken(ctx, { tokenHash: device.tokenHash, owner: library.owner, now: Date.now() });
  }
  const rows = await Promise.all([
    ctx.db.query("playback").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).collect(),
    ctx.db.query("queues").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).collect(),
    ctx.db.query("commands").withIndex("by_to_pending", (q) => q.eq("toDeviceId", deviceId)).collect(),
    ctx.db.query("commands").withIndex("by_from", (q) => q.eq("fromDeviceId", deviceId)).collect(),
  ]);
  const keys = await ctx.db.query("deviceKeys").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).collect();
  for (const row of [...rows.flat(), ...keys]) await ctx.db.delete(row._id);
  await ctx.db.delete(deviceId);

  const remaining = await ctx.db
    .query("devices")
    .withIndex("by_library", (q) => q.eq("libraryId", libraryId))
    .first();
  if (remaining === null) {
    await retireLibrary(ctx, libraryId);
    return;
  }
  await afterDeviceLeft(ctx, { libraryId, deviceId, key: keys[0] ?? null, now: Date.now() });
  await bumpKeyRevision(ctx, libraryId);
}

/**
 * A device that can still open the vault and keep the account going: it holds the key, or has a grant it can
 * unwrap and accept. When none is left, the key is reset.
 */
export function canOpenVault(key: Doc<"deviceKeys">): boolean {
  switch (key.state.kind) {
    case "holder":
    case "granted":
      return true;
    case "requested":
    case "denied":
      return false;
    default: {
      const _exhaustive: never = key.state;
      return _exhaustive;
    }
  }
}

/**
 * A device that may have the library's current key, whatever its state says now: it can open the vault, or it was
 * given the current key once (a granted device that asked again keeps whatever it unwrapped). Its leaving forces a
 * rotation. Exchange state alone can't decide this: `keys:request` moves a granted device back to `requested`.
 */
export function mayHaveCurrentKey(key: Doc<"deviceKeys">, library: Doc<"libraries">): boolean {
  return canOpenVault(key) || (library.keyId !== undefined && key.exposedKeyId === library.keyId);
}

/**
 * Resets the vault key when the library has one but no device left can open the vault (`canOpenVault`): nobody
 * can rotate it, grant it or write with it, and a claim needs a library without a key, so the account would be
 * stuck. Happens when the last granted device asks again after its holder left. Returns whether it reset.
 */
export async function resetIfStranded(ctx: MutationCtx, libraryId: Id<"libraries">, now: number): Promise<boolean> {
  const library = await ctx.db.get(libraryId);
  if (library === null || library.keyId === undefined) return false;
  const keys = await ctx.db
    .query("deviceKeys")
    .withIndex("by_library", (q) => q.eq("libraryId", libraryId))
    .collect();
  if (keys.some(canOpenVault)) return false;
  await resetVaultKey(ctx, library, now);
  return true;
}

/**
 * After a device left a library that still has devices:
 * - exchanges it was answering start over (the asking device commits to a new nonce);
 * - when no remaining device can open the vault, the key is reset (`resetVaultKey`);
 * - when the device may have had the current key (`mayHaveCurrentKey`), the key must be replaced: a removed or
 *   lost device may still have it, so the remaining holders rotate it (`keys:rotate`) before the vault takes new
 *   writes.
 */
async function afterDeviceLeft(
  ctx: MutationCtx,
  left: { libraryId: Id<"libraries">; deviceId: Id<"devices">; key: Doc<"deviceKeys"> | null; now: number },
): Promise<void> {
  const library = await ctx.db.get(left.libraryId);
  if (library === null) return;
  const keys = await ctx.db
    .query("deviceKeys")
    .withIndex("by_library", (q) => q.eq("libraryId", left.libraryId))
    .collect();
  for (const key of keys) {
    const exchange = key.state.kind === "requested" ? key.state.exchange : undefined;
    if (exchange !== undefined && exchange.phase !== "committed" && exchange.holder === left.deviceId) {
      await ctx.db.patch(key._id, { state: { kind: "requested", requestedAt: left.now }, updatedAt: left.now });
    }
  }
  if (library.keyId === undefined) return;
  if (!keys.some(canOpenVault)) {
    await resetVaultKey(ctx, library, left.now);
  } else if (left.key !== null && mayHaveCurrentKey(left.key, library) && library.keyRotation === undefined) {
    await ctx.db.patch(library._id, { keyRotation: { neededSince: left.now } });
  }
}

/**
 * When no remaining device can open the vault, its sign-ins are lost for good. The key fingerprint is cleared (and
 * retired, so it is never adopted again) and every device moves to `requested`; the next device to notice claims a
 * fresh key (`keys:claim`) and uploads its own sign-ins, and the others then ask it.
 *
 * Settings rows are deleted (they were sealed under the lost key). Vault rows aren't: a sealed row becomes `cleared` at the next revision, and a tombstone stays a
 * tombstone. Revisions only ever grow, so every device's record of the revision it applied stays valid: its next
 * write is based on the stored revision, a device that missed a sign-out still honors it, and no old blob can come
 * back at a revision a device already passed.
 */
export async function resetVaultKey(ctx: MutationCtx, library: Doc<"libraries">, now: number): Promise<void> {
  await ctx.db.patch(library._id, {
    keyId: undefined,
    keyRotation: undefined,
    previousKey: undefined,
    retiredKeyIds: retiredWith(library, library.keyId),
  });
  await bumpKeyRevision(ctx, library._id);
  // Settings are sealed under the lost key, so nobody can open them again; the next device to claim a key fills them
  // in from its own values. (At most `LIMITS.maxSettingKeys` rows.) Playback content under the lost key is ignored by
  // readers and replaced by each device's next publish.
  const settings = await ctx.db
    .query("settings")
    .withIndex("by_library_key", (q) => q.eq("libraryId", library._id))
    .collect();
  for (const row of settings) await ctx.db.delete(row._id);
  const vault = await ctx.db
    .query("vault")
    .withIndex("by_library_provider", (q) => q.eq("libraryId", library._id))
    .collect();
  for (const row of vault) {
    if (row.sealed === undefined) continue;
    await ctx.db.replace(row._id, {
      libraryId: row.libraryId,
      provider: row.provider,
      sealed: undefined,
      cleared: true,
      keyId: NO_KEY,
      revision: (row.revision ?? 0) + 1,
      updatedAt: Math.max(now, row.updatedAt + 1),
      updatedBy: row.updatedBy,
    });
  }
  const keys = await ctx.db
    .query("deviceKeys")
    .withIndex("by_library", (q) => q.eq("libraryId", library._id))
    .collect();
  for (const key of keys) await ctx.db.patch(key._id, { state: { kind: "requested", requestedAt: now }, updatedAt: now });
}

/**
 * Takes a library out of use at once and has its rows deleted in the background: the owner is detached, so the
 * user's tokens stop working (`authenticate` needs a library the user owns) and their next device starts a new
 * library, and the owner-less library sweep (`legacy:sweep`) deletes everything it had, in bounded batches.
 *
 * The tokens of the devices it still has are retired first (`retireToken`), while the owner is known: the sweep
 * deletes those devices later without one, and a late registration with one of their tokens must stay refused after
 * that too. At most `LIMITS.maxDevicesPerLibrary` records.
 */
export async function retireLibrary(ctx: MutationCtx, libraryId: Id<"libraries">): Promise<void> {
  const library = await ctx.db.get(libraryId);
  if (library === null) return;
  if (library.owner !== undefined) {
    const owner = library.owner;
    const now = Date.now();
    const devices = await ctx.db
      .query("devices")
      .withIndex("by_library", (q) => q.eq("libraryId", libraryId))
      .collect();
    for (const device of devices) await retireToken(ctx, { tokenHash: device.tokenHash, owner, now });
    await ctx.db.patch(libraryId, { owner: undefined });
  }
  await ctx.scheduler.runAfter(0, internal.legacy.sweep, {});
}

/**
 * Expires one library whose `expiresAt` passed. The devices' `lastSeenAt` is the truth: when one was seen
 * recently enough, the expiry moves forward instead.
 */
export async function expireLibrary(ctx: MutationCtx, library: Doc<"libraries">, now: number): Promise<"deleted" | "kept"> {
  const devices = await ctx.db
    .query("devices")
    .withIndex("by_library", (q) => q.eq("libraryId", library._id))
    .collect();
  const lastSeen = devices.reduce((latest, d) => Math.max(latest, d.lastSeenAt), library.createdAt);
  const expiresAt = lastSeen + LIMITS.libraryIdleTtlMs;
  if (expiresAt > now) {
    await ctx.db.patch(library._id, { expiresAt });
    return "kept";
  }
  await retireLibrary(ctx, library._id);
  return "deleted";
}

/**
 * Deletes up to `budget` rows of an owner-less library: its library-wide rows, then each device with its own rows,
 * then the library itself. Returns how many rows it deleted and whether the library is gone. Nothing is kept between
 * runs: what is left in the database is where the next run picks up.
 */
export async function drainLibrary(ctx: MutationCtx, libraryId: Id<"libraries">, budget: number): Promise<{ deleted: number; done: boolean }> {
  let left = budget;
  const drop = async (rows: { _id: Id<"vault" | "settings" | "settingOps" | "deviceKeys" | "playback" | "queues" | "commands"> }[]) => {
    for (const row of rows) await ctx.db.delete(row._id);
    left -= rows.length;
  };
  const result = (done: boolean) => ({ deleted: budget - left, done });

  const libraryWide = [
    () => ctx.db.query("vault").withIndex("by_library_provider", (q) => q.eq("libraryId", libraryId)).take(left),
    () => ctx.db.query("settings").withIndex("by_library_key", (q) => q.eq("libraryId", libraryId)).take(left),
    () => ctx.db.query("settingOps").withIndex("by_library_key_write", (q) => q.eq("libraryId", libraryId)).take(left),
    () => ctx.db.query("deviceKeys").withIndex("by_library", (q) => q.eq("libraryId", libraryId)).take(left),
    () => ctx.db.query("playback").withIndex("by_library", (q) => q.eq("libraryId", libraryId)).take(left),
  ];
  for (const rows of libraryWide) {
    await drop(await rows());
    if (left <= 0) return result(false);
  }

  for (;;) {
    const device = await ctx.db
      .query("devices")
      .withIndex("by_library", (q) => q.eq("libraryId", libraryId))
      .first();
    if (device === null) break;
    const own = [
      () => ctx.db.query("queues").withIndex("by_device", (q) => q.eq("deviceId", device._id)).take(left),
      () => ctx.db.query("commands").withIndex("by_to_pending", (q) => q.eq("toDeviceId", device._id)).take(left),
      () => ctx.db.query("commands").withIndex("by_from", (q) => q.eq("fromDeviceId", device._id)).take(left),
    ];
    for (const rows of own) {
      await drop(await rows());
      if (left <= 0) return result(false);
    }
    await ctx.db.delete(device._id);
    left -= 1;
    if (left <= 0) return result(false);
  }

  await ctx.db.delete(libraryId);
  left -= 1;
  return result(true);
}
