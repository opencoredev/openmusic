import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { internalMutation, mutation, type MutationCtx } from "./_generated/server";
import { bumpKeyRevision, deleteDevice, isRetired, NO_KEY, refusalOf, touchLibrary } from "./cleanup";
import {
  checkDeviceInfo,
  checkKeyId,
  checkPublicKey,
  checkToken,
  deviceKeyOf,
  fail,
  libraryOf,
  requireOwner,
  sha256Hex,
  type Owner,
} from "./lib";
import { deviceInfoV, keyStateKindV, LIMITS, serverNowV, type KeyState } from "./model";
import { check, hit, type Limit } from "./throttle";

const hourMs = 3600_000;

async function registerLimit(owner: Owner): Promise<Limit> {
  return { key: `register:${(await sha256Hex(owner)).slice(0, 32)}`, windowMs: hourMs, limit: LIMITS.registerPerUserPerHour };
}

async function withdrawalLimit(owner: Owner): Promise<Limit> {
  return { key: `withdraw:${(await sha256Hex(owner)).slice(0, 32)}`, windowMs: hourMs, limit: LIMITS.withdrawalsPerUserPerHour };
}

/**
 * The unexpired withdrawals recorded for `owner`, oldest expiry first, at most `limit`. A row without a `reason` (written
 * before the field existed) is a withdrawal too, so it counts toward the cap like one.
 */
async function withdrawalsOf(
  ctx: MutationCtx,
  query: { owner: Owner; now: number; limit: number },
): Promise<Doc<"cancelledRegistrations">[]> {
  const { owner, now, limit } = query;
  const tagged = await ctx.db
    .query("cancelledRegistrations")
    .withIndex("by_owner_reason_expiresAt", (q) => q.eq("owner", owner).eq("reason", "withdrawn").gt("expiresAt", now))
    .take(limit);
  const untagged = await ctx.db
    .query("cancelledRegistrations")
    .withIndex("by_owner_reason_expiresAt", (q) => q.eq("owner", owner).eq("reason", undefined).gt("expiresAt", now))
    .take(limit);
  return [...tagged, ...untagged].sort((a, b) => a.expiresAt - b.expiresAt).slice(0, limit);
}

/**
 * Records a new withdrawal of `tokenHash` for `owner`: a token no device of theirs has, so nothing bounds how many a
 * client could make up. Limited per user per hour (`LIMITS.withdrawalsPerUserPerHour`) and in total
 * (`LIMITS.maxWithdrawalsPerUser` unexpired), both answered with `rateLimited`; the device keeps the removal it owes
 * and tries again later. The caller checks first that the token isn't recorded already (a retry is free).
 */
async function recordWithdrawal(ctx: MutationCtx, withdrawal: { tokenHash: string; owner: Owner; now: number }): Promise<void> {
  const { tokenHash, owner, now } = withdrawal;
  const limit = await withdrawalLimit(owner);
  const verdict = await check(ctx, [limit], now);
  if (verdict.kind === "blocked") {
    fail("rateLimited", "Too many sign-outs of unknown devices. Try again later.", { retryAfterMs: verdict.retryAfterMs });
  }
  const recorded = await withdrawalsOf(ctx, { owner, now, limit: LIMITS.maxWithdrawalsPerUser });
  const oldest = recorded.at(0);
  if (oldest !== undefined && recorded.length >= LIMITS.maxWithdrawalsPerUser) {
    fail("rateLimited", "Too many sign-outs of unknown devices. Try again later.", { retryAfterMs: oldest.expiresAt - now });
  }
  await hit(ctx, [limit], now);
  await ctx.db.insert("cancelledRegistrations", {
    tokenHash,
    owner,
    reason: "withdrawn",
    createdAt: now,
    expiresAt: now + LIMITS.cancelledRegistrationTtlMs,
  });
}

/** The signed-in user's library, created on their first device. */
async function libraryFor(ctx: MutationCtx, owner: Owner, now: number): Promise<Doc<"libraries">> {
  const existing = await libraryOf(ctx, owner);
  if (existing !== null) return existing;
  const id = await ctx.db.insert("libraries", { owner, createdAt: now, expiresAt: now + LIMITS.libraryIdleTtlMs });
  const library = await ctx.db.get(id);
  if (library === null) fail("notFound", "No such library.");
  return library;
}

/** Makes room for one more device by removing the one seen least recently, when the library is full. */
async function evictIfFull(ctx: MutationCtx, libraryId: Id<"libraries">): Promise<void> {
  const devices = await ctx.db
    .query("devices")
    .withIndex("by_library", (q) => q.eq("libraryId", libraryId))
    .collect();
  if (devices.length < LIMITS.maxDevicesPerLibrary) return;
  const stalest = devices.reduce((a, b) => (b.lastSeenAt < a.lastSeenAt ? b : a));
  await deleteDevice(ctx, stalest._id, libraryId);
}

