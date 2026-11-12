import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { mutation, query, type MutationCtx } from "./_generated/server";
import { checkSealed, type KeyPolicy } from "./content";
import { authenticate, checkFinite, deviceInLibrary, fail, type Caller } from "./lib";
import { anchorV, sealedV, serverNowV, storedAnchorV, type AnchorInput } from "./model";

export const playbackRowV = v.object({
  deviceId: v.id("devices"),
  /** The current track, its index and the window's length, sealed; null from a device without the vault key. */
  content: v.union(sealedV, v.null()),
  queueVersion: v.number(),
  anchor: storedAnchorV,
  /** Server ms of the last publish. */
  updatedAt: v.number(),
});

/** Validates an anchor and stamps `positionAt` with the server clock (a client estimate is kept if recent). */
export function stampAnchor(anchor: AnchorInput, now: number): Doc<"playback">["anchor"] {
  checkFinite(anchor.positionMs, "positionMs", { min: 0, max: 24 * 3600_000 });
  checkFinite(anchor.rate, "rate", { min: 0, max: 4 });
  checkFinite(anchor.volume, "volume", { min: 0, max: 1 });
  if (anchor.durationMs !== undefined) checkFinite(anchor.durationMs, "durationMs", { min: 0, max: 24 * 3600_000 });
  const claimed = anchor.positionAt === undefined ? now : checkFinite(anchor.positionAt, "positionAt");
  return { ...anchor, positionAt: Math.min(now, Math.max(now - 10_000, claimed)) };
}

export async function libraryOf(ctx: MutationCtx, caller: Caller): Promise<Doc<"libraries">> {
  const library = await ctx.db.get(caller.libraryId);
  if (library === null) fail("notFound", "No such library.");
  return library;
}

/**
 * Publishes the caller's player state. `content`:
 * - `{ playback, queue }` replaces what plays (the current track with its index and the window's length, and the
 *   queue window), both sealed under the vault key. Send it when the queue window or the current index changed.
 * - `null` says this device publishes no content (it doesn't hold the key): any it published before is dropped.
 * - left out, the stored content is kept (play/pause, seek, the 20 s refresh).
 * Content can't be published in the clear: the validators take only sealed fields.
 */
export const publish = mutation({
  args: {
    token: v.string(),
    anchor: anchorV,
    content: v.optional(v.union(v.null(), v.object({ playback: sealedV, queue: sealedV }))),
  },
  returns: v.object({ serverNow: serverNowV, positionAt: v.number(), queueVersion: v.number() }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const now = Date.now();
    const anchor = stampAnchor(args.anchor, now);
    const deviceId = caller.device._id;

    const [existing, existingQueue] = await Promise.all([
      ctx.db.query("playback").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).unique(),
      ctx.db.query("queues").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).unique(),
    ]);
    let content = existing?.content;
    let version = existing?.queueVersion ?? existingQueue?.version ?? 0;
    if (args.content === null) {
      if (content !== undefined || existingQueue !== null) version += 1;
      content = undefined;
      if (existingQueue !== null) await ctx.db.delete(existingQueue._id);
    } else if (args.content !== undefined) {
      const library = await libraryOf(ctx, caller);
      const policy: KeyPolicy = { kind: "currentOrPrevious", now };
      const playback = checkSealed(args.content.playback, "playback", library, policy);
      const queue = checkSealed(args.content.queue, "queue", library, policy);
      if (playback.keyId !== queue.keyId) fail("invalidArgument", "The track and the queue are sealed with different keys.");
      version += 1;
      content = playback;
      const row = { libraryId: caller.libraryId, deviceId, content: queue, version };
      if (existingQueue === null) await ctx.db.insert("queues", row);
      else await ctx.db.replace(existingQueue._id, row);
    }

    const row = { libraryId: caller.libraryId, deviceId, content, queueVersion: version, anchor, updatedAt: now };
    if (existing === null) await ctx.db.insert("playback", row);
    else await ctx.db.replace(existing._id, row);
    await ctx.db.patch(deviceId, { lastSeenAt: now });
    return { serverNow: now, positionAt: anchor.positionAt, queueVersion: version };
  },
});

/** The caller has nothing loaded any more (queue cleared). */
export const clear = mutation({
  args: { token: v.string() },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const deviceId = caller.device._id;
    const rows = await Promise.all([
      ctx.db.query("playback").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).collect(),
      ctx.db.query("queues").withIndex("by_device", (q) => q.eq("deviceId", deviceId)).collect(),
    ]);
    for (const row of rows.flat()) await ctx.db.delete(row._id);
    return { serverNow: Date.now() };
  },
});

/** Every device's playback row in the caller's library (including the caller's own). */
export const list = query({
  args: { token: v.string() },
  returns: v.array(playbackRowV),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const rows = await ctx.db
      .query("playback")
      .withIndex("by_library", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    return rows.map((r) => ({
      deviceId: r.deviceId,
      content: r.content ?? null,
      queueVersion: r.queueVersion,
      anchor: r.anchor,
      updatedAt: r.updatedAt,
    }));
  },
});

/** The sealed queue window of a device in the caller's library, or null when it published none. */
export const queue = query({
  args: { token: v.string(), deviceId: v.id("devices") },
  returns: v.union(v.null(), v.object({ content: sealedV, version: v.number() })),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    await deviceInLibrary(ctx, caller, args.deviceId);
    const row = await ctx.db.query("queues").withIndex("by_device", (q) => q.eq("deviceId", args.deviceId)).unique();
    return row === null ? null : { content: row.content, version: row.version };
  },
});
