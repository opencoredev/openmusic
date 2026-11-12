import { ConvexError } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx } from "./_generated/server";
import { LIMITS, type DeviceInfo } from "./model";

// MARK: - Errors

/** Error codes clients can switch on (`ConvexError.data.code`). */
export type SyncErrorCode =
  /** No Clerk identity came with the call (signed out, or the token expired). Refresh the token and retry. */
  | "unauthenticated"
  /** The device token is unknown, removed, or belongs to another user's devices. The device is signed out. */
  | "unauthorized"
  | "notFound"
  | "invalidArgument"
  | "forbidden"
  /** Too many requests from this client (or everyone); `retryAfterMs` says when to try again. */
  | "rateLimited"
  /** A vault write based on an older revision than the stored one. `revision` is the stored one. */
  | "conflict";

export function fail(code: SyncErrorCode, message: string, extra?: Record<string, number>): never {
  throw new ConvexError({ code, message, ...extra });
}

// MARK: - Crypto

const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return hex(new Uint8Array(digest));
}

// MARK: - Auth

/** A Clerk user, as `identity.tokenIdentifier` (issuer and subject). Only `requireOwner` makes one. */
export type Owner = string & { readonly __brand: "Owner" };

function isOwner(text: string): text is Owner {
  return text.length > 0;
}

/** The signed-in Clerk user. Throws `unauthenticated` without one. */
export async function requireOwner(ctx: QueryCtx): Promise<Owner> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null || !isOwner(identity.tokenIdentifier)) fail("unauthenticated", "Sign in to sync.");
  return identity.tokenIdentifier;
}

/** The user's library, or null before their first device registered. */
export async function libraryOf(ctx: QueryCtx, owner: Owner): Promise<Doc<"libraries"> | null> {
  return await ctx.db
    .query("libraries")
    .withIndex("by_owner", (q) => q.eq("owner", owner))
    .unique();
}

export type Caller = { device: Doc<"devices">; libraryId: Id<"libraries">; owner: Owner };

export function checkToken(token: string): string {
  if (token.length < LIMITS.minTokenLength || token.length > LIMITS.maxTokenLength || !/^[A-Za-z0-9_-]+$/.test(token)) {
    fail("invalidArgument", "The device token must be 32 to 100 base64url characters.");
  }
  return token;
}

/**
 * Resolves the calling device from its token, for the signed-in user only. Throws `unauthenticated` without a
 * Clerk identity, and `unauthorized` for a token that is unknown, removed, or a device of another user.
 */
export async function authenticate(ctx: QueryCtx, token: string): Promise<Caller> {
  const owner = await requireOwner(ctx);
  if (token.length < 20 || token.length > LIMITS.maxTokenLength) fail("unauthorized", "Unknown device.");
  const tokenHash = await sha256Hex(token);
  const device = await ctx.db
    .query("devices")
    .withIndex("by_tokenHash", (q) => q.eq("tokenHash", tokenHash))
    .unique();
  if (device === null) fail("unauthorized", "Unknown device.");
  const library = await ctx.db.get(device.libraryId);
  if (library === null || library.owner !== owner) fail("unauthorized", "Unknown device.");
  return { device, libraryId: device.libraryId, owner };
}

/** A device in the caller's library. Devices of other libraries look the same as missing ones. */
export async function deviceInLibrary(ctx: QueryCtx, caller: Caller, deviceId: Id<"devices">): Promise<Doc<"devices">> {
  const device = await ctx.db.get(deviceId);
  if (device === null || device.libraryId !== caller.libraryId) fail("notFound", "No such device in this library.");
  return device;
}

/** The key row of a device (null only for devices from before accounts). */
export async function deviceKeyOf(ctx: QueryCtx, deviceId: Id<"devices">): Promise<Doc<"deviceKeys"> | null> {
  return await ctx.db
    .query("deviceKeys")
    .withIndex("by_device", (q) => q.eq("deviceId", deviceId))
    .unique();
}

// MARK: - Input checks

export function checkName(name: string): string {
  const trimmed = name.trim();
  if (trimmed.length === 0 || trimmed.length > LIMITS.maxNameLength) {
    fail("invalidArgument", `Names are 1 to ${LIMITS.maxNameLength} characters.`);
  }
  return trimmed;
}

export function checkDeviceInfo(info: DeviceInfo): DeviceInfo {
  const short = (s: string, field: string): string => {
    if (s.length > LIMITS.maxShortString) fail("invalidArgument", `${field} is too long.`);
    return s;
  };
  return {
    name: checkName(info.name),
    platform: info.platform,
    model: short(info.model, "model"),
    appVersion: short(info.appVersion, "appVersion"),
  };
}

/** A key fingerprint: 32 lowercase hex characters (the client sends SHA-256 of the key, truncated). */
export function checkKeyId(keyId: string): string {
  if (!/^[0-9a-f]{32}$/.test(keyId)) fail("invalidArgument", "keyId must be 32 hex characters.");
  return keyId;
}

/** Exactly 32 bytes, base64: X25519 public keys, exchange commitments and nonces. */
export function checkBytes32(text: string, field: string): string {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(text)) fail("invalidArgument", `${field} must be 32 bytes, base64.`);
  return text;
}

/** A base64 X25519 public key: exactly 32 bytes. */
export function checkPublicKey(text: string): string {
  return checkBytes32(text, "publicKey");
}

export function checkBase64(text: string, field: string, maxBytes: number): string {
  if (text.length === 0 || text.length > maxBytes) fail("invalidArgument", `${field} must be 1 to ${maxBytes} characters.`);
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(text)) fail("invalidArgument", `${field} must be base64.`);
  return text;
}

export function checkFinite(value: number, field: string, range?: { min: number; max: number }): number {
  if (!Number.isFinite(value)) fail("invalidArgument", `${field} must be a finite number.`);
  if (range && (value < range.min || value > range.max)) {
    fail("invalidArgument", `${field} must be within ${range.min}...${range.max}.`);
  }
  return value;
}

/**
 * The public shape of a device. Never includes the token hash or a wrapped key. `publicKey` is the device's X25519
 * key (public by nature: holders wrap the vault key to it, and a rotation wraps the new key to every holder).
 * `exchange` is shown only while the device asks for the vault key, for the holders that answer it.
 */
export function publicDevice(device: Doc<"devices">, key: Doc<"deviceKeys"> | null) {
  return {
    id: device._id,
    name: device.name,
    platform: device.platform,
    model: device.model,
    appVersion: device.appVersion,
    createdAt: device.createdAt,
    lastSeenAt: device.lastSeenAt,
    keyState: key?.state.kind ?? null,
    publicKey: key?.publicKey ?? null,
    exchange: key?.state.kind === "requested" ? (key.state.exchange ?? null) : null,
  };
}
