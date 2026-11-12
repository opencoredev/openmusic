import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import type { Doc } from "./_generated/dataModel";
import { checkSealed, type KeyPolicy } from "./content";
import { authenticate, checkFinite, deviceInLibrary, fail } from "./lib";
import { commandResultV, commandV, LIMITS, serverNowV, storedCommandV, type Command, type CommandResult, type StoredCommand } from "./model";
import { libraryOf, stampAnchor } from "./playback";

const commandKindV = v.union(
  v.literal("play"),
  v.literal("pause"),
  v.literal("toggle"),
  v.literal("next"),
  v.literal("previous"),
  v.literal("stop"),
  v.literal("seek"),
  v.literal("setVolume"),
  v.literal("takeOver"),
);

function checkCommand(command: Command, library: Doc<"libraries">, now: number): StoredCommand {
  switch (command.kind) {
    case "play":
    case "pause":
    case "toggle":
    case "next":
    case "previous":
    case "stop":
      return command;
    case "seek":
      checkFinite(command.positionMs, "positionMs", { min: 0, max: 24 * 3600_000 });
      return command;
    case "setVolume":
      checkFinite(command.volume, "volume", { min: 0, max: 1 });
      return command;
    case "takeOver":
      return {
        kind: "takeOver",
        anchor: stampAnchor(command.anchor, now),
        content: checkSealed(command.content, "command", library, { kind: "currentOrPrevious", now }),
      };
    default: {
      const _exhaustive: never = command;
      return _exhaustive;
    }
  }
}

/**
 * Sends a command to another device of the caller's library. It expires after 2 minutes if not acked.
 * `clientId` (1 to 64 characters, unique per command from this device) makes the send idempotent: sending the
 * same `clientId` again returns the command already stored instead of queueing it twice.
 */
export const send = mutation({
  args: { token: v.string(), toDeviceId: v.id("devices"), command: commandV, clientId: v.optional(v.string()) },
  returns: v.object({ commandId: v.id("commands"), expiresAt: v.number(), serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const target = await deviceInLibrary(ctx, caller, args.toDeviceId);
    if (target._id === caller.device._id) fail("invalidArgument", "A device can't send commands to itself.");
    const now = Date.now();
    const clientId = args.clientId;
    if (clientId !== undefined) {
      if (clientId.length === 0 || clientId.length > 64) fail("invalidArgument", "clientId is 1 to 64 characters.");
      const sent = await ctx.db
        .query("commands")
        .withIndex("by_from_clientId", (q) => q.eq("fromDeviceId", caller.device._id).eq("clientId", clientId))
        .first();
      if (sent !== null) return { commandId: sent._id, expiresAt: sent.expiresAt, serverNow: now };
    }
    const expiresAt = now + LIMITS.commandTtlMs;
    const command = checkCommand(args.command, await libraryOf(ctx, caller), now);
    const commandId = await ctx.db.insert("commands", {
      libraryId: caller.libraryId,
      fromDeviceId: caller.device._id,
      toDeviceId: target._id,
      command,
      createdAt: now,
      expiresAt,
      clientId,
    });
    await ctx.db.patch(caller.device._id, { lastSeenAt: now });
    return { commandId, expiresAt, serverNow: now };
  },
});

export const incomingCommandV = v.object({
  id: v.id("commands"),
  fromDeviceId: v.id("devices"),
  command: storedCommandV,
  createdAt: v.number(),
  expiresAt: v.number(),
});

/**
 * Commands for the caller that aren't acked yet, oldest first. Expired ones may still be listed until the
 * cron removes them; clients skip any with `expiresAt` in the past.
 */
export const incoming = query({
  args: { token: v.string() },
  returns: v.array(incomingCommandV),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const rows = await ctx.db
      .query("commands")
      .withIndex("by_to_pending", (q) => q.eq("toDeviceId", caller.device._id).eq("ackedAt", undefined))
      .order("asc")
      .take(50);
    return rows.map((r) => ({
      id: r._id,
      fromDeviceId: r.fromDeviceId,
      command: r.command,
      createdAt: r.createdAt,
      expiresAt: r.expiresAt,
    }));
  },
});

/** A result's shape: `reason` only on a failure, a sealed message only from a device that can seal one. */
function checkResult(result: CommandResult, library: Doc<"libraries">, now: number): CommandResult {
  if (result.ok && result.reason !== undefined) fail("invalidArgument", "A success has no failure reason.");
  const policy: KeyPolicy = { kind: "currentOrPrevious", now };
  return {
    ok: result.ok,
    reason: result.ok ? undefined : (result.reason ?? "failed"),
    content: result.content === undefined ? undefined : checkSealed(result.content, "result", library, policy),
  };
}

/**
 * Acknowledges a command sent to the caller, with what happened. Acking twice keeps the first result. A failure says
 * why as a code (`reason`); its message, which may name a song, comes sealed (`content`) or not at all.
 */
export const ack = mutation({
  args: { token: v.string(), commandId: v.id("commands"), result: commandResultV },
  returns: v.object({ serverNow: serverNowV }),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const now = Date.now();
    const command = await ctx.db.get(args.commandId);
    if (command === null || command.toDeviceId !== caller.device._id) fail("notFound", "No such command for this device.");
    if (command.ackedAt === undefined) {
      await ctx.db.patch(command._id, { ackedAt: now, result: checkResult(args.result, await libraryOf(ctx, caller), now) });
    }
    await ctx.db.patch(caller.device._id, { lastSeenAt: now });
    return { serverNow: now };
  },
});

export const outgoingCommandV = v.object({
  id: v.id("commands"),
  toDeviceId: v.id("devices"),
  kind: commandKindV,
  createdAt: v.number(),
  expiresAt: v.number(),
  ackedAt: v.optional(v.number()),
  result: v.optional(commandResultV),
});

/** The caller's most recent commands (newest first) and whether each was acked. */
export const outgoing = query({
  args: { token: v.string() },
  returns: v.array(outgoingCommandV),
  handler: async (ctx, args) => {
    const caller = await authenticate(ctx, args.token);
    const rows = await ctx.db
      .query("commands")
      .withIndex("by_from", (q) => q.eq("fromDeviceId", caller.device._id))
      .order("desc")
      .take(LIMITS.outgoingLimit);
    return rows.map((r) => ({
      id: r._id,
      toDeviceId: r.toDeviceId,
      kind: r.command.kind,
      createdAt: r.createdAt,
      expiresAt: r.expiresAt,
      ackedAt: r.ackedAt,
      result: r.result,
    }));
  },
});

/** Cron: deletes commands past their expiry, acked or not. */
export const sweep = internalMutation({
  args: {},
  returns: v.object({ deleted: v.number() }),
  handler: async (ctx) => {
    const expired = await ctx.db
      .query("commands")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", Date.now()))
      .take(500);
    for (const row of expired) await ctx.db.delete(row._id);
    return { deleted: expired.length };
  },
});
