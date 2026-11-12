import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalMutation, type MutationCtx } from "./_generated/server";
import { LIMITS } from "./model";

/**
 * A named rate limit. Fixed window: blocked once `limit` hits land inside one `windowMs` window. With `backoff`,
 * reaching the limit instead blocks for `baseMs`, doubling with every further hit in the window, up to `maxMs`.
 */
export type Limit = {
  key: string;
  windowMs: number;
  limit: number;
  backoff?: { baseMs: number; maxMs: number };
};

export type ThrottleVerdict = { kind: "allowed" } | { kind: "blocked"; retryAfterMs: number };

function windowStart(limit: Limit, now: number): number {
  return now - (now % limit.windowMs);
}

async function row(ctx: MutationCtx, limit: Limit, now: number) {
  const start = windowStart(limit, now);
  return await ctx.db
    .query("throttles")
    .withIndex("by_key", (q) => q.eq("key", limit.key).eq("windowStart", start))
    .unique();
}

/** Whether any of `limits` is exhausted right now, and for how long. */
export async function check(ctx: MutationCtx, limits: readonly Limit[], now: number): Promise<ThrottleVerdict> {
  let retryAfterMs = 0;
  for (const limit of limits) {
    const r = await row(ctx, limit, now);
    if (r === null) continue;
    if (limit.backoff !== undefined) {
      if (r.blockedUntil !== undefined && r.blockedUntil > now) retryAfterMs = Math.max(retryAfterMs, r.blockedUntil - now);
    } else if (r.count >= limit.limit) {
      retryAfterMs = Math.max(retryAfterMs, windowStart(limit, now) + limit.windowMs - now);
    }
  }
  return retryAfterMs > 0 ? { kind: "blocked", retryAfterMs } : { kind: "allowed" };
}

/** Counts one hit against each of `limits`. */
export async function hit(ctx: MutationCtx, limits: readonly Limit[], now: number): Promise<void> {
  for (const limit of limits) {
    const start = windowStart(limit, now);
    const existing = await row(ctx, limit, now);
    const count = (existing?.count ?? 0) + 1;
    let blockedUntil = existing?.blockedUntil;
    if (limit.backoff !== undefined && count >= limit.limit) {
      const block = Math.min(limit.backoff.maxMs, limit.backoff.baseMs * 2 ** (count - limit.limit));
      blockedUntil = now + block;
    }
    const expiresAt = Math.max(start + limit.windowMs, blockedUntil ?? 0);
    if (existing === null) await ctx.db.insert("throttles", { key: limit.key, windowStart: start, count, blockedUntil, expiresAt });
    else await ctx.db.patch(existing._id, { count, blockedUntil, expiresAt });
  }
}

/**
 * Cron: deletes counters whose window and lockout are over. Works in batches; while a batch comes back full it
 * schedules itself again right away, so a backlog drains completely instead of growing by whatever one run can't
 * delete.
 */
export const sweep = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number(), more: v.boolean() }),
  handler: async (ctx) => {
    const now = Date.now();
    const batch = LIMITS.sweepBatch;
    const stale = await ctx.db
      .query("throttles")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", now))
      .take(batch);
    for (const r of stale) await ctx.db.delete(r._id);
    const more = stale.length === batch;
    if (more) await ctx.scheduler.runAfter(0, internal.throttle.sweep, {});
    return { deleted: stale.length, more };
  },
});
