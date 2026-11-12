// The account's vault key moves from device to device, never through the server in a readable form. See
// docs/accounts-design.md, "Sign-in vault key". The server only relays the verification exchange and keeps the
// state machine honest for honest devices; it is not trusted with confidentiality, so every check that protects
// the key against the server itself happens on the devices.
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { mutation, type MutationCtx } from "./_generated/server";
import { bumpKeyRevision, isRetired, NO_KEY, resetIfStranded, retiredWith } from "./cleanup";
import { authenticate, checkBase64, checkBytes32, checkKeyId, deviceInLibrary, deviceKeyOf, fail, type Caller } from "./lib";
import { checkSealed, PREVIOUS_KEY_GRACE_MS } from "./content";
import { LIMITS, providerV, sealedV, serverNowV } from "./model";
import { check, hit, type Limit } from "./throttle";

async function callerKey(ctx: MutationCtx, caller: Caller): Promise<Doc<"deviceKeys">> {
  const key = await deviceKeyOf(ctx, caller.device._id);
  if (key === null) fail("unauthorized", "Unknown device.");
  return key;
}

async function libraryOfCaller(ctx: MutationCtx, caller: Caller): Promise<Doc<"libraries">> {
  const library = await ctx.db.get(caller.libraryId);
  if (library === null) fail("notFound", "No such library.");
  return library;
}

async function requireHolder(ctx: MutationCtx, caller: Caller): Promise<Doc<"deviceKeys">> {
  const key = await callerKey(ctx, caller);
  if (key.state.kind !== "holder") fail("forbidden", "This device doesn't have your sign-ins.");
  return key;
}

/** The key row of another device of the caller's library. */
async function targetKey(ctx: MutationCtx, caller: Caller, deviceId: Id<"devices">): Promise<Doc<"deviceKeys">> {
  const target = await deviceInLibrary(ctx, caller, deviceId);
  if (target._id === caller.device._id) fail("invalidArgument", "A device can't answer itself.");
  const key = await deviceKeyOf(ctx, target._id);
  if (key === null) fail("notFound", "No such device in this library.");
  return key;
}

function requestLimit(deviceId: Id<"devices">): Limit {
  return { key: `keyRequest:${deviceId}`, windowMs: 3600_000, limit: LIMITS.keyRequestsPerDeviceHour };
}

/** The library's `keyRevision` now (after any bump in this transaction). */
async function revisionOf(ctx: MutationCtx, libraryId: Id<"libraries">): Promise<number> {
  return (await ctx.db.get(libraryId))?.keyRevision ?? 0;
}

/**
 * Claims a vault key for an account that has none (the first device, or every device that could open the vault
 * is gone). The caller generated the key and becomes its holder. A claim is refused when the account has a key
 * (only holders get it, by the exchange) and for a key the account used before. Retrying a claim that landed is a
 * no-op.
 *
 * The claim is a compare-and-swap on what the device examined: `keyRevision` is the account's key revision in the
 * state where it saw no key, and any change since is refused with `conflict` (nothing changes). A claim can therefore
 * land only right after the state it was decided on, never later: once a device has seen a newer revision (another
 * device claimed, and maybe left again), its claim still on its way can't make it the holder of a key it may already
 * have dropped. The answer carries the revision after the claim, which the device counts as an observation.
 */
