import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { mutation, query, type MutationCtx } from "./_generated/server";
import type { Infer } from "convex/values";
import { NO_KEY } from "./cleanup";
import { authenticate, checkBase64, checkFinite, checkKeyId, fail } from "./lib";
import { LIMITS, providerV, serverNowV } from "./model";

export const vaultEntryV = v.object({
  provider: providerV,
  /** AES-GCM ciphertext (base64) under the library key; null after "sign out everywhere", or when `cleared`. */
  sealed: v.union(v.string(), v.null()),
  /**
   * The account lost its vault key and this sign-in with it (no device that could open it was left). Not a
   * sign-out: devices keep their own sign-in and upload it again under the new key, at the next revision.
   */
  cleared: v.boolean(),
  keyId: v.string(),
  /**
   * Counts every write of this provider's row, sign-outs included (0 for a row from before revisions). Clients
   * seal with the revision the write will get in the authenticated data, and never apply a lower one.
   */
  revision: v.number(),
  updatedAt: v.number(),
  updatedBy: v.id("devices"),
});

const writeResultV = v.object({ updatedAt: v.number(), revision: v.number(), serverNow: serverNowV });

type Provider = Infer<typeof providerV>;

/** The library's sealed sign-ins, one entry per provider that was ever synced. */
export const list = query({
  args: { token: v.string() },
  returns: v.array(vaultEntryV),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const rows = await ctx.db
      .query("vault")
      .withIndex("by_library_provider", (q) => q.eq("libraryId", caller.libraryId))
      .collect();
    return rows.map((r) => ({
      provider: r.provider,
      sealed: r.sealed ?? null,
      cleared: r.cleared === true,
      keyId: r.keyId,
      revision: r.revision ?? 0,
      updatedAt: r.updatedAt,
      updatedBy: r.updatedBy,
    }));
  },
});

function checkRevision(value: number | undefined): number | undefined {
  if (value === undefined) return undefined;
  checkFinite(value, "baseRevision", { min: 0, max: Number.MAX_SAFE_INTEGER });
  if (!Number.isInteger(value)) fail("invalidArgument", "baseRevision must be an integer.");
  return value;
}

function conflict(current: number): never {
  fail("conflict", "Another device changed this sign-in first.", { revision: current });
}

/**
 * Stores a provider's sealed sign-in for the whole library. `keyId` must match the library's key fingerprint, so a
 * device holding the wrong key can't overwrite readable data.
 *
 * `baseRevision` is the revision the writer last saw. The write is accepted only when it still is the stored one
 * (compare and swap), and gets revision `baseRevision + 1`; otherwise it throws `conflict` with the stored
 * `revision`. Retrying a write that already landed (same device, same ciphertext, stored revision is
 * `baseRevision + 1`) returns that write again.
 *
 * Writers from before revisions (no `baseRevision`) seal in the v1 format, which current clients open only at
 * revision 0. Their writes therefore keep a row at revision 0, and are refused (`conflict`) once the row has a
 * revision (a current client migrated or wrote it) or is a "sign out everywhere" tombstone.
 */
export const put = mutation({
  args: { token: v.string(), provider: providerV, sealed: v.string(), keyId: v.string(), baseRevision: v.optional(v.number()) },
  returns: writeResultV,
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const keyId = checkKeyId(args.keyId);
    const sealed = checkBase64(args.sealed, "sealed", LIMITS.maxSealedBytes);
    const baseRevision = checkRevision(args.baseRevision);
    const library = await ctx.db.get(caller.libraryId);
    if (library === null) fail("notFound", "No such library.");
    if (library.keyId !== keyId) fail("forbidden", "This data is sealed with a key the library doesn't use.");
    if (library.keyRotation !== undefined) fail("forbidden", "Your account's key is being replaced. Sign-ins sync again in a moment.");
    const existing = await row(ctx, caller.libraryId, args.provider);
    const current = existing?.revision ?? 0;
    if (baseRevision === undefined) {
      if (existing !== null && (existing.sealed === undefined || current > 0)) conflict(current);
      return await write(ctx, existing, {
        libraryId: caller.libraryId,
        deviceId: caller.device._id,
        provider: args.provider,
        sealed,
        keyId,
        revision: 0,
      });
    } else {
      if (existing !== null && isRetry(existing, caller.device._id, baseRevision, sealed)) {
        return { updatedAt: existing.updatedAt, revision: current, serverNow: Date.now() };
      }
      if (baseRevision !== current) conflict(current);
    }
    return await write(ctx, existing, { libraryId: caller.libraryId, deviceId: caller.device._id, provider: args.provider, sealed, keyId });
  },
});

/**
 * "Sign out everywhere": leaves a tombstone so every device signs out of this provider, at the next revision.
 * With `baseRevision` it is checked like `put` (a retry of the same sign-out returns it again); without, it always
 * applies.
 */
export const signOutEverywhere = mutation({
  args: { token: v.string(), provider: providerV, baseRevision: v.optional(v.number()) },
  returns: writeResultV,
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const baseRevision = checkRevision(args.baseRevision);
    const library = await ctx.db.get(caller.libraryId);
    if (library === null) fail("notFound", "No such library.");
    const existing = await row(ctx, caller.libraryId, args.provider);
    const current = existing?.revision ?? 0;
    if (baseRevision !== undefined) {
      if (existing !== null && isRetry(existing, caller.device._id, baseRevision, undefined)) {
        return { updatedAt: existing.updatedAt, revision: current, serverNow: Date.now() };
      }
      if (baseRevision !== current) conflict(current);
    }
    const keyId = library.keyId ?? NO_KEY;
    return await write(ctx, existing, { libraryId: caller.libraryId, deviceId: caller.device._id, provider: args.provider, sealed: undefined, keyId });
  },
});

function isRetry(existing: Doc<"vault">, deviceId: Id<"devices">, baseRevision: number, sealed: string | undefined): boolean {
  return existing.updatedBy === deviceId && existing.sealed === sealed && (existing.revision ?? 0) === baseRevision + 1;
}

async function row(ctx: MutationCtx, libraryId: Id<"libraries">, provider: Provider): Promise<Doc<"vault"> | null> {
  return await ctx.db
    .query("vault")
    .withIndex("by_library_provider", (q) => q.eq("libraryId", libraryId).eq("provider", provider))
    .unique();
}

async function write(
  ctx: MutationCtx,
  existing: Doc<"vault"> | null,
  data: {
    libraryId: Id<"libraries">;
    deviceId: Id<"devices">;
    provider: Provider;
    sealed: string | undefined;
    keyId: string;
    /** Only for writers from before revisions, whose rows stay at 0. Otherwise the stored revision plus one. */
    revision?: 0;
  },
): Promise<{ updatedAt: number; revision: number; serverNow: number }> {
  const now = Date.now();
  // Server time orders writes; a write in the same millisecond as the stored one still moves it forward.
  const updatedAt = existing === null ? now : Math.max(now, existing.updatedAt + 1);
  const revision = data.revision ?? (existing?.revision ?? 0) + 1;
  const doc = {
    libraryId: data.libraryId,
    provider: data.provider,
    sealed: data.sealed,
    keyId: data.keyId,
    revision,
    updatedAt,
    updatedBy: data.deviceId,
  };
  if (existing === null) await ctx.db.insert("vault", doc);
  else await ctx.db.replace(existing._id, doc);
  return { updatedAt, revision, serverNow: now };
}
