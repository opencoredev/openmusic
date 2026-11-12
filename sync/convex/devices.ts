import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { canOpenVault, deleteDevice, resetIfStranded, touchLibrary } from "./cleanup";
import { authenticate, checkName, deviceInLibrary, deviceKeyOf, publicDevice } from "./lib";
import { exchangeV, keyStateKindV, platformV, serverNowV } from "./model";

export const deviceV = v.object({
  id: v.id("devices"),
  name: v.string(),
  platform: platformV,
  model: v.string(),
  appVersion: v.string(),
  createdAt: v.number(),
  /** Server ms. Online means `serverNow - lastSeenAt < LIMITS.onlineWindowMs` (90 s), computed by the client. */
  lastSeenAt: v.number(),
  /** Whether the device holds the vault key (null only for devices from before accounts). */
  keyState: v.union(keyStateKindV, v.null()),
  /** The device's X25519 public key (null only for devices from before accounts). */
  publicKey: v.union(v.string(), v.null()),
  /** Its verification exchange, only while it asks for the vault key. */
  exchange: v.union(exchangeV, v.null()),
});

/** The vault key wrapped to the caller, while a holder's grant waits for `keys:accept`. */
const grantV = v.object({
  keyId: v.string(),
  wrapped: v.string(),
  fromDeviceId: v.id("devices"),
  /** The exchange it came out of; null for a grant from before the exchange, which can't be opened. */
  commitment: v.union(v.string(), v.null()),
});

/** A rotated vault key wrapped to the caller (a holder), until it takes it with `keys:accept`. */
const rekeyListV = v.object({ keyId: v.string(), fromKeyId: v.string(), wrapped: v.string(), fromDeviceId: v.id("devices") });

/**
 * Every device of the signed-in user, oldest first, which one is the caller, the vault key fingerprint, and the
 * caller's pending key grant.
 */
export const list = query({
  args: { token: v.string() },
  returns: v.object({
    selfId: v.id("devices"),
    libraryId: v.id("libraries"),
    /** Fingerprint of the vault key, null while nobody holds one (claim one with `keys:claim`). */
    keyId: v.union(v.string(), v.null()),
    /** A device that could open the vault left: a holder must replace the key (`keys:rotate`). */
    rotationNeeded: v.boolean(),
    /**
     * The account's key revision (`libraries.keyRevision`): it grows with every change to the key state, so a device
     * ignores a list older than one it already applied.
     */
    keyRevision: v.number(),
    devices: v.array(deviceV),
    grant: v.union(grantV, v.null()),
    rekey: v.union(rekeyListV, v.null()),
  }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const devices = await ctx.db
      .query("devices")
      .withIndex("by_library", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    const keys = await ctx.db
      .query("deviceKeys")
      .withIndex("by_library", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    const keyOf = new Map(keys.map((k) => [k.deviceId, k]));
    const own = keyOf.get(caller.device._id)?.state;
    const library = await ctx.db.get(caller.libraryId);
    return {
      selfId: caller.device._id,
      libraryId: caller.libraryId,
      keyId: library?.keyId ?? null,
      rotationNeeded: library?.keyRotation !== undefined,
      keyRevision: library?.keyRevision ?? 0,
      devices: devices.map((d) => publicDevice(d, keyOf.get(d._id) ?? null)),
      grant:
        own?.kind === "granted"
          ? { keyId: own.keyId, wrapped: own.wrapped, fromDeviceId: own.grantedBy, commitment: own.commitment ?? null }
          : null,
      rekey:
        own?.kind === "holder" && own.rekey !== undefined
          ? { keyId: own.rekey.keyId, fromKeyId: own.rekey.fromKeyId, wrapped: own.rekey.wrapped, fromDeviceId: own.rekey.by }
          : null,
    };
  },
});

/**
 * Marks the caller as seen (and keeps its library from expiring). Apps call it every 30 s while in the foreground or
 * playing. A device without the key also checks that its account isn't stranded with a key nobody can open (an
 * older server could leave one like that), and resets the key if it is (`resetIfStranded`).
 */
export const heartbeat = mutation({
  args: { token: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const now = Date.now();
    await ctx.db.patch(caller.device._id, { lastSeenAt: now });
    await touchLibrary(ctx, caller.libraryId, now);
    const key = await deviceKeyOf(ctx, caller.device._id);
    if (key !== null && !canOpenVault(key)) await resetIfStranded(ctx, caller.libraryId, now);
    return { serverNow: now };
  },
});

export const rename = mutation({
  args: { token: v.string(), deviceId: v.id("devices"), name: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const device = await deviceInLibrary(ctx, caller, args.deviceId);
    await ctx.db.patch(device._id, { name: checkName(args.name) });
    return { serverNow: Date.now() };
  },
});

/**
 * Removes a device (the caller itself, when signing out, or another of the user's devices) and retires its token
 * (`retireToken`): a removed device gets `unauthorized` from then on and signs itself out, and a copy of its
 * registration still on its way is refused instead of registering it again.
 */
export const remove = mutation({
  args: { token: v.string(), deviceId: v.id("devices") },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const device = await deviceInLibrary(ctx, caller, args.deviceId);
    await deleteDevice(ctx, device._id, device.libraryId);
    return { serverNow: Date.now() };
  },
});