export const claim = mutation({
  args: { token: v.string(), keyId: v.string(), keyRevision: v.number() },
  returns: v.object({ keyId: v.string(), keyRevision: v.number(), serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const keyId = checkKeyId(args.keyId);
    const library = await libraryOfCaller(ctx, caller);
    const key = await callerKey(ctx, caller);
    const now = Date.now();
    if (library.keyId !== undefined) {
      if (library.keyId === keyId && key.state.kind === "holder") return { keyId, keyRevision: library.keyRevision ?? 0, serverNow: now };
      fail("forbidden", "Your account already has a key. A device that has it must allow this one.");
    }
    if (isRetired(library, keyId) || keyId === NO_KEY) fail("forbidden", "That key was used before. Make a new one.");
    if (args.keyRevision !== (library.keyRevision ?? 0)) fail("conflict", "Your account's keys changed since this device looked. Look again.");
    await ctx.db.patch(library._id, { keyId, keyRotation: undefined });
    await ctx.db.patch(key._id, { state: { kind: "holder", since: now }, exposedKeyId: keyId, updatedAt: now });
    await bumpKeyRevision(ctx, caller.libraryId);
    return { keyId, keyRevision: await revisionOf(ctx, caller.libraryId), serverNow: now };
  },
});

/**
 * The caller (a device without the key) asks for it: it commits to a secret nonce, `commitment` =
 * SHA-256(domain ‖ its public key ‖ nonce), and starts a new exchange. Any earlier exchange, denial or unopened
 * grant is dropped (the device stays exposed to a granted key: `mayHaveCurrentKey`). A holder stays a holder.
 * Rate limited per device: each request puts a prompt on the holders.
 *
 * When dropping a grant leaves no device that can open the vault (its holder left before the grant was taken),
 * the key is reset (`resetIfStranded`) and the next device to notice claims a fresh one.
 */
export const request = mutation({
  args: { token: v.string(), commitment: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    const commitment = checkBytes32(args.commitment, "commitment");
    const key = await callerKey(ctx, caller);
    const now = Date.now();
    if (key.state.kind === "holder") return { serverNow: now };
    // A retry of the same request changes nothing (and isn't counted).
    if (key.state.kind === "requested" && key.state.exchange?.commitment === commitment) {
      await resetIfStranded(ctx, caller.libraryId, now);
      return { serverNow: now };
    }
    const limit = requestLimit(caller.device._id);
    const verdict = await check(ctx, [limit], now);
    if (verdict.kind === "blocked") {
      fail("rateLimited", "This device asked for your sign-ins too often. Try again later.", { retryAfterMs: verdict.retryAfterMs });
    }
    await hit(ctx, [limit], now);
    await ctx.db.patch(key._id, {
      state: { kind: "requested", requestedAt: now, exchange: { phase: "committed", commitment, at: now } },
      updatedAt: now,
    });
    await resetIfStranded(ctx, caller.libraryId, now);
    return { serverNow: now };
  },
});

/**
 * A holder answers an asking device's commitment with a fresh nonce of its own; the holder's device public key
 * goes with it. The first holder to answer runs the exchange. Answering the same commitment again with the same
 * nonce is a no-op (a retry).
 */
export const answer = mutation({
  args: { token: v.string(), deviceId: v.id("devices"), commitment: v.string(), nonce: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    const commitment = checkBytes32(args.commitment, "commitment");
    const nonce = checkBytes32(args.nonce, "nonce");
    const own = await requireHolder(ctx, caller);
    const key = await targetKey(ctx, caller, args.deviceId);
    const now = Date.now();
    const exchange = key.state.kind === "requested" ? key.state.exchange : undefined;
    if (exchange === undefined || exchange.commitment !== commitment) fail("conflict", "That device isn't asking any more.");
    switch (exchange.phase) {
      case "committed":
        await ctx.db.patch(key._id, {
          state: {
            kind: "requested",
            requestedAt: now,
            exchange: { phase: "answered", commitment, at: now, holder: caller.device._id, holderKey: own.publicKey, holderNonce: nonce },
          },
          updatedAt: now,
        });
        return { serverNow: now };
      case "answered":
      case "revealed":
        if (exchange.holder === caller.device._id && exchange.holderNonce === nonce) return { serverNow: now };
        return fail("conflict", "Another device answered first.");
      default: {
        const _exhaustive: never = exchange;
        return _exhaustive;
      }
    }
  },
});

/** The asking device reveals the nonce it committed to, once a holder answered. Revealing it again is a no-op. */
export const reveal = mutation({
  args: { token: v.string(), commitment: v.string(), nonce: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    const commitment = checkBytes32(args.commitment, "commitment");
    const nonce = checkBytes32(args.nonce, "nonce");
    const key = await callerKey(ctx, caller);
    const now = Date.now();
    const exchange = key.state.kind === "requested" ? key.state.exchange : undefined;
    if (exchange === undefined || exchange.commitment !== commitment) fail("conflict", "That exchange isn't running any more.");
    switch (exchange.phase) {
      case "committed":
        return fail("conflict", "No device has answered yet.");
      case "answered":
        await ctx.db.patch(key._id, {
          state: { kind: "requested", requestedAt: now, exchange: { ...exchange, phase: "revealed", at: now, nonce } },
          updatedAt: now,
        });
        return { serverNow: now };
      case "revealed":
        if (exchange.nonce === nonce) return { serverNow: now };
        return fail("conflict", "This exchange already has a nonce.");
      default: {
        const _exhaustive: never = exchange;
        return _exhaustive;
      }
    }
  },
});

/**
 * The holder that ran the exchange gives the vault key to the asking device after the listener compared the codes
 * and tapped Allow: `wrapped` is the key sealed under a key only those two devices can derive (see the design doc).
 * The server can't open it. Refused while the key is being replaced (`keys:rotate` first). Granting the same blob
 * again is a no-op (a retry).
 */
export const grant = mutation({
  args: { token: v.string(), deviceId: v.id("devices"), keyId: v.string(), wrapped: v.string(), commitment: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    const keyId = checkKeyId(args.keyId);
    const wrapped = checkBase64(args.wrapped, "wrapped", LIMITS.maxWrappedKeyLength);
    const commitment = checkBytes32(args.commitment, "commitment");
    await requireHolder(ctx, caller);
    const library = await libraryOfCaller(ctx, caller);
    if (library.keyId !== keyId) fail("forbidden", "That isn't your account's key.");
    if (library.keyRotation !== undefined) fail("conflict", "Your account's key is being replaced. Try again in a moment.");
    const key = await targetKey(ctx, caller, args.deviceId);
    const now = Date.now();
    switch (key.state.kind) {
      case "requested": {
        const exchange = key.state.exchange;
        if (exchange?.phase !== "revealed" || exchange.commitment !== commitment || exchange.holder !== caller.device._id) {
          return fail("conflict", "That device's request changed. Check its code again.");
        }
        await ctx.db.patch(key._id, {
          state: { kind: "granted", grantedAt: now, grantedBy: caller.device._id, keyId, wrapped, commitment },
          exposedKeyId: keyId,
          updatedAt: now,
        });
        return { serverNow: now };
      }
      case "granted":
        if (key.state.wrapped === wrapped) return { serverNow: now };
        return fail("conflict", "Another device already allowed it.");
      case "holder":
        return fail("conflict", "That device already has your sign-ins.");
      case "denied":
        return fail("forbidden", "That device was not allowed. It has to ask again.");
      default: {
        const _exhaustive: never = key.state;
        return _exhaustive;
      }
    }
  },
});

/**
 * The caller took a key: a `granted` device opened its grant (and the listener confirmed the code on it), or a
 * holder took the rotated key waiting on its row. Idempotent.
 */
export const accept = mutation({
  args: { token: v.string(), keyId: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    const keyId = checkKeyId(args.keyId);
    const key = await callerKey(ctx, caller);
    const library = await libraryOfCaller(ctx, caller);
    const now = Date.now();
    switch (key.state.kind) {
      case "holder":
        if (key.state.rekey !== undefined && key.state.rekey.keyId === keyId) {
          await ctx.db.patch(key._id, { state: { kind: "holder", since: key.state.since }, updatedAt: now });
        }
        return { serverNow: now };
      case "granted":
        if (key.state.keyId !== keyId || library.keyId !== keyId) break;
        await ctx.db.patch(key._id, { state: { kind: "holder", since: now }, updatedAt: now });
        return { serverNow: now };
      case "requested":
      case "denied":
        break;
      default: {
        const _exhaustive: never = key.state;
        return _exhaustive;
      }
    }
    return fail("forbidden", "There is no grant of that key for this device.");
  },
});

/**
 * A holder says the key it holds (`keyId`) isn't the account's and it can't get the current one: the rotated key
 * meant for it never arrived, or was made from a key it never had. As a holder it could never ask again, and an
 * account whose only holders are like it would never be reset. So it becomes a device without the key, with no
 * exchange (it asks only when the listener taps Ask Again); exchanges it was answering start over, and when no
 * device left can open the vault the key is reset (`resetIfStranded`). Refused with `conflict` for the account's
 * own key (the device has it after all). A device that isn't a holder changes nothing (a retry). The device keeps
 * its `exposedKeyId`, so removing it later still forces a rotation when it may have the current key.
 *
 * The release is a compare-and-swap on what the device examined before deciding: `accountKeyId`, the account's key
 * in the state it fetched just before, and `rekeyKeyId`, the rotated key waiting on its own row then (null for
 * none), which it tried to open with every key it holds. Anything else now (a device list that arrived late, a
 * rotation since) is refused with `conflict` and changes nothing, so a stale view can never discard an envelope the
 * device could open, nor reset the vault under it.
 */
export const release = mutation({
  args: {
    token: v.string(),
    keyId: v.string(),
    accountKeyId: v.union(v.string(), v.null()),
    rekeyKeyId: v.union(v.string(), v.null()),
    /** The account's `keyRevision` in the state the device examined. Any change since is refused (`conflict`). */
    keyRevision: v.number(),
  },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const keyId = checkKeyId(args.keyId);
    const accountKeyId = args.accountKeyId === null ? null : checkKeyId(args.accountKeyId);
    const rekeyKeyId = args.rekeyKeyId === null ? null : checkKeyId(args.rekeyKeyId);
    const key = await callerKey(ctx, caller);
    const library = await libraryOfCaller(ctx, caller);
    const now = Date.now();
    if (key.state.kind !== "holder") return { serverNow: now };
    if (library.keyId === keyId) fail("conflict", "This device has your account's key.");
    if ((library.keyId ?? null) !== accountKeyId) fail("conflict", "Your account's key changed. Look again.");
    if ((key.state.rekey?.keyId ?? null) !== rekeyKeyId) fail("conflict", "A new key is waiting for this device. Look again.");
    if (args.keyRevision !== (library.keyRevision ?? 0)) fail("conflict", "Your account's keys changed since this device looked. Look again.");
    await bumpKeyRevision(ctx, caller.libraryId);
    await ctx.db.patch(key._id, { state: { kind: "requested", requestedAt: now }, updatedAt: now });
    const keys = await ctx.db
      .query("deviceKeys")
      .withIndex("by_library", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    for (const other of keys) {
      const exchange = other.state.kind === "requested" ? other.state.exchange : undefined;
      if (exchange !== undefined && exchange.phase !== "committed" && exchange.holder === caller.device._id) {
        await ctx.db.patch(other._id, { state: { kind: "requested", requestedAt: now }, updatedAt: now });
      }
    }
    await resetIfStranded(ctx, caller.libraryId, now);
    return { serverNow: now };
  },
});

/** A holder said no to a device asking for the key. The device stops being shown until it asks again. */
export const deny = mutation({
  // `commitment`: the exchange the holder's listener saw. A device that asked again since has a new one, and a "Don't
  // Allow" meant for the old request leaves the new one alone. Optional for apps from before it existed.
  args: { token: v.string(), deviceId: v.id("devices"), commitment: v.optional(v.string()) },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const commitment = args.commitment === undefined ? undefined : checkBytes32(args.commitment, "commitment");
    // Rolled back with everything else when the mutation throws.
    await bumpKeyRevision(ctx, caller.libraryId);
    await requireHolder(ctx, caller);
    const key = await targetKey(ctx, caller, args.deviceId);
    const now = Date.now();
    if (key.state.kind === "requested" && (commitment === undefined || key.state.exchange?.commitment === commitment)) {
      await ctx.db.patch(key._id, { state: { kind: "denied", deniedAt: now, deniedBy: caller.device._id }, updatedAt: now });
    }
    return { serverNow: now };
  },
});

