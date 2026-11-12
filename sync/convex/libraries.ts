import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { expireLibrary } from "./cleanup";

/**
 * Cron: deletes accounts' sync data nobody has used for 60 days, with every row it owns. Harmless for someone
 * coming back later: their next launch registers the device again, and devices holding the vault key upload
 * their sign-ins again.
 */
export const sweepExpired = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number(), kept: v.number() }),
  handler: async (ctx) => {
    const now = Date.now();
    const due = await ctx.db
      .query("libraries")
      .withIndex("by_expiresAt", (q) => q.gt("expiresAt", 0).lt("expiresAt", now))
      .take(50);
    let deleted = 0;
    let kept = 0;
    for (const library of due) {
      // Owner-less (paired) libraries are the legacy sweep's.
      if (library.owner === undefined) continue;
      if ((await expireLibrary(ctx, library, now)) === "deleted") deleted += 1;
      else kept += 1;
    }
    return { deleted, kept };
  },
});
