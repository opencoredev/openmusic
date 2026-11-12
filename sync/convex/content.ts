// What people listen to and search for reaches the server only sealed under the account's vault key (see
// docs/sync-design.md, "What the server can see"). The server stores and relays these blobs and checks their shape,
// size and key fingerprint; it can never read them. Devices seal and open them (Swift `ContentSealing`, C#
// `ContentSealing`), with AAD that binds the library, the writing device, the kind and the vault key, so a blob
// can't be moved between devices, kinds or settings keys.
import type { Doc } from "./_generated/dataModel";
import { checkKeyId, fail } from "./lib";
import type { Sealed } from "./model";

/** What a sealed field holds, each with its own content key (`medley.content.v1.<kind>`) and size bound. */
export type ContentKind = "playback" | "queue" | "command" | "result" | "setting";

/**
 * Upper bounds on `sealed` (base64 characters) per kind. AES-GCM adds 28 bytes; base64 adds a third.
 * - playback: one track with its artwork, index and window length.
 * - queue / command: a window of up to 121 queue entries.
 * - result: one short message.
 * - setting: a value of up to 32 KB of JSON.
 */
export const SEALED_MAX: Record<ContentKind, number> = {
  playback: 16 * 1024,
  queue: 512 * 1024,
  command: 512 * 1024,
  result: 2 * 1024,
  setting: 44 * 1024,
};

/** 12-byte nonce + 16-byte tag + at least one byte, base64. */
const SEALED_MIN = 40;

/** How long blobs sealed under the key a rotation replaced are still taken (holders take the new key within seconds). */
export const PREVIOUS_KEY_GRACE_MS = 10 * 60_000;

/** Which vault keys a write may be sealed with. */
export type KeyPolicy =
  /** The library's key only: settings, which a rotation re-seals in the same transaction. */
  | { kind: "current" }
  /**
   * The library's key, or the key the last rotation replaced for `PREVIOUS_KEY_GRACE_MS`: what a device publishes
   * about itself (playback, queue, commands and their results). A holder that hasn't taken the rotated key yet keeps
   * publishing under the old one for a moment; readers holding the new key ignore those blobs until it re-seals.
   */
  | { kind: "currentOrPrevious"; now: number };

/**
 * Checks a sealed field's shape (never its content): version 1, a key fingerprint the library accepts under `policy`,
 * and base64 of a plausible length for `kind`. Throws `invalidArgument` for a malformed blob and `forbidden` for a key
 * the library doesn't use (a library without a key takes no content at all).
 */
export function checkSealed(sealed: Sealed, kind: ContentKind, library: Doc<"libraries">, policy: KeyPolicy): Sealed {
  const keyId = checkKeyId(sealed.keyId);
  const text = sealed.sealed;
  if (text.length < SEALED_MIN || text.length > SEALED_MAX[kind] || text.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(text)) {
    fail("invalidArgument", `A sealed ${kind} is base64 of ${SEALED_MIN} to ${SEALED_MAX[kind]} characters.`);
  }
  if (!acceptsKey(library, keyId, policy)) fail("forbidden", "This data is sealed with a key your account doesn't use.");
  return { v: 1, keyId, sealed: text };
}

export function acceptsKey(library: Doc<"libraries">, keyId: string, policy: KeyPolicy): boolean {
  if (library.keyId === undefined) return false;
  if (keyId === library.keyId) return true;
  switch (policy.kind) {
    case "current":
      return false;
    case "currentOrPrevious":
      return library.previousKey !== undefined && library.previousKey.keyId === keyId && library.previousKey.until > policy.now;
    default: {
      const _exhaustive: never = policy;
      return _exhaustive;
    }
  }
}