const rewrapV = v.object({ deviceId: v.id("devices"), wrapped: v.string() });
const resealV = v.object({ provider: providerV, baseRevision: v.number(), sealed: v.union(v.string(), v.null()) });
/** A settings row re-sealed under the new key, at the `updatedAt` the rotating device read (null: it couldn't open it). */
const resealSettingV = v.object({ key: v.string(), baseUpdatedAt: v.number(), value: v.union(sealedV, v.null()) });

/**
 * A holder replaces the account's vault key: after a device that could open the vault left (`keyRotation`), or
 * whenever it chooses. In one transaction:
 * - `wraps` gives the new key to every other holder. Each wrap is made with the old key mixed in, so only a holder
 *   of the old key can make one and the server can't hand a holder a key of its own (docs/accounts-design.md).
 * - `vault` re-seals every sealed row under the new key at the next revision (`sealed: null` for a row the holder
 *   couldn't open: it becomes a sign-out, as it already is on every device). Tombstones and cleared rows keep
 *   their revision.
 * - `settings` re-seals every settings row under the new key (`value: null` for a row the holder couldn't open: it is
 *   deleted), so every settings value is always readable with the library's current key. A row changed since the
 *   holder read it is a `conflict`.
 * - the old fingerprint is retired (and kept as `previousKey` for `PREVIOUS_KEY_GRACE_MS`, so holders publishing their
 *   playback under it until they take the new key aren't refused); grants of the old key not yet accepted are dropped (those devices ask again),
 *   and so are holders still holding an older rotation they never took.
 * Refused with `conflict` when the holders or the vault changed since the caller looked; it looks again and retries.
 * The answer carries the key revision after the rotation, which the device counts as an observation.
 */
