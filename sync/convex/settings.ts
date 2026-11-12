import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalMutation, mutation, query } from "./_generated/server";
import { checkSealed } from "./content";
import { authenticate, fail } from "./lib";
import { LIMITS, sealedV, serverNowV } from "./model";
import { libraryOf } from "./playback";

/** Setting keys: 1 to 64 of A-Z a-z 0-9 . _ - (they are in the clear; values never are). */
export function checkSettingKey(key: string): string {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(key)) fail("invalidArgument", "Setting keys are 1 to 64 of A-Z a-z 0-9 . _ -.");
  return key;
}

export const settingV = v.object({
  key: v.string(),
  /** The value's JSON text, sealed under the vault key (kind `setting`, the key and the writer bound in). */
  value: sealedV,
  updatedAt: v.number(),
  updatedBy: v.id("devices"),
  /** The `writeId` the writer sent with this value, if any. */
  writeId: v.optional(v.string()),
});

/** Every synced setting of the library. */
export const list = query({
  args: { token: v.string() },
  returns: v.array(settingV),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const rows = await ctx.db
      .query("settings")
      .withIndex("by_library_key", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    return rows.map((r) => ({ key: r.key, value: r.value, updatedAt: r.updatedAt, updatedBy: r.updatedBy, writeId: r.writeId }));
  },
});

/**
 * Sets one setting for the whole library, its value sealed under the library's current vault key (a device without
 * it syncs no settings; a value sealed with any other key is refused). Last write (by server time) wins. `writeId` (any id the writer picks,
 * up to 64 characters) makes a retry of the same write idempotent: for 10 minutes after the write landed, putting
 * it again returns the `updatedAt` it got and changes nothing, even if another device wrote the key since. With
 * `ifAbsent` (a device filling in a key on its first sync) an existing value is kept and its `updatedAt` returned.
 */
export const put = mutation({
  args: { token: v.string(), key: v.string(), value: sealedV, writeId: v.optional(v.string()), ifAbsent: v.optional(v.boolean()) },
  returns: v.object({ updatedAt: v.number(), serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    checkSettingKey(args.key);
    const value = checkSealed(args.value, "setting", await libraryOf(ctx, caller), { kind: "current" });
    const writeId = args.writeId;
    if (writeId !== undefined && (writeId.length === 0 || writeId.length > 64)) {
      fail("invalidArgument", "writeId is 1 to 64 characters.");
    }
    const now = Date.now();
    if (writeId !== undefined) {
      const op = await ctx.db
        .query("settingOps")
        .withIndex("by_library_key_write", (q) => q.eq("libraryId", caller.libraryId).eq("key", args.key).eq("writeId", writeId))
        .first();
      if (op !== null && op.deviceId === caller.device._id) return { updatedAt: op.updatedAt, serverNow: now };
    }
    const existing = await ctx.db
      .query("settings")
      .withIndex("by_library_key", (q) => q.eq("libraryId", caller.libraryId).eq("key", args.key))
      .unique();
    if (existing !== null && writeId !== undefined && existing.writeId === writeId && existing.updatedBy === caller.device._id) {
      return { updatedAt: existing.updatedAt, serverNow: now };
    }
    const remember = async (updatedAt: number) => {
      if (writeId === undefined) return;
      await ctx.db.insert("settingOps", {
        libraryId: caller.libraryId,
        key: args.key,
        writeId,
        deviceId: caller.device._id,
        updatedAt,
        expiresAt: now + LIMITS.settingOpTtlMs,
      });
    };
    if (existing !== null && args.ifAbsent === true) {
      await remember(existing.updatedAt);
      return { updatedAt: existing.updatedAt, serverNow: now };
    }
    if (existing === null) {
      const count = (await ctx.db
        .query("settings")
        .withIndex("by_library_key", (q) => q.eq("libraryId", caller.libraryId))
        .take(LIMITS.maxSettingKeys)).length;
      if (count >= LIMITS.maxSettingKeys) fail("invalidArgument", "Too many synced settings.");
    }
    const updatedAt = existing === null ? now : Math.max(now, existing.updatedAt + 1);
    const row = { libraryId: caller.libraryId, key: args.key, value, updatedAt, updatedBy: caller.device._id, writeId };
    if (existing === null) await ctx.db.insert("settings", row);
    else await ctx.db.replace(existing._id, row);
    await remember(updatedAt);
    return { updatedAt, serverNow: now };
  },
});

/** Cron: forgets settings writes older than `LIMITS.settingOpTtlMs`, in batches (a full batch runs again at once). */
export const sweepOps = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number(), more: v.boolean() }),
  handler: async (ctx) => {
    const expired = await ctx.db
      .query("settingOps")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", Date.now()))
      .take(LIMITS.sweepBatch);
    for (const op of expired) await ctx.db.delete(op._id);
    const more = expired.length === LIMITS.sweepBatch;
    if (more) await ctx.scheduler.runAfter(0, internal.settings.sweepOps, {});
    return { deleted: expired.length, more };
  },
});