/**
 * The device's first key state. Every device proposes a fresh vault key fingerprint. A library without a key
 * adopts the proposal (the first device creates the key). In a library that has a key, a new device always asks
 * for it, whatever it proposes: knowing the fingerprint (every device sees it) proves nothing, and a device coming
 * back after it was removed must be approved again. A key the account used before is never adopted again.
 */
function initialKeyState(library: Doc<"libraries">, proposed: string | undefined, now: number): { state: KeyState; adopt: boolean } {
  if (proposed !== undefined && library.keyId === undefined && proposed !== NO_KEY && !isRetired(library, proposed)) {
    return { state: { kind: "holder", since: now }, adopt: true };
  }
  return { state: { kind: "requested", requestedAt: now }, adopt: false };
}

/**
 * Adds the calling device to the signed-in user's devices, creating the user's library on their first device.
 * `token` is the device's own secret (32 random bytes, base64url): every other function takes it to know which
 * device is calling, and only its SHA-256 is stored. The token is also the registration's request id: registering
 * the same token again returns the same device with its key state (a retry, before the rate limit and without
 * counting toward it), so a device whose answer was lost sends the same registration again and learns what landed.
 * `publicKey` is the device's X25519 key that the vault key is wrapped to;
 * `keyId` is the fresh vault key fingerprint the device proposes, adopted only by a library without a key (see
 * `initialKeyState`).
 *
 * A device token is single-use: once its device is gone (signed out, removed from another device, evicted, its
 * account expired), or the user withdrew it (`account:unregister`), it is refused with `unauthorized` for that user
 * (`cancelledRegistrations`). So a copy of a registration that arrives after its device left never creates the device
 * again with a token and key the installation discarded. A retry while the device exists still gets the same device.
 *
 * Every attempt carries `createdAt`: when the device made this registration (ms since 1970, its clock), the same in
 * every attempt. A new device is refused (`invalidArgument`) when that is older than `LIMITS.registrationMaxAgeMs`
 * (or further ahead than `LIMITS.registrationMaxAheadMs`): retirements are forgotten after
 * `LIMITS.cancelledRegistrationTtlMs`, and an attempt resent after that (a device offline for a month) must not register
 * a token whose device was removed meanwhile. The device starts a new registration then. A retry of a device that
 * exists is answered whatever its age: it creates nothing.
 *
 * A full library (32 devices) loses the device seen least recently. Rate limited per user.
 */
export const register = mutation({
  args: { token: v.string(), device: deviceInfoV, publicKey: v.string(), keyId: v.optional(v.string()), createdAt: v.number() },
  returns: v.object({
    deviceId: v.id("devices"),
    libraryId: v.id("libraries"),
    keyId: v.union(v.string(), v.null()),
    keyState: keyStateKindV,
    /** The account's key revision this answer reflects (see `devices:list`). */
    keyRevision: v.number(),
    serverNow: serverNowV,
  }),
  handler: async (ctx, args) => {
    const owner = await requireOwner(ctx);
    const now = Date.now();
    const token = checkToken(args.token);
    const info = checkDeviceInfo(args.device);
    const publicKey = checkPublicKey(args.publicKey);
    const proposed = args.keyId === undefined ? undefined : checkKeyId(args.keyId);
    const tokenHash = await sha256Hex(token);
    if ((await refusalOf(ctx, tokenHash, owner)) !== null) fail("unauthorized", "This device signed out.");

    const known = await ctx.db
      .query("devices")
      .withIndex("by_tokenHash", (q) => q.eq("tokenHash", tokenHash))
      .unique();
    if (known !== null) {
      const library = await ctx.db.get(known.libraryId);
      if (library === null || library.owner !== owner) fail("unauthorized", "Unknown device.");
      const key = await deviceKeyOf(ctx, known._id);
      if (key === null) fail("unauthorized", "Unknown device.");
      return {
        deviceId: known._id,
        libraryId: library._id,
        keyId: library.keyId ?? null,
        keyState: key.state.kind,
        keyRevision: library.keyRevision ?? 0,
        serverNow: now,
      };
    }

    if (!Number.isFinite(args.createdAt) || args.createdAt < now - LIMITS.registrationMaxAgeMs || args.createdAt > now + LIMITS.registrationMaxAheadMs) {
      fail("invalidArgument", "This registration is too old, or the device's clock is off. Check the date and time and try again.");
    }

    const limit = await registerLimit(owner);
    const verdict = await check(ctx, [limit], now);
    if (verdict.kind === "blocked") {
      fail("rateLimited", "Too many sign-ins on new devices. Try again later.", { retryAfterMs: verdict.retryAfterMs });
    }
    await hit(ctx, [limit], now);

    const library = await libraryFor(ctx, owner, now);
    await evictIfFull(ctx, library._id);
    // Eviction may have reset the vault key; read the library again.
    const current = (await ctx.db.get(library._id)) ?? library;
    const { state, adopt } = initialKeyState(current, proposed, now);
    if (adopt) await ctx.db.patch(current._id, { keyId: proposed });
    const deviceId = await ctx.db.insert("devices", {
      libraryId: current._id,
      ...info,
      tokenHash,
      createdAt: now,
      lastSeenAt: now,
    });
    await ctx.db.insert("deviceKeys", { libraryId: current._id, deviceId, publicKey, state, exposedKeyId: adopt ? proposed : undefined, updatedAt: now });
    await touchLibrary(ctx, current._id, now);
    await bumpKeyRevision(ctx, current._id);
    const revision = (await ctx.db.get(current._id))?.keyRevision ?? 0;
    return {
      deviceId,
      libraryId: current._id,
      keyId: adopt ? (proposed ?? null) : (current.keyId ?? null),
      keyState: state.kind,
      keyRevision: revision,
      serverNow: now,
    };
  },
});