export const rotate = mutation({
  args: {
    token: v.string(),
    fromKeyId: v.string(),
    keyId: v.string(),
    wraps: v.array(rewrapV),
    vault: v.array(resealV),
    settings: v.array(resealSettingV),
  },
  returns: v.object({ keyRevision: v.number(), serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const fromKeyId = checkKeyId(args.fromKeyId);
    const keyId = checkKeyId(args.keyId);
    const own = await requireHolder(ctx, caller);
    const library = await libraryOfCaller(ctx, caller);
    const now = Date.now();
    // A retry that landed: nothing changes, and the answer reports the revision as it is.
    if (library.keyId === keyId && library.keyRotation === undefined) return { keyRevision: library.keyRevision ?? 0, serverNow: now };
    if (library.keyId !== fromKeyId) fail("conflict", "Your account's key changed. Look again.");
    if (keyId === fromKeyId || keyId === NO_KEY || isRetired(library, keyId)) fail("forbidden", "Use a new key.");

    const keys = await ctx.db
      .query("deviceKeys")
      .withIndex("by_library", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    const holders = keys.filter((k) => k.state.kind === "holder" && k.deviceId !== caller.device._id);
    const wraps = new Map(args.wraps.map((w) => [w.deviceId, checkBase64(w.wrapped, "wrapped", LIMITS.maxWrappedKeyLength)]));
    if (wraps.size !== args.wraps.length || wraps.size !== holders.length || holders.some((h) => !wraps.has(h.deviceId))) {
      fail("conflict", "Your devices changed. Look again.");
    }
    // A holder that still has an older rotation waiting can't open a wrap made with the current key: it asks again.
    const behind = holders.filter((k) => k.state.kind === "holder" && k.state.rekey !== undefined);

    const rows = await ctx.db
      .query("vault")
      .withIndex("by_library_provider", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    const sealedRows = rows.filter((r) => r.sealed !== undefined);
    const reseal = new Map(args.vault.map((r) => [r.provider, r]));
    if (reseal.size !== args.vault.length || reseal.size !== sealedRows.length) fail("conflict", "Your sign-ins changed. Look again.");
    for (const row of sealedRows) {
      const next = reseal.get(row.provider);
      if (next === undefined || next.baseRevision !== (row.revision ?? 0)) fail("conflict", "Your sign-ins changed. Look again.");
    }

    const settingRows = await ctx.db
      .query("settings")
      .withIndex("by_library_key", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    const resealedSettings = new Map(args.settings.map((s) => [s.key, s]));
    if (resealedSettings.size !== args.settings.length || resealedSettings.size !== settingRows.length) {
      fail("conflict", "Your settings changed. Look again.");
    }
    for (const row of settingRows) {
      if (resealedSettings.get(row.key)?.baseUpdatedAt !== row.updatedAt) fail("conflict", "Your settings changed. Look again.");
    }
    // Checked against the new key: until this transaction commits the library still uses the old one.
    const rotated = { ...library, keyId, previousKey: undefined };
    for (const row of settingRows) {
      const next = resealedSettings.get(row.key);
      if (next === undefined) continue;
      if (next.value === null) {
        await ctx.db.delete(row._id);
        continue;
      }
      await ctx.db.replace(row._id, {
        libraryId: row.libraryId,
        key: row.key,
        value: checkSealed(next.value, "setting", rotated, { kind: "current" }),
        updatedAt: Math.max(now, row.updatedAt + 1),
        updatedBy: caller.device._id,
      });
    }

    for (const row of rows) {
      const next = reseal.get(row.provider);
      if (next === undefined) {
        await ctx.db.patch(row._id, { keyId: NO_KEY });
        continue;
      }
      const sealed = next.sealed === null ? undefined : checkBase64(next.sealed, "sealed", LIMITS.maxSealedBytes);
      await ctx.db.replace(row._id, {
        libraryId: row.libraryId,
        provider: row.provider,
        sealed,
        keyId: sealed === undefined ? NO_KEY : keyId,
        revision: (row.revision ?? 0) + 1,
        updatedAt: Math.max(now, row.updatedAt + 1),
        updatedBy: caller.device._id,
      });
    }
    for (const holder of holders) {
      const wrapped = wraps.get(holder.deviceId);
      if (wrapped === undefined || holder.state.kind !== "holder" || holder.state.rekey !== undefined) continue;
      await ctx.db.patch(holder._id, {
        state: { kind: "holder", since: holder.state.since, rekey: { keyId, fromKeyId, wrapped, by: caller.device._id } },
        exposedKeyId: keyId,
        updatedAt: now,
      });
    }
    for (const key of [...behind, ...keys.filter((k) => k.state.kind === "granted")]) {
      await ctx.db.patch(key._id, { state: { kind: "requested", requestedAt: now }, updatedAt: now });
    }
    await ctx.db.patch(own._id, { exposedKeyId: keyId, updatedAt: now });
    await ctx.db.patch(library._id, {
      keyId,
      keyRotation: undefined,
      retiredKeyIds: retiredWith(library, fromKeyId),
      previousKey: { keyId: fromKeyId, until: now + PREVIOUS_KEY_GRACE_MS },
    });
    await bumpKeyRevision(ctx, caller.libraryId);
    return { keyRevision: await revisionOf(ctx, caller.libraryId), serverNow: now };
  },
});
