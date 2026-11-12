import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalMutation } from "./_generated/server";
import { drainLibrary } from "./cleanup";
import { LIMITS } from "./model";

/**
 * Cron, and scheduled right away whenever a library is retired: deletes owner-less libraries with everything
 * they had (devices, key rows, playback, queues, commands, vault, settings and remembered settings writes), then
 * invites and the old redeem counters. Owner-less libraries are the ones pairing by invite code left behind, and
 * libraries retired since (the last device left, or they expired). Their tokens already stop working, because
 * `authenticate` needs a library owned by the signed-in user.
 *
 * One run deletes at most `LIMITS.librarySweepRows` rows in all, however large a library is, so it stays far inside
 * Convex's transaction limits. A library too big for one run is finished by the next: the run schedules another
 * while there is more to do, and the work left is whatever is still in the database.
 */
export const sweep = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number(), more: v.boolean() }),
  handler: async (ctx) => {
    let budget = LIMITS.librarySweepRows;
    let deleted = 0;
    let more = false;
    while (budget > 0) {
      const library = await ctx.db
        .query("libraries")
        .withIndex("by_owner", (q) => q.eq("owner", undefined))
        .first();
      if (library === null) break;
      const run = await drainLibrary(ctx, library._id, budget);
      deleted += run.deleted;
      budget -= run.deleted;
      if (!run.done) {
        more = true;
        break;
      }
    }
    // Invites, then counters, each from what is left of the run's budget after everything deleted before it.
    for (const table of ["invites", "redeemFailures"] as const) {
      const batch = Math.min(LIMITS.sweepBatch, budget);
      if (batch <= 0) {
        more = true;
        break;
      }
      const rows = await ctx.db.query(table).take(batch);
      for (const row of rows) await ctx.db.delete(row._id);
      deleted += rows.length;
      budget -= rows.length;
      more = more || rows.length === batch;
    }
    if (more) await ctx.scheduler.runAfter(0, internal.legacy.sweep, {});
    return { deleted, more };
  },
});