/**
 * Withdraws the registration a token names, for the signed-in user: the way a device signs out when it doesn't know
 * its own device id, because the answer to its first registration was lost. Registration is idempotent by token, so
 * the server may have taken it; this removes that device (with the same effects as `devices:remove`).
 *
 * Either way the token is refused for this user from then on (`cancelledRegistrations`): the registration may still
 * be on its way (sent, not yet run). A device that was there is removed, which retires its token like any removal,
 * never limited. A token no device of this user's has is recorded as withdrawn, which is rate limited and capped per
 * user (`recordWithdrawal`); a retry of one already recorded (withdrawn or retired) is free. So `cancelled: true` in
 * the answer tells the device that no copy of that registration can ever land, and it may drop the token and key it
 * saved for it. A token of another user's device changes nothing of theirs (the record is this user's only) and is
 * answered the same way as an unknown one.
 */
export const unregister = mutation({
  args: { token: v.string() },
  returns: v.object({ removed: v.boolean(), cancelled: v.boolean(), serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const owner = await requireOwner(ctx);
    const now = Date.now();
    const tokenHash = await sha256Hex(checkToken(args.token));
    const device = await ctx.db
      .query("devices")
      .withIndex("by_tokenHash", (q) => q.eq("tokenHash", tokenHash))
      .unique();
    const library = device === null ? null : await ctx.db.get(device.libraryId);
    if (device !== null && library !== null && library.owner === owner) {
      // Retires the token (`deleteDevice`), never limited.
      await deleteDevice(ctx, device._id, device.libraryId);
      return { removed: true, cancelled: true, serverNow: now };
    }
    if ((await refusalOf(ctx, tokenHash, owner)) === null) await recordWithdrawal(ctx, { tokenHash, owner, now });
    return { removed: false, cancelled: true, serverNow: now };
  },
});

/**
 * Migration: gives `reason: "withdrawn"` to `cancelledRegistrations` rows written before the field existed (what they
 * count as already), `LIMITS.sweepBatch` rows per run, each run scheduling the next until the table is done. Run once
 * per deployment after pushing the schema where `reason` is optional (`npx convex run account:backfillCancellationReasons`),
 * before a later change makes it required. Safe to run again: rows that have a reason are left alone.
 */
export const backfillCancellationReasons = internalMutation({
  args: { cursor: v.optional(v.union(v.string(), v.null())) },
  returns: v.object({ patched: v.number(), done: v.boolean() }),
  handler: async (ctx, args) => {
    const page = await ctx.db
      .query("cancelledRegistrations")
      .paginate({ cursor: args.cursor ?? null, numItems: LIMITS.sweepBatch });
    let patched = 0;
    for (const row of page.page) {
      if (row.reason !== undefined) continue;
      await ctx.db.patch(row._id, { reason: "withdrawn" });
      patched += 1;
    }
    if (!page.isDone) await ctx.scheduler.runAfter(0, internal.account.backfillCancellationReasons, { cursor: page.continueCursor });
    return { patched, done: page.isDone };
  },
});

/** Forgets retired and withdrawn tokens older than `LIMITS.cancelledRegistrationTtlMs`. Continues while a batch is full. */
export const sweepCancellations = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number(), more: v.boolean() }),
  handler: async (ctx) => {
    const expired = await ctx.db
      .query("cancelledRegistrations")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", Date.now()))
      .take(LIMITS.sweepBatch);
    for (const row of expired) await ctx.db.delete(row._id);
    const more = expired.length === LIMITS.sweepBatch;
    if (more) await ctx.scheduler.runAfter(0, internal.account.sweepCancellations, {});
    return { deleted: expired.length, more };
  },
});
