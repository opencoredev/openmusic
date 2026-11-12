/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import type { FunctionArgs } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import schema from "./schema";
import { sha256Hex } from "./lib";
import { readAuthConfig } from "./config";
import { LIMITS, type DeviceInfo, type Sealed } from "./model";

const modules = import.meta.glob("./**/*.ts");

const mac = { name: "Studio Mac", platform: "mac" as const, model: "Mac16,10", appVersion: "1.0" };
const phone = { name: "iPhone", platform: "ios" as const, model: "iPhone17,1", appVersion: "1.0" };

const LEO = { subject: "user_leo", issuer: "https://clerk.openmusic.test", tokenIdentifier: "https://clerk.openmusic.test|user_leo" };
const ANNA = { subject: "user_anna", issuer: "https://clerk.openmusic.test", tokenIdentifier: "https://clerk.openmusic.test|user_anna" };

const KEY_A = "a".repeat(32);
const KEY_B = "b".repeat(32);
const KEY_C = "c".repeat(32);

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
/** A device token as devices make them: 32 random bytes, base64url. */
const newToken = (): string => base64Url(crypto.getRandomValues(new Uint8Array(32)));
/** 32 random bytes, base64: the shape of X25519 public keys, exchange commitments and nonces. */
const random32 = (): string => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
const newPublicKey = random32;

type Accessor = ReturnType<ReturnType<typeof convexTest>["withIdentity"]>;
type Registered = { token: string; publicKey: string; deviceId: Id<"devices">; libraryId: Id<"libraries">; keyId: string | null; keyState: string; keyRevision: number };

async function register(t: Accessor, device: DeviceInfo, keyId?: string, token = newToken()): Promise<Registered> {
  const publicKey = newPublicKey();
  const r = await t.mutation(api.account.register, { createdAt: Date.now(), token, device, publicKey, keyId });
  return { token, publicKey, ...r };
}

/** The key revision of the library the device with `token` is in: what that device would have just seen. */
async function revisionSeenBy(t: Accessor, token: string): Promise<number> {
  return await t.run(async (ctx) => {
    const tokenHash = await sha256Hex(token);
    const device = (await ctx.db.query("devices").collect()).find((d) => d.tokenHash === tokenHash);
    const library = device === undefined ? null : await ctx.db.get(device.libraryId);
    return library?.keyRevision ?? 0;
  });
}

/** `keys:claim` decided on the current state (the revision the device just saw). */
async function claimNow(t: Accessor, args: Omit<FunctionArgs<typeof api.keys.claim>, "keyRevision">) {
  return await t.mutation(api.keys.claim, { ...args, keyRevision: await revisionSeenBy(t, args.token) });
}

/** `keys:release` decided on the current state (the revision the device just saw). */
async function releaseNow(t: Accessor, args: Omit<FunctionArgs<typeof api.keys.release>, "keyRevision">) {
  return await t.mutation(api.keys.release, { ...args, keyRevision: await revisionSeenBy(t, args.token) });
}

/**
 * A stand-in for a blob a device sealed: the server never opens one, so any base64 of the right length will do. The
 * label is readable here (base64 of it) so tests can tell blobs apart; real blobs are AES-GCM output.
 */
function seal(keyId: string, label: string): Sealed {
  return { v: 1, keyId, sealed: btoa(`sealed:${label}`.padEnd(30, ".")) };
}
/** What a device holding the key publishes when its track or queue window changes. */
function content(keyId: string, label = "now") {
  return { playback: seal(keyId, `${label}:track`), queue: seal(keyId, `${label}:queue`) };
}

const anchor = { positionMs: 12_000, isPlaying: true, rate: 1, durationMs: 200_000, volume: 0.8, shuffle: false, repeat: "off" as const };

/** The verification exchange up to the point where both devices show the code: commit, answer, reveal. */
async function exchange(t: Accessor, holder: Registered, asker: Registered) {
  const commitment = random32();
  const holderNonce = random32();
  const nonce = random32();
  await t.mutation(api.keys.request, { token: asker.token, commitment });
  await t.mutation(api.keys.answer, { token: holder.token, deviceId: asker.deviceId, commitment, nonce: holderNonce });
  await t.mutation(api.keys.reveal, { token: asker.token, commitment, nonce });
  return { commitment, holderNonce, nonce };
}

/** The whole approval: the exchange, the holder's grant (after Allow) and the asking device's accept. */
async function approve(t: Accessor, holder: Registered, asker: Registered, keyId: string) {
  const { commitment } = await exchange(t, holder, asker);
  await t.mutation(api.keys.grant, { token: holder.token, deviceId: asker.deviceId, keyId, wrapped: btoa(`wrapped for ${asker.deviceId}`), commitment });
  await t.mutation(api.keys.accept, { token: asker.token, keyId });
}

/** Leo's Mac (holds KEY_A, which it created) and Leo's iPhone (asked for the key and got it). */
async function twoDevices() {
  const base = convexTest(schema, modules);
  const t = base.withIdentity(LEO);
  const a = await register(t, mac, KEY_A);
  const b = await register(t, phone, KEY_B);
  await approve(t, a, b, KEY_A);
  return { base, t, a, b };
}

/** Runs everything scheduled (the library sweep a retired library starts). */
async function settleScheduled(base: ReturnType<typeof convexTest>) {
  await base.finishAllScheduledFunctions(vi.runAllTimers);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-11-03T12:00:00Z"));
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("config", () => {
  test("serves the Clerk publishable key without an identity, or says the server isn't set up", async () => {
    const t = convexTest(schema, modules);
    expect(await t.query(api.config.get, {})).toEqual({ auth: { kind: "notConfigured" } });
    vi.stubEnv("CLERK_PUBLISHABLE_KEY", "pk_test_Y2xlcmsubWVkbGV5LnRlc3Qk");
    expect(await t.query(api.config.get, {})).toEqual({ auth: { kind: "clerk", publishableKey: "pk_test_Y2xlcmsubWVkbGV5LnRlc3Qk" } });
    expect(readAuthConfig("sk_test_secret")).toEqual({ kind: "notConfigured" });
    expect(readAuthConfig("pk_live_bad key")).toEqual({ kind: "notConfigured" });
  });
});

describe("accounts and devices", () => {
  test("every function needs a Clerk identity", async () => {
    const base = convexTest(schema, modules);
    const a = await register(base.withIdentity(LEO), mac, KEY_A);
    const unauthenticated = { data: { code: "unauthenticated" } };
    await expect(base.query(api.devices.list, { token: a.token })).rejects.toMatchObject(unauthenticated);
    await expect(base.mutation(api.devices.heartbeat, { token: a.token })).rejects.toMatchObject(unauthenticated);
    await expect(base.query(api.vault.list, { token: a.token })).rejects.toMatchObject(unauthenticated);
    await expect(base.mutation(api.account.register, { createdAt: Date.now(), token: newToken(), device: phone, publicKey: newPublicKey() })).rejects.toMatchObject(
      unauthenticated,
    );
  });

  test("the first device creates the library and its key; only the token's hash is stored", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    expect(a).toMatchObject({ keyId: KEY_A, keyState: "holder" });
    const [library] = await t.run((ctx) => ctx.db.query("libraries").collect());
    expect(library).toMatchObject({ owner: LEO.tokenIdentifier, keyId: KEY_A });
    const rows = await t.run((ctx) => ctx.db.query("devices").collect());
    expect(rows).toHaveLength(1);
    expect(rows[0].tokenHash).toBe(await sha256Hex(a.token));
    expect(JSON.stringify(rows)).not.toContain(a.token);

    const list = await t.query(api.devices.list, { token: a.token });
    expect(list).toMatchObject({ selfId: a.deviceId, libraryId: a.libraryId, keyId: KEY_A, grant: null });
    expect(list.devices).toEqual([expect.objectContaining({ name: "Studio Mac", keyState: "holder", publicKey: a.publicKey, exchange: null })]);
    expect(JSON.stringify(list)).not.toContain("tokenHash");
  });

  test("registering is idempotent per token, and every device of the user joins the same library", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const retry = await register(t, mac, KEY_A, a.token);
    expect(retry).toMatchObject({ deviceId: a.deviceId, libraryId: a.libraryId, keyState: "holder" });
    const b = await register(t, phone, KEY_B);
    expect(b).toMatchObject({ libraryId: a.libraryId, keyId: KEY_A, keyState: "requested" });
    expect(await t.run((ctx) => ctx.db.query("libraries").collect())).toHaveLength(1);
    const list = await t.query(api.devices.list, { token: a.token });
    expect(list.devices.map((d) => [d.name, d.keyState])).toEqual([
      ["Studio Mac", "holder"],
      ["iPhone", "requested"],
    ]);
    // The asking device's public key is shown, for the holder to wrap to.
    expect(list.devices[1].publicKey).toBe(b.publicKey);
  });

  test("another user can't use, register or see a device's token", async () => {
    const base = convexTest(schema, modules);
    const a = await register(base.withIdentity(LEO), mac, KEY_A);
    const anna = base.withIdentity(ANNA);
    const unauthorized = { data: { code: "unauthorized" } };
    await expect(anna.query(api.devices.list, { token: a.token })).rejects.toMatchObject(unauthorized);
    await expect(anna.mutation(api.playback.clear, { token: a.token })).rejects.toMatchObject(unauthorized);
    await expect(register(anna, mac, KEY_B, a.token)).rejects.toMatchObject(unauthorized);
  });

  test("unknown tokens and malformed input are rejected", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    await expect(t.query(api.devices.list, { token: "x".repeat(43) })).rejects.toThrow(/Unknown device/);
    await expect(t.mutation(api.account.register, { createdAt: Date.now(), token: "short", device: mac, publicKey: newPublicKey() })).rejects.toThrow(/token/);
    await expect(t.mutation(api.account.register, { createdAt: Date.now(), token: newToken(), device: mac, publicKey: "abc" })).rejects.toThrow(/publicKey/);
    await expect(t.mutation(api.account.register, { createdAt: Date.now(), token: newToken(), device: { ...mac, name: " " }, publicKey: newPublicKey() })).rejects.toThrow(
      /Names/,
    );
  });

  test("heartbeat moves lastSeenAt; rename and remove work within the account", async () => {
    const { t, a, b } = await twoDevices();
    vi.advanceTimersByTime(30_000);
    const beat = await t.mutation(api.devices.heartbeat, { token: b.token });
    const list = await t.query(api.devices.list, { token: a.token });
    expect(list.devices.find((d) => d.id === b.deviceId)?.lastSeenAt).toBe(beat.serverNow);

    await t.mutation(api.devices.rename, { token: a.token, deviceId: b.deviceId, name: "  Leo's iPhone " });
    expect((await t.query(api.devices.list, { token: b.token })).devices.map((d) => d.name)).toContain("Leo's iPhone");
    await expect(t.mutation(api.devices.rename, { token: a.token, deviceId: b.deviceId, name: "   " })).rejects.toThrow();

    await t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_A) });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: b.deviceId });
    await expect(t.query(api.devices.list, { token: b.token })).rejects.toMatchObject({ data: { code: "unauthorized" } });
    expect(await t.query(api.playback.list, { token: a.token })).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("queues").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("deviceKeys").collect())).toHaveLength(1);
  });

  test("devices of another user are invisible", async () => {
    const { base, t, a } = await twoDevices();
    const other = await register(base.withIdentity(ANNA), { ...mac, name: "Stranger" }, KEY_C);
    await expect(t.mutation(api.devices.rename, { token: a.token, deviceId: other.deviceId, name: "Mine" })).rejects.toThrow(/No such device/);
    await expect(t.mutation(api.devices.remove, { token: a.token, deviceId: other.deviceId })).rejects.toThrow(/No such device/);
    await expect(t.query(api.playback.queue, { token: a.token, deviceId: other.deviceId })).rejects.toThrow(/No such device/);
    await expect(
      t.mutation(api.keys.grant, { token: a.token, deviceId: other.deviceId, keyId: KEY_A, wrapped: btoa("x"), commitment: random32() }),
    ).rejects.toThrow(/No such device/);
    await expect(
      t.mutation(api.commands.send, { token: a.token, toDeviceId: other.deviceId, command: { kind: "pause" } }),
    ).rejects.toThrow(/No such device/);
  });

  test("a full account makes room by removing the device seen least recently", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const first = await register(t, mac, KEY_A);
    const devices: Registered[] = [first];
    for (let i = 1; i < 32; i++) {
      // Two minutes apart, so the 32 registrations span two rate-limit windows.
      vi.advanceTimersByTime(120_000);
      devices.push(await register(t, { ...phone, name: `Phone ${i}` }, KEY_A));
    }
    // Keep the first one fresh; device 1 is now the stalest.
    await t.mutation(api.devices.heartbeat, { token: first.token });
    vi.advanceTimersByTime(3600_000);
    const newest = await register(t, { ...phone, name: "Newest" }, KEY_A);
    const list = await t.query(api.devices.list, { token: newest.token });
    expect(list.devices).toHaveLength(32);
    expect(list.devices.map((d) => d.name)).not.toContain("Phone 1");
    await expect(t.query(api.devices.list, { token: devices[1].token })).rejects.toThrow(/Unknown device/);
  });

  test("a registration sent again after its answer was lost gets the same device and key, past the rate limit too", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const first = await register(t, mac, KEY_A);
    // The device never saw that answer and sends the same registration again, after the user used up the hour.
    for (let i = 0; i < LIMITS.registerPerUserPerHour - 1; i++) {
      const r = await register(t, { ...phone, name: `Phone ${i}` }, KEY_B);
      await t.mutation(api.devices.remove, { token: r.token, deviceId: r.deviceId });
    }
    await expect(register(t, phone, KEY_B)).rejects.toMatchObject({ data: { code: "rateLimited" } });
    const again = await t.mutation(api.account.register, { createdAt: Date.now(), token: first.token, device: mac, publicKey: first.publicKey, keyId: KEY_A });
    expect(again).toMatchObject({ deviceId: first.deviceId, libraryId: first.libraryId, keyId: KEY_A, keyState: "holder" });
    expect(await t.run((ctx) => ctx.db.query("devices").collect())).toHaveLength(1);
    const keys = await t.run((ctx) => ctx.db.query("deviceKeys").collect());
    expect(keys).toEqual([expect.objectContaining({ deviceId: first.deviceId, publicKey: first.publicKey, exposedKeyId: KEY_A })]);
  });

  test("registering new devices is rate limited per user", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const tokens: string[] = [];
    for (let i = 0; i < 30; i++) {
      const r = await register(t, { ...phone, name: `Phone ${i}` }, KEY_A);
      tokens.push(r.token);
      await t.mutation(api.devices.remove, { token: r.token, deviceId: r.deviceId });
    }
    await expect(register(t, phone, KEY_A)).rejects.toMatchObject({ data: { code: "rateLimited" } });
    // Other users aren't affected, and an hour later it works again.
    await register(base.withIdentity(ANNA), phone, KEY_B);
    vi.advanceTimersByTime(3600_000);
    await register(t, phone, KEY_A);
  });

  test("accounts expire after 60 idle days with all their rows; a heartbeat keeps them", async () => {
    const { base, t, a, b } = await twoDevices();
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("x"), keyId: KEY_A, baseRevision: 0 });
    await t.mutation(api.settings.put, { token: a.token, key: "playback.autoplay", value: seal(KEY_A, "true") });
    await t.mutation(api.playback.publish, { token: a.token, anchor, content: content(KEY_A) });
    vi.advanceTimersByTime(59 * 24 * 3600_000);
    await t.mutation(api.devices.heartbeat, { token: b.token });
    vi.advanceTimersByTime(2 * 24 * 3600_000);
    expect(await t.mutation(internal.libraries.sweepExpired, {})).toEqual({ deleted: 0, kept: 0 });
    vi.advanceTimersByTime(59 * 24 * 3600_000);
    expect(await t.mutation(internal.libraries.sweepExpired, {})).toEqual({ deleted: 1, kept: 0 });
    // Its tokens stop working at once; the rows go in the background.
    await expect(t.query(api.devices.list, { token: a.token })).rejects.toMatchObject({ data: { code: "unauthorized" } });
    await settleScheduled(base);
    for (const table of ["libraries", "devices", "deviceKeys", "playback", "queues", "vault", "settings"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
    // Coming back registers again, as the first device of a new library.
    expect(await register(t, mac, KEY_C)).toMatchObject({ keyId: KEY_C, keyState: "holder" });
  });
});

describe("vault key", () => {
  test("two first devices at once: exactly one key wins and the other device asks", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const [a, b] = await Promise.all([register(t, mac, KEY_A), register(t, phone, KEY_B)]);
    const states = [a, b].map((r) => r.keyState).sort();
    expect(states).toEqual(["holder", "requested"]);
    const winner = a.keyState === "holder" ? KEY_A : KEY_B;
    expect(a.keyId).toBe(winner);
    expect(b.keyId).toBe(winner);
  });

  test("the exchange runs in order: commit, answer, reveal, then a grant from the holder that answered", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...mac, name: "Studio Mac 2" }, KEY_C);
    await approve(t, a, c, KEY_A);
    const conflict = { data: { code: "conflict" } };
    const commitment = random32();
    const holderNonce = random32();
    const nonce = random32();
    const wrapped = btoa("sealed under a key only the Mac and the phone can derive");

    // Nothing to answer before the phone committed, nothing to reveal or grant before a holder answered.
    await expect(t.mutation(api.keys.answer, { token: a.token, deviceId: b.deviceId, commitment, nonce: holderNonce })).rejects.toMatchObject(conflict);
    await t.mutation(api.keys.request, { token: b.token, commitment });
    await t.mutation(api.keys.request, { token: b.token, commitment }); // a retry
    await expect(t.mutation(api.keys.reveal, { token: b.token, commitment, nonce })).rejects.toThrow(/No device has answered/);
    await expect(t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment })).rejects.toMatchObject(conflict);

    // Holders see the commitment and the phone's public key; the first holder to answer runs the exchange.
    const seen = (await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId);
    expect(seen).toMatchObject({ keyState: "requested", publicKey: b.publicKey, exchange: { phase: "committed", commitment } });
    await t.mutation(api.keys.answer, { token: a.token, deviceId: b.deviceId, commitment, nonce: holderNonce });
    await t.mutation(api.keys.answer, { token: a.token, deviceId: b.deviceId, commitment, nonce: holderNonce }); // a retry
    await expect(t.mutation(api.keys.answer, { token: c.token, deviceId: b.deviceId, commitment, nonce: random32() })).rejects.toMatchObject(conflict);
    await expect(t.mutation(api.keys.answer, { token: a.token, deviceId: b.deviceId, commitment, nonce: random32() })).rejects.toMatchObject(conflict);
    const answered = (await t.query(api.devices.list, { token: b.token })).devices.find((d) => d.id === b.deviceId);
    expect(answered?.exchange).toMatchObject({ phase: "answered", holder: a.deviceId, holderKey: a.publicKey, holderNonce });

    // Not granted before the reveal; then only by the holder that answered, for this exchange.
    await expect(t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment })).rejects.toMatchObject(conflict);
    await t.mutation(api.keys.reveal, { token: b.token, commitment, nonce });
    await t.mutation(api.keys.reveal, { token: b.token, commitment, nonce }); // a retry
    await expect(t.mutation(api.keys.reveal, { token: b.token, commitment, nonce: random32() })).rejects.toMatchObject(conflict);
    await expect(t.mutation(api.keys.grant, { token: c.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment })).rejects.toMatchObject(conflict);
    await expect(t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment: random32() })).rejects.toMatchObject(
      conflict,
    );
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment });
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped, commitment }); // a retry

    const forPhone = await t.query(api.devices.list, { token: b.token });
    expect(forPhone.grant).toEqual({ keyId: KEY_A, wrapped, fromDeviceId: a.deviceId, commitment });
    const forMac = await t.query(api.devices.list, { token: a.token });
    expect(forMac.grant).toBeNull();
    expect(JSON.stringify(forMac)).not.toContain(wrapped);
    expect(forMac.devices.find((d) => d.id === b.deviceId)).toMatchObject({ keyState: "granted", publicKey: b.publicKey, exchange: null });

    await expect(t.mutation(api.keys.accept, { token: b.token, keyId: KEY_B })).rejects.toThrow(/no grant/);
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_A });
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_A });
    expect((await t.query(api.devices.list, { token: b.token })).grant).toBeNull();
    expect((await t.query(api.devices.list, { token: a.token })).devices.map((d) => d.keyState)).toEqual(["holder", "holder", "holder"]);
  });

  test("only holders answer, grant or deny, only the account's key, only to an asking device", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    const { commitment } = await exchange(t, a, c);
    const forbidden = { data: { code: "forbidden" } };
    const grant = (token: string, keyId: string, wrapped = btoa("x"), deviceId = c.deviceId) =>
      t.mutation(api.keys.grant, { token, deviceId, keyId, wrapped, commitment });
    await expect(grant(b.token, KEY_A)).rejects.toMatchObject(forbidden);
    await expect(t.mutation(api.keys.answer, { token: b.token, deviceId: c.deviceId, commitment, nonce: random32() })).rejects.toMatchObject(forbidden);
    await expect(t.mutation(api.keys.deny, { token: b.token, deviceId: c.deviceId })).rejects.toMatchObject(forbidden);
    await expect(grant(a.token, KEY_B)).rejects.toMatchObject(forbidden);
    await expect(grant(a.token, KEY_A, btoa("x"), a.deviceId)).rejects.toThrow(/itself/);
    await expect(grant(a.token, KEY_A, "not base64!")).rejects.toThrow(/base64/);
    await expect(grant(a.token, KEY_A, btoa("x".repeat(400)))).rejects.toThrow(/wrapped/);
    await expect(t.mutation(api.keys.request, { token: b.token, commitment: "short" })).rejects.toThrow(/commitment/);
  });

  test("knowing the key's fingerprint makes no device a holder: registering and claiming need approval", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    // Every device sees the fingerprint.
    const keyId = (await t.query(api.devices.list, { token: a.token })).keyId;
    expect(keyId).toBe(KEY_A);
    const intruder = await register(t, { ...phone, name: "Not Leo's" }, KEY_A);
    expect(intruder).toMatchObject({ keyId: KEY_A, keyState: "requested" });
    await expect(claimNow(t, { token: intruder.token, keyId: KEY_A })).rejects.toMatchObject({ data: { code: "forbidden" } });
    await expect(claimNow(t, { token: intruder.token, keyId: KEY_B })).rejects.toMatchObject({ data: { code: "forbidden" } });
    expect((await t.query(api.devices.list, { token: a.token })).devices.map((d) => d.keyState)).toEqual(["holder", "requested"]);
    // The holder retrying its own claim is fine.
    await claimNow(t, { token: a.token, keyId: KEY_A });
    // A registration retry with the holder's own token keeps its state.
    expect(await register(t, mac, KEY_A, a.token)).toMatchObject({ deviceId: a.deviceId, keyState: "holder" });
  });

  test("a don't allow meant for an earlier exchange leaves the device's new request alone", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const { commitment: first } = await exchange(t, a, b);
    // The phone asks again (a new exchange) before the Mac's listener answers the first alert.
    const second = random32();
    await t.mutation(api.keys.request, { token: b.token, commitment: second });
    await t.mutation(api.keys.deny, { token: a.token, deviceId: b.deviceId, commitment: first });
    const still = (await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId);
    expect(still).toMatchObject({ keyState: "requested" });
    // The current one is denied.
    await t.mutation(api.keys.deny, { token: a.token, deviceId: b.deviceId, commitment: second });
    const denied = (await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId);
    expect(denied).toMatchObject({ keyState: "denied" });
    await expect(t.mutation(api.keys.deny, { token: a.token, deviceId: b.deviceId, commitment: "short" })).rejects.toThrow();
  });

  test("don't allow, then ask again (rate limited per device)", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const { commitment } = await exchange(t, a, b);
    await t.mutation(api.keys.deny, { token: a.token, deviceId: b.deviceId });
    const denied = (await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId);
    expect(denied).toMatchObject({ keyState: "denied", exchange: null });
    await expect(
      t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped: btoa("x"), commitment }),
    ).rejects.toThrow(/ask again/);
    const again = random32();
    await t.mutation(api.keys.request, { token: b.token, commitment: again });
    expect((await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId)).toMatchObject({
      keyState: "requested",
      exchange: { phase: "committed", commitment: again },
    });
    // A holder asking again stays a holder.
    await t.mutation(api.keys.request, { token: a.token, commitment: random32() });
    expect((await t.query(api.devices.list, { token: a.token })).devices[0].keyState).toBe("holder");
    // Each request puts a prompt on the holders: 20 an hour per device.
    // Two so far (the exchange and asking again), 18 more fill the hour.
    for (let i = 0; i < 18; i++) await t.mutation(api.keys.request, { token: b.token, commitment: random32() });
    await expect(t.mutation(api.keys.request, { token: b.token, commitment: random32() })).rejects.toMatchObject({ data: { code: "rateLimited" } });
  });

  test("removing a holder replaces the key: until a holder rotates, no writes or grants; then every other holder gets it", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    const d = await register(t, { ...mac, name: "Lost Mac" }, KEY_C);
    const e = await register(t, { ...phone, name: "New Phone" }, KEY_C);
    await approve(t, a, b, KEY_A);
    await approve(t, a, d, KEY_A);
    // The iPad was granted the key but hasn't accepted; the new phone is mid-exchange.
    const cx = await exchange(t, a, c);
    await t.mutation(api.keys.grant, { token: a.token, deviceId: c.deviceId, keyId: KEY_A, wrapped: btoa("for the iPad"), commitment: cx.commitment });
    const ex = await exchange(t, a, e);
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("spotify r1"), keyId: KEY_A, baseRevision: 0 });
    await t.mutation(api.vault.signOutEverywhere, { token: a.token, provider: "youtubeMusic", baseRevision: 0 });

    // The lost Mac is removed while it still has the key (and maybe a Clerk session).
    await t.mutation(api.devices.remove, { token: a.token, deviceId: d.deviceId });
    const pending = await t.query(api.devices.list, { token: a.token });
    expect(pending).toMatchObject({ keyId: KEY_A, rotationNeeded: true });
    await expect(
      t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("x"), keyId: KEY_A, baseRevision: 1 }),
    ).rejects.toThrow(/being replaced/);
    await expect(
      t.mutation(api.keys.grant, { token: a.token, deviceId: e.deviceId, keyId: KEY_A, wrapped: btoa("w"), commitment: ex.commitment }),
    ).rejects.toThrow(/being replaced/);

    // Coming back with a Clerk session gets the lost Mac nothing: it asks like any new device.
    expect(await register(t, { ...mac, name: "Lost Mac" }, KEY_A)).toMatchObject({ keyState: "requested" });

    const KEY_D = "d".repeat(32);
    const rotate = (args: Partial<FunctionArgs<typeof api.keys.rotate>>) =>
      t.mutation(api.keys.rotate, { settings: [],
        token: a.token,
        fromKeyId: KEY_A,
        keyId: KEY_D,
        wraps: [{ deviceId: b.deviceId, wrapped: btoa("KEY_D for the phone, made with KEY_A") }],
        vault: [{ provider: "spotify", baseRevision: 1, sealed: btoa("spotify r2 under KEY_D") }],
        ...args,
      });
    const conflict = { data: { code: "conflict" } };
    await expect(t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_B, keyId: KEY_D, wraps: [], vault: [] })).rejects.toMatchObject(conflict);
    await expect(rotate({ token: c.token })).rejects.toMatchObject({ data: { code: "forbidden" } }); // granted isn't holder
    await expect(rotate({ wraps: [] })).rejects.toMatchObject(conflict); // every other holder must get the key
    await expect(rotate({ vault: [] })).rejects.toMatchObject(conflict); // every sealed row must be re-sealed
    await expect(rotate({ vault: [{ provider: "spotify", baseRevision: 0, sealed: btoa("stale") }] })).rejects.toMatchObject(conflict);
    await expect(rotate({ keyId: KEY_A })).rejects.toMatchObject({ data: { code: "forbidden" } });
    await rotate({});
    await rotate({}); // a retry

    const after = await t.query(api.devices.list, { token: b.token });
    expect(after).toMatchObject({ keyId: KEY_D, rotationNeeded: false, grant: null });
    expect(after.rekey).toEqual({ keyId: KEY_D, fromKeyId: KEY_A, wrapped: btoa("KEY_D for the phone, made with KEY_A"), fromDeviceId: a.deviceId });
    expect((await t.query(api.devices.list, { token: a.token })).rekey).toBeNull();
    // The unaccepted grant of the old key is dropped (the iPad asks again); the new phone's exchange goes on.
    const states = Object.fromEntries(after.devices.map((x) => [x.name, x.keyState]));
    expect(states).toMatchObject({ iPad: "requested", "New Phone": "requested", "Studio Mac": "holder", iPhone: "holder" });
    expect(after.devices.find((x) => x.id === e.deviceId)?.exchange).toMatchObject({ phase: "revealed", commitment: ex.commitment });

    const vault = await t.query(api.vault.list, { token: a.token });
    expect(vault.find((r) => r.provider === "spotify")).toMatchObject({ sealed: btoa("spotify r2 under KEY_D"), keyId: KEY_D, revision: 2 });
    expect(vault.find((r) => r.provider === "youtubeMusic")).toMatchObject({ sealed: null, cleared: false, revision: 1 });

    // The phone takes the rotated key; writes and grants work again, with the new key only.
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_D });
    expect((await t.query(api.devices.list, { token: b.token })).rekey).toBeNull();
    await expect(
      t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: btoa("old key"), keyId: KEY_A, baseRevision: 2 }),
    ).rejects.toMatchObject({ data: { code: "forbidden" } });
    await t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: btoa("spotify r3"), keyId: KEY_D, baseRevision: 2 });
    await t.mutation(api.keys.grant, { token: a.token, deviceId: e.deviceId, keyId: KEY_D, wrapped: btoa("w"), commitment: ex.commitment });
    // An old key is never adopted again.
    await expect(claimNow(t, { token: a.token, keyId: KEY_A })).rejects.toMatchObject({ data: { code: "forbidden" } });
  });

  test("a holder still holding an older rotation can't open the next one: it asks again", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_A, keyId: KEY_B, wraps: [{ deviceId: b.deviceId, wrapped: btoa("w1") }], vault: [] });
    // The phone was offline and never took KEY_B; the Mac rotates again (wrapping to every holder it sees).
    await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_B, keyId: KEY_C, wraps: [{ deviceId: b.deviceId, wrapped: btoa("w2") }], vault: [] });
    const list = await t.query(api.devices.list, { token: b.token });
    expect(list).toMatchObject({ keyId: KEY_C, rekey: null });
    expect(list.devices.find((d) => d.id === b.deviceId)?.keyState).toBe("requested");
  });

  test("when the last device that could open the vault leaves, the key resets but revisions keep counting", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const w = await register(t, phone, KEY_B);
    // Spotify reached revision 5 with a sign-out everywhere (the waiting phone applied it); YouTube Music has a sign-in.
    for (let r = 0; r < 4; r++) {
      await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa(`spotify ${r + 1}`), keyId: KEY_A, baseRevision: r });
    }
    await t.mutation(api.vault.signOutEverywhere, { token: a.token, provider: "spotify", baseRevision: 4 });
    await t.mutation(api.vault.put, { token: a.token, provider: "youtubeMusic", sealed: btoa("ytm 1"), keyId: KEY_A, baseRevision: 0 });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });

    const list = await t.query(api.devices.list, { token: w.token });
    expect(list).toMatchObject({ keyId: null, rotationNeeded: false });
    expect(list.devices.map((d) => d.keyState)).toEqual(["requested"]);
    const vault = await t.query(api.vault.list, { token: w.token });
    // The sign-out stays a sign-out; the unreadable sign-in is cleared one revision on, not deleted.
    expect(vault.find((r) => r.provider === "spotify")).toMatchObject({ sealed: null, cleared: false, revision: 5 });
    expect(vault.find((r) => r.provider === "youtubeMusic")).toMatchObject({ sealed: null, cleared: true, revision: 2 });
    expect(JSON.stringify(vault)).not.toContain(btoa("ytm 1"));

    // The phone claims a fresh key (never the old one) and signs in: its writes continue the count.
    await expect(claimNow(t, { token: w.token, keyId: KEY_A })).rejects.toThrow(/used before/);
    await claimNow(t, { token: w.token, keyId: KEY_C });
    await claimNow(t, { token: w.token, keyId: KEY_C });
    expect((await t.query(api.devices.list, { token: w.token })).devices[0].keyState).toBe("holder");
    await expect(
      t.mutation(api.vault.put, { token: w.token, provider: "spotify", sealed: btoa("fresh"), keyId: KEY_C, baseRevision: 0 }),
    ).rejects.toMatchObject({ data: { code: "conflict", revision: 5 } });
    expect(await t.mutation(api.vault.put, { token: w.token, provider: "spotify", sealed: btoa("fresh"), keyId: KEY_C, baseRevision: 5 })).toMatchObject({
      revision: 6,
    });
    expect(await t.mutation(api.vault.put, { token: w.token, provider: "youtubeMusic", sealed: btoa("fresh ytm"), keyId: KEY_C, baseRevision: 2 })).toMatchObject({
      revision: 3,
    });
    const written = await t.query(api.vault.list, { token: w.token });
    expect(written.find((r) => r.provider === "youtubeMusic")).toMatchObject({ cleared: false, keyId: KEY_C });
  });

  test("a device holding a grant it hasn't accepted still counts: no reset, and it replaces the key once it has it", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const { commitment } = await exchange(t, a, b);
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped: btoa("w"), commitment });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    expect(await t.query(api.devices.list, { token: b.token })).toMatchObject({ keyId: KEY_A, rotationNeeded: true });
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_A });
    await t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [], vault: [] });
    expect(await t.query(api.devices.list, { token: b.token })).toMatchObject({ keyId: KEY_C, rotationNeeded: false });
  });

  test("a device that was granted the key and asked again still forces a rotation when it leaves", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const { commitment } = await exchange(t, a, b);
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped: btoa("w"), commitment });
    // A malicious phone unwraps the grant, then asks again so it looks like a device without the key.
    await t.mutation(api.keys.request, { token: b.token, commitment: random32() });
    expect((await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === b.deviceId)?.keyState).toBe("requested");
    await t.mutation(api.devices.remove, { token: a.token, deviceId: b.deviceId });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_A, rotationNeeded: true });
  });

  test("a holder demoted by two rotations was only given old keys: removing it needs no rotation", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_A, keyId: KEY_B, wraps: [{ deviceId: b.deviceId, wrapped: btoa("w1") }], vault: [] });
    await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_B, keyId: KEY_C, wraps: [{ deviceId: b.deviceId, wrapped: btoa("w2") }], vault: [] });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: b.deviceId });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_C, rotationNeeded: false });
  });

  test("a granted device asking again after its holder left resets the key instead of stranding the account", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    const { commitment } = await exchange(t, a, b);
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped: btoa("w"), commitment });
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("spotify"), keyId: KEY_A, baseRevision: 0 });
    // The Mac signs out; the phone still has a grant, so the key stays and must be rotated.
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    expect(await t.query(api.devices.list, { token: b.token })).toMatchObject({ keyId: KEY_A, rotationNeeded: true });
    // The listener tapped Codes Don't Match and Ask Again: nobody left can open the vault.
    await t.mutation(api.keys.request, { token: b.token, commitment: random32() });
    const list = await t.query(api.devices.list, { token: b.token });
    expect(list).toMatchObject({ keyId: null, rotationNeeded: false });
    expect(list.devices.map((d) => d.keyState)).toEqual(["requested", "requested"]);
    expect((await t.query(api.vault.list, { token: b.token }))[0]).toMatchObject({ sealed: null, cleared: true, revision: 2 });
    // A fresh key can be claimed, never the old one.
    await expect(claimNow(t, { token: c.token, keyId: KEY_A })).rejects.toThrow(/used before/);
    await claimNow(t, { token: c.token, keyId: KEY_C });
    expect((await t.query(api.devices.list, { token: c.token })).devices.find((d) => d.id === c.deviceId)?.keyState).toBe("holder");
  });

  test("an account stranded by an older server recovers on the next heartbeat of a device without the key", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    // What the old `keys:request` left behind: a key, a rotation pending, and no device able to open the vault.
    await t.run(async (ctx) => {
      await ctx.db.patch(a.libraryId, { keyRotation: { neededSince: Date.now() } });
      for (const key of await ctx.db.query("deviceKeys").collect()) {
        await ctx.db.patch(key._id, { state: { kind: "requested", requestedAt: Date.now() } });
      }
    });
    await t.mutation(api.devices.heartbeat, { token: b.token });
    expect(await t.query(api.devices.list, { token: b.token })).toMatchObject({ keyId: null, rotationNeeded: false });
    await claimNow(t, { token: b.token, keyId: KEY_C });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_C });
  });

  test("a holder's heartbeat never resets the key", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.devices.heartbeat, { token: a.token });
    await t.mutation(api.devices.heartbeat, { token: b.token });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_A });
  });

  test("a holder that can't reach the account's key steps down, keeps nothing it answered, and asks again like any device", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    await approve(t, a, b, KEY_A);
    // The Mac was answering the iPad when the phone rotated, and the Mac's rotated key never reached it.
    const cx = await exchange(t, a, c);
    await t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [{ deviceId: a.deviceId, wrapped: btoa("lost") }], vault: [] });
    const conflict = { data: { code: "conflict" } };
    // Only a key that isn't the account's can be given up.
    await expect(releaseNow(t, { token: b.token, keyId: KEY_C, accountKeyId: KEY_C, rekeyKeyId: null })).rejects.toMatchObject(conflict);
    const examined = { accountKeyId: KEY_C, rekeyKeyId: KEY_C };
    await releaseNow(t, { token: a.token, keyId: KEY_A, ...examined });
    await releaseNow(t, { token: a.token, keyId: KEY_A, ...examined }); // a retry, and a non-holder: no-op
    await releaseNow(t, { token: c.token, keyId: KEY_A, ...examined });
    const list = await t.query(api.devices.list, { token: a.token });
    expect(list).toMatchObject({ keyId: KEY_C, rotationNeeded: false, rekey: null });
    const rows = Object.fromEntries(list.devices.map((d) => [d.name, d]));
    expect(rows["Studio Mac"]).toMatchObject({ keyState: "requested", exchange: null });
    expect(rows["iPhone"]).toMatchObject({ keyState: "holder" });
    // The iPad's exchange with the Mac starts over: the Mac can't grant any more.
    expect(rows["iPad"]).toMatchObject({ keyState: "requested", exchange: null });
    await expect(
      t.mutation(api.keys.grant, { token: a.token, deviceId: c.deviceId, keyId: KEY_C, wrapped: btoa("w"), commitment: cx.commitment }),
    ).rejects.toMatchObject({ data: { code: "forbidden" } });
    // Ask Again: the Mac gets the current key from the phone through the exchange.
    await approve(t, b, a, KEY_C);
    expect((await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === a.deviceId)?.keyState).toBe("holder");
  });

  test("the last holder stepping down resets the key, and a fresh one can be claimed", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("spotify r1"), keyId: KEY_A, baseRevision: 0 });
    // The phone rotates (its re-seal at revision 2) and leaves; the Mac never got the rotated key.
    await t.mutation(api.keys.rotate, { settings: [],
      token: b.token,
      fromKeyId: KEY_A,
      keyId: KEY_C,
      wraps: [{ deviceId: a.deviceId, wrapped: btoa("lost") }],
      vault: [{ provider: "spotify", baseRevision: 1, sealed: btoa("spotify r2 under KEY_C") }],
    });
    await t.mutation(api.devices.remove, { token: b.token, deviceId: b.deviceId });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_C, rotationNeeded: true });

    await releaseNow(t, { token: a.token, keyId: KEY_A, accountKeyId: KEY_C, rekeyKeyId: KEY_C });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: null, rotationNeeded: false });
    const vault = await t.query(api.vault.list, { token: a.token });
    expect(vault.find((r) => r.provider === "spotify")).toMatchObject({ sealed: null, cleared: true, revision: 3 });
    const KEY_D = "d".repeat(32);
    await claimNow(t, { token: a.token, keyId: KEY_D });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_D });
  });

  test("a release based on a stale device list is refused and keeps the rotated key waiting for the device", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("spotify r1"), keyId: KEY_A, baseRevision: 0 });
    // The Mac rotates KEY_A → KEY_B; the phone takes KEY_B, rotates KEY_B → KEY_C (wrapped for the Mac under KEY_B)
    // and leaves. The Mac holds KEY_B, and a KEY_B → KEY_C envelope waits for it.
    await t.mutation(api.keys.rotate, { settings: [],
      token: a.token,
      fromKeyId: KEY_A,
      keyId: KEY_B,
      wraps: [{ deviceId: b.deviceId, wrapped: btoa("KEY_B for the phone") }],
      vault: [{ provider: "spotify", baseRevision: 1, sealed: btoa("spotify r2 under KEY_B") }],
    });
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_B });
    await t.mutation(api.keys.rotate, { settings: [],
      token: b.token,
      fromKeyId: KEY_B,
      keyId: KEY_C,
      wraps: [{ deviceId: a.deviceId, wrapped: btoa("KEY_C for the Mac") }],
      vault: [{ provider: "spotify", baseRevision: 2, sealed: btoa("spotify r3 under KEY_C") }],
    });
    await t.mutation(api.devices.remove, { token: b.token, deviceId: b.deviceId });
    const before = await t.query(api.devices.list, { token: a.token });
    expect(before).toMatchObject({ keyId: KEY_C, rotationNeeded: true, rekey: { keyId: KEY_C, fromKeyId: KEY_B } });

    // The Mac's delayed list from before its rotation says KEY_A, so KEY_B looks stranded. A release built on it,
    // or one that didn't see the waiting envelope, is refused and changes nothing.
    const conflict = { data: { code: "conflict" } };
    await expect(
      releaseNow(t, { token: a.token, keyId: KEY_B, accountKeyId: KEY_A, rekeyKeyId: null }),
    ).rejects.toMatchObject(conflict);
    await expect(
      releaseNow(t, { token: a.token, keyId: KEY_B, accountKeyId: KEY_C, rekeyKeyId: null }),
    ).rejects.toMatchObject(conflict);
    expect(await t.query(api.devices.list, { token: a.token })).toEqual(before);
    expect((await t.query(api.vault.list, { token: a.token }))[0]).toMatchObject({ sealed: btoa("spotify r3 under KEY_C"), revision: 3 });

    // The Mac opens the envelope with KEY_B and takes KEY_C instead.
    await t.mutation(api.keys.accept, { token: a.token, keyId: KEY_C });
    expect(await t.query(api.devices.list, { token: a.token })).toMatchObject({ keyId: KEY_C, rekey: null });
    const own = (await t.query(api.devices.list, { token: a.token })).devices.find((d) => d.id === a.deviceId);
    expect(own?.keyState).toBe("holder");
  });

  test("a release that saw the account's current state goes through, envelope included", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    // A rotation made from a key the Mac never had: the Mac can't open the envelope it examined.
    await t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [{ deviceId: a.deviceId, wrapped: btoa("w") }], vault: [] });
    await t.run(async (ctx) => {
      const row = (await ctx.db.query("deviceKeys").collect()).find((k) => k.deviceId === a.deviceId);
      if (row?.state.kind !== "holder" || row.state.rekey === undefined) throw new Error("expected a rekey");
      await ctx.db.patch(row._id, { state: { ...row.state, rekey: { ...row.state.rekey, fromKeyId: KEY_B } } });
    });
    await releaseNow(t, { token: a.token, keyId: KEY_A, accountKeyId: KEY_C, rekeyKeyId: KEY_C });
    const list = await t.query(api.devices.list, { token: a.token });
    expect(list).toMatchObject({ keyId: KEY_C, rekey: null });
    expect(list.devices.find((d) => d.id === a.deviceId)?.keyState).toBe("requested");
  });

  test("the key revision grows with every change to the key state and never goes back", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const revisions = [(await t.query(api.devices.list, { token: a.token })).keyRevision];
    const look = async (token: string) => {
      const list = await t.query(api.devices.list, { token });
      revisions.push(list.keyRevision);
      return list;
    };
    const b = await register(t, phone, KEY_B);
    expect(b.keyRevision).toBeGreaterThan(revisions[0] ?? 0);
    await look(a.token);
    const { commitment } = await exchange(t, a, b);
    await look(a.token);
    await t.mutation(api.keys.grant, { token: a.token, deviceId: b.deviceId, keyId: KEY_A, wrapped: btoa("w"), commitment });
    await look(a.token);
    await t.mutation(api.keys.accept, { token: b.token, keyId: KEY_A });
    await look(a.token);
    const c = await register(t, { ...phone, name: "iPad" });
    await look(a.token);
    await t.mutation(api.devices.remove, { token: c.token, deviceId: c.deviceId });
    await look(a.token);
    await t.mutation(api.devices.remove, { token: b.token, deviceId: b.deviceId });
    const afterRemoval = await look(a.token);
    expect(afterRemoval.rotationNeeded).toBe(true);
    await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [], vault: [] });
    await look(a.token);
    for (let i = 1; i < revisions.length; i++) expect(revisions[i]).toBeGreaterThan(revisions[i - 1] ?? 0);
    // A query that changes nothing reports the same revision; so does a heartbeat or a rename.
    await t.mutation(api.devices.heartbeat, { token: a.token });
    await t.mutation(api.devices.rename, { token: a.token, deviceId: a.deviceId, name: "Mac" });
    expect((await t.query(api.devices.list, { token: a.token })).keyRevision).toBe(revisions.at(-1));
  });

  test("a release is refused when the key state changed since the revision the device examined", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    await t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [{ deviceId: a.deviceId, wrapped: btoa("w") }], vault: [] });
    await t.run(async (ctx) => {
      const row = (await ctx.db.query("deviceKeys").collect()).find((k) => k.deviceId === a.deviceId);
      if (row?.state.kind !== "holder" || row.state.rekey === undefined) throw new Error("expected a rekey");
      await ctx.db.patch(row._id, { state: { ...row.state, rekey: { ...row.state.rekey, fromKeyId: KEY_B } } });
    });
    const seen = await t.query(api.devices.list, { token: a.token });
    // Something changes after the Mac looked (a device joins): the same keys, but a newer revision.
    await register(t, { ...phone, name: "iPad" });
    await expect(
      t.mutation(api.keys.release, { token: a.token, keyId: KEY_A, accountKeyId: KEY_C, rekeyKeyId: KEY_C, keyRevision: seen.keyRevision }),
    ).rejects.toMatchObject({ data: { code: "conflict" } });
    const now = await t.query(api.devices.list, { token: a.token });
    expect(now.devices.find((d) => d.id === a.deviceId)?.keyState).toBe("holder");
    await t.mutation(api.keys.release, { token: a.token, keyId: KEY_A, accountKeyId: KEY_C, rekeyKeyId: KEY_C, keyRevision: now.keyRevision });
    const after = await t.query(api.devices.list, { token: a.token });
    expect(after.devices.find((d) => d.id === a.deviceId)?.keyState).toBe("requested");
    expect(after.keyRevision).toBeGreaterThan(now.keyRevision);
  });

  test("unregister removes the device a token names, for its own user only, and is a no-op otherwise", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const anna = base.withIdentity(ANNA);
    const keeper = await register(t, phone, KEY_B);
    // A first device whose registration answer was lost: it knows only its token. It holds the account's key.
    const lost = await register(anna, mac, KEY_A);
    const annaPhone = await register(anna, phone);
    expect(lost.keyState).toBe("holder");
    // Another user can't remove it with the token, and learns nothing.
    expect(await t.mutation(api.account.unregister, { token: lost.token })).toMatchObject({ removed: false });
    expect((await anna.query(api.devices.list, { token: annaPhone.token })).devices).toHaveLength(2);
    // Its own user removes it, with the effects of devices:remove: nobody left can open the vault, so it resets.
    expect(await anna.mutation(api.account.unregister, { token: lost.token })).toMatchObject({ removed: true });
    const list = await anna.query(api.devices.list, { token: annaPhone.token });
    expect(list.devices.map((d) => d.id)).toEqual([annaPhone.deviceId]);
    expect(list.keyId).toBeNull();
    // Again, or a token that never registered: nothing to do.
    expect(await anna.mutation(api.account.unregister, { token: lost.token })).toMatchObject({ removed: false });
    expect(await anna.mutation(api.account.unregister, { token: newToken() })).toMatchObject({ removed: false });
    expect((await t.query(api.devices.list, { token: keeper.token })).devices).toHaveLength(1);
    await expect(base.mutation(api.account.unregister, { token: lost.token })).rejects.toMatchObject({ data: { code: "unauthenticated" } });
  });

  test("a registration withdrawn before it ran never lands, and a replay of one that landed never comes back", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const anna = base.withIdentity(ANNA);
    const keeper = await register(t, phone, KEY_B);
    // The device sent its registration, heard nothing, and signed out: the withdrawal reaches the server first.
    const token = newToken();
    expect(await t.mutation(api.account.unregister, { token })).toMatchObject({ removed: false, cancelled: true });
    // The registration arrives afterwards: refused, so it never makes a device whose token and key are gone.
    await expect(register(t, mac, KEY_A, token)).rejects.toMatchObject({ data: { code: "unauthorized" } });
    expect((await t.query(api.devices.list, { token: keeper.token })).devices.map((d) => d.id)).toEqual([keeper.deviceId]);
    // A registration that landed and was withdrawn: a late copy of it doesn't create the device again.
    const landed = await register(t, mac, undefined);
    expect(await t.mutation(api.account.unregister, { token: landed.token })).toMatchObject({ removed: true, cancelled: true });
    await expect(register(t, mac, undefined, landed.token)).rejects.toMatchObject({ data: { code: "unauthorized" } });
    expect((await t.query(api.devices.list, { token: keeper.token })).devices).toHaveLength(1);
    // One user's withdrawal is theirs only: another user's registration with that token isn't refused for it.
    expect(await register(anna, mac, KEY_A, token)).toMatchObject({ keyState: "holder" });
    // Withdrawals are forgotten after their time, long after any copy could still arrive.
    vi.advanceTimersByTime(LIMITS.cancelledRegistrationTtlMs + 60_000);
    await t.mutation(internal.account.sweepCancellations, {});
    expect(await t.run((ctx) => ctx.db.query("cancelledRegistrations").collect())).toHaveLength(0);
  });

  test("a claim lands only on the state it was decided on", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    await approve(t, a, b, KEY_A);
    // The Mac leaves, the phone rotates and leaves too: nobody left can open the vault, and the iPad sees no key.
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    const c = await register(t, { ...mac, name: "iPad" });
    await t.mutation(api.keys.rotate, { settings: [], token: b.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [], vault: [] });
    await t.mutation(api.devices.remove, { token: b.token, deviceId: b.deviceId });
    const seen = await t.query(api.devices.list, { token: c.token });
    expect(seen.keyId).toBeNull();
    // The iPad decides to claim KEY_D from what it saw, but the claim is on its way. Meanwhile another device
    // claims, and leaves again: the account is keyless once more, at a newer revision.
    const d = await register(t, { ...phone, name: "Phone 2" });
    const KEY_D = "d".repeat(32);
    const KEY_E = "e".repeat(32);
    const sawD = await t.query(api.devices.list, { token: d.token });
    await t.mutation(api.keys.claim, { token: d.token, keyId: KEY_E, keyRevision: sawD.keyRevision });
    await t.mutation(api.devices.remove, { token: d.token, deviceId: d.deviceId });
    expect((await t.query(api.devices.list, { token: c.token })).keyId).toBeNull();
    // The iPad's late claim is refused and changes nothing: it can't become a holder of a key it may have dropped.
    const before = await t.query(api.devices.list, { token: c.token });
    await expect(t.mutation(api.keys.claim, { token: c.token, keyId: KEY_D, keyRevision: seen.keyRevision })).rejects.toMatchObject({
      data: { code: "conflict" },
    });
    const after = await t.query(api.devices.list, { token: c.token });
    expect(after).toMatchObject({ keyId: null, keyRevision: before.keyRevision });
    expect(after.devices.find((x) => x.id === c.deviceId)?.keyState).toBe("requested");
    // A claim made from the current state lands, and reports the revision after it, which the list agrees with.
    const landed = await t.mutation(api.keys.claim, { token: c.token, keyId: KEY_D, keyRevision: after.keyRevision });
    expect(landed.keyRevision).toBeGreaterThan(after.keyRevision);
    expect(await t.query(api.devices.list, { token: c.token })).toMatchObject({ keyId: KEY_D, keyRevision: landed.keyRevision });
    // Its retry (the answer was lost) is a no-op even with the old revision, and moves nothing.
    expect(await t.mutation(api.keys.claim, { token: c.token, keyId: KEY_D, keyRevision: after.keyRevision })).toMatchObject({
      keyId: KEY_D,
      keyRevision: landed.keyRevision,
    });
  });

  test("a rotation reports the revision after it; its retry changes nothing", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const before = await t.query(api.devices.list, { token: a.token });
    const rotated = await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [], vault: [] });
    expect(rotated.keyRevision).toBeGreaterThan(before.keyRevision);
    expect((await t.query(api.devices.list, { token: a.token })).keyRevision).toBe(rotated.keyRevision);
    const retry = await t.mutation(api.keys.rotate, { settings: [], token: a.token, fromKeyId: KEY_A, keyId: KEY_C, wraps: [], vault: [] });
    expect(retry.keyRevision).toBe(rotated.keyRevision);
  });

  test("an exchange whose holder left starts over", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const b = await register(t, phone, KEY_B);
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    await approve(t, a, b, KEY_A);
    await exchange(t, a, c);
    await t.mutation(api.devices.remove, { token: b.token, deviceId: a.deviceId });
    const row = (await t.query(api.devices.list, { token: b.token })).devices.find((d) => d.id === c.deviceId);
    expect(row).toMatchObject({ keyState: "requested", exchange: null });
  });
});

describe("device tokens are single-use", () => {
  const unauthorized = { data: { code: "unauthorized" } };
  const rateLimited = { data: { code: "rateLimited" } };

  /** Every device row of every account, with the account it is in. */
  async function allDevices(t: Accessor) {
    return await t.run((ctx) => ctx.db.query("devices").collect());
  }

  test("a late copy of a registration never registers again after a normal sign-out (the seventh review's case)", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    // R1 is sent and delayed; the device retries with the same registration (R2), which lands. A retry of a live
    // registration still gets the same device.
    const token = newToken();
    const r2 = await register(t, mac, KEY_A, token);
    expect(r2).toMatchObject({ keyState: "holder", keyId: KEY_A });
    expect(await t.mutation(api.account.register, { createdAt: Date.now(), token, device: mac, publicKey: r2.publicKey, keyId: KEY_A })).toMatchObject({
      deviceId: r2.deviceId,
    });
    // The device saved its credentials and dropped the saved registration, then signed out normally.
    await t.mutation(api.devices.remove, { token, deviceId: r2.deviceId });
    // R1 arrives now: refused, so no holder row (or new library) appears whose token and key the device discarded.
    await expect(t.mutation(api.account.register, { createdAt: Date.now(), token, device: mac, publicKey: r2.publicKey, keyId: KEY_A })).rejects.toMatchObject(unauthorized);
    expect(await allDevices(t)).toEqual([]);
    expect((await t.run((ctx) => ctx.db.query("libraries").collect())).filter((l) => l.owner !== undefined)).toEqual([]);
    // Still refused after the retired library is swept.
    await settleScheduled(base);
    await expect(register(t, mac, KEY_A, token)).rejects.toMatchObject(unauthorized);
    expect(await allDevices(t)).toEqual([]);
    // The record is the user's only: another user's registration with that token isn't refused for it.
    expect(await register(base.withIdentity(ANNA), mac, KEY_B, token)).toMatchObject({ keyState: "holder" });
  });

  test("a device removed from another device can't come back with a late copy of its registration", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.devices.remove, { token: a.token, deviceId: b.deviceId });
    await expect(t.mutation(api.account.register, { createdAt: Date.now(), token: b.token, device: phone, publicKey: b.publicKey, keyId: KEY_B })).rejects.toMatchObject(
      unauthorized,
    );
    expect((await t.query(api.devices.list, { token: a.token })).devices.map((d) => d.id)).toEqual([a.deviceId]);
  });

  test("an evicted device can't come back with a late copy of its registration", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const first = await register(t, mac, KEY_A);
    const devices: Registered[] = [first];
    for (let i = 1; i < LIMITS.maxDevicesPerLibrary; i++) {
      vi.advanceTimersByTime(120_000);
      devices.push(await register(t, { ...phone, name: `Phone ${i}` }, KEY_A));
    }
    await t.mutation(api.devices.heartbeat, { token: first.token });
    vi.advanceTimersByTime(3600_000);
    const newest = await register(t, { ...phone, name: "Newest" }, KEY_A);
    const evicted = devices[1];
    await expect(t.query(api.devices.list, { token: evicted.token })).rejects.toMatchObject(unauthorized);
    await expect(register(t, { ...phone, name: "Phone 1" }, KEY_A, evicted.token)).rejects.toMatchObject(unauthorized);
    const list = await t.query(api.devices.list, { token: newest.token });
    expect(list.devices).toHaveLength(LIMITS.maxDevicesPerLibrary);
    expect(list.devices.map((d) => d.name)).not.toContain("Phone 1");
  });

  test("the devices of an expired account can't come back with late copies of their registrations", async () => {
    const { base, t, a, b } = await twoDevices();
    vi.advanceTimersByTime(LIMITS.libraryIdleTtlMs + 60_000);
    expect(await t.mutation(internal.libraries.sweepExpired, {})).toEqual({ deleted: 1, kept: 0 });
    await expect(register(t, mac, KEY_A, a.token)).rejects.toMatchObject(unauthorized);
    // The legacy sweep deletes the devices later, without an owner; their tokens stay refused.
    await settleScheduled(base);
    expect(await allDevices(t)).toEqual([]);
    await expect(register(t, phone, KEY_B, b.token)).rejects.toMatchObject(unauthorized);
    expect(await allDevices(t)).toEqual([]);
    // A new token is a new device, the first of a new library.
    expect(await register(t, mac, KEY_C)).toMatchObject({ keyId: KEY_C, keyState: "holder" });
  });

  test("withdrawals of unknown tokens are rate limited and capped per user; retries and real removals never are", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const keeper = await register(t, phone, KEY_B);
    const withdrawn: string[] = [];
    for (let i = 0; i < LIMITS.withdrawalsPerUserPerHour; i++) {
      const token = newToken();
      expect(await t.mutation(api.account.unregister, { token })).toMatchObject({ removed: false, cancelled: true });
      withdrawn.push(token);
    }
    await expect(t.mutation(api.account.unregister, { token: newToken() })).rejects.toMatchObject(rateLimited);
    // A retry of one already recorded is free and still settles it.
    expect(await t.mutation(api.account.unregister, { token: withdrawn[0] ?? "" })).toMatchObject({ removed: false, cancelled: true });
    // Another user isn't affected.
    expect(await base.withIdentity(ANNA).mutation(api.account.unregister, { token: newToken() })).toMatchObject({ cancelled: true });
    // A real device of this user is removed by its token, and its token retired, whatever the limit says.
    const lost = await register(t, mac);
    expect(await t.mutation(api.account.unregister, { token: lost.token })).toMatchObject({ removed: true, cancelled: true });
    await expect(register(t, mac, undefined, lost.token)).rejects.toMatchObject(unauthorized);
    const removed = await register(t, mac);
    await t.mutation(api.devices.remove, { token: keeper.token, deviceId: removed.deviceId });
    await expect(register(t, mac, undefined, removed.token)).rejects.toMatchObject(unauthorized);

    // Hour after hour, up to the cap of records kept at once.
    while (withdrawn.length < LIMITS.maxWithdrawalsPerUser) {
      vi.advanceTimersByTime(3600_000);
      const token = newToken();
      await t.mutation(api.account.unregister, { token });
      withdrawn.push(token);
    }
    vi.advanceTimersByTime(3600_000);
    await expect(t.mutation(api.account.unregister, { token: newToken() })).rejects.toMatchObject(rateLimited);
    expect(await t.mutation(api.account.unregister, { token: withdrawn.at(-1) ?? "" })).toMatchObject({ cancelled: true });
    const records = await t.run((ctx) => ctx.db.query("cancelledRegistrations").collect());
    const leo = records.filter((r) => r.owner === LEO.tokenIdentifier);
    expect(leo.filter((r) => r.reason === "withdrawn")).toHaveLength(LIMITS.maxWithdrawalsPerUser);
    expect(leo.filter((r) => r.reason === "retired")).toHaveLength(2);
    // Once the oldest expire, there is room again.
    vi.advanceTimersByTime(LIMITS.cancelledRegistrationTtlMs);
    expect(await t.mutation(api.account.unregister, { token: newToken() })).toMatchObject({ cancelled: true });
  });
});

describe("the eighth review", () => {
  const unauthorized = { data: { code: "unauthorized" } };
  const invalidArgument = { data: { code: "invalidArgument" } };
  const rateLimited = { data: { code: "rateLimited" } };
  const dayMs = 24 * 3600_000;

  test("a registration resent after its token's retirement was forgotten (31 days) never registers that token again", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const keeper = await register(t, mac, KEY_A);
    // The phone's registration lands, but its answer is lost; the Mac removes the phone, which retires the token.
    const token = newToken();
    const createdAt = Date.now();
    const attempt = { token, device: phone, publicKey: newPublicKey(), keyId: KEY_B, createdAt };
    const landed = await t.mutation(api.account.register, attempt);
    await t.mutation(api.devices.remove, { token: keeper.token, deviceId: landed.deviceId });
    // 31 days later the retirement has been swept. The Mac stayed in use, so the account didn't expire.
    for (let day = 0; day < 31; day++) {
      vi.advanceTimersByTime(dayMs);
      await t.mutation(api.devices.heartbeat, { token: keeper.token });
    }
    await t.mutation(internal.account.sweepCancellations, {});
    expect(await t.run((ctx) => ctx.db.query("cancelledRegistrations").collect())).toEqual([]);
    // The phone, offline all along, resends its saved attempt: refused by its age, nothing registered.
    await expect(t.mutation(api.account.register, attempt)).rejects.toMatchObject(invalidArgument);
    const list = await t.query(api.devices.list, { token: keeper.token });
    expect(list.devices.map((d) => d.id)).toEqual([keeper.deviceId]);
  });

  test("registration attempts are refused past the age limit or from a clock far ahead; a live device's retry is still answered", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const now = Date.now();
    const old = { token: newToken(), device: mac, publicKey: newPublicKey(), keyId: KEY_A, createdAt: now - LIMITS.registrationMaxAgeMs - 1 };
    await expect(t.mutation(api.account.register, old)).rejects.toMatchObject(invalidArgument);
    const ahead = { ...old, token: newToken(), createdAt: now + LIMITS.registrationMaxAheadMs + 1 };
    await expect(t.mutation(api.account.register, ahead)).rejects.toMatchObject(invalidArgument);
    expect(await t.run((ctx) => ctx.db.query("devices").collect())).toEqual([]);
    // Inside the limits it registers; a retry of that live device is answered at any age (it creates nothing).
    const fresh = { ...old, token: newToken(), createdAt: now - LIMITS.registrationMaxAgeMs + 60_000 };
    const first = await t.mutation(api.account.register, fresh);
    vi.advanceTimersByTime(LIMITS.registrationMaxAgeMs);
    expect(await t.mutation(api.account.register, fresh)).toMatchObject({ deviceId: first.deviceId });
    expect(LIMITS.registrationMaxAgeMs).toBeLessThan(LIMITS.cancelledRegistrationTtlMs);
  });

  /** Inserts refusal records for LEO as a deployment from before `reason` existed holds them. */
  async function insertUntagged(t: Accessor, count: number): Promise<string[]> {
    const tokens = Array.from({ length: count }, newToken);
    await t.run(async (ctx) => {
      const now = Date.now();
      for (const token of tokens) {
        await ctx.db.insert("cancelledRegistrations", {
          tokenHash: await sha256Hex(token),
          owner: LEO.tokenIdentifier,
          createdAt: now,
          expiresAt: now + LIMITS.cancelledRegistrationTtlMs,
        });
      }
    });
    return tokens;
  }

  test("records without a reason (from before it existed) refuse their tokens and count toward the withdrawal cap", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const untagged = await insertUntagged(t, LIMITS.maxWithdrawalsPerUser - 5);
    for (let i = 0; i < 5; i++) await t.mutation(api.account.unregister, { token: newToken() });
    // The cap is reached by old rows and new withdrawals together.
    vi.advanceTimersByTime(3600_000);
    await expect(t.mutation(api.account.unregister, { token: newToken() })).rejects.toMatchObject(rateLimited);
    // An old row refuses its token like a withdrawal, and a retry of its withdrawal is free.
    await expect(register(t, mac, KEY_A, untagged[0])).rejects.toMatchObject(unauthorized);
    expect(await t.mutation(api.account.unregister, { token: untagged[1] ?? "" })).toMatchObject({ removed: false, cancelled: true });
  });

  test("the backfill gives old records reason withdrawn in bounded runs and leaves the others alone", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const count = LIMITS.sweepBatch * 2 + 7;
    await insertUntagged(t, count);
    const keeper = await register(t, mac, KEY_A);
    const removed = await register(t, phone, KEY_B);
    await t.mutation(api.devices.remove, { token: keeper.token, deviceId: removed.deviceId });
    const first = await t.mutation(internal.account.backfillCancellationReasons, {});
    expect(first).toEqual({ patched: LIMITS.sweepBatch, done: false });
    await settleScheduled(base);
    const rows = await t.run((ctx) => ctx.db.query("cancelledRegistrations").collect());
    expect(rows.filter((r) => r.reason === undefined)).toEqual([]);
    expect(rows.filter((r) => r.reason === "withdrawn")).toHaveLength(count);
    expect(rows.filter((r) => r.reason === "retired")).toHaveLength(1);
    // Running it again changes nothing.
    expect(await t.mutation(internal.account.backfillCancellationReasons, {})).toMatchObject({ patched: 0 });
  });
});

describe("legacy pairing data", () => {
  test("old libraries, invites and counters are swept; their tokens no longer work", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    const mine = await register(t, mac, KEY_A);
    const legacyToken = newToken();
    const legacy = await t.run(async (ctx) => {
      const libraryId = await ctx.db.insert("libraries", { createdAt: 1, keyId: KEY_B, pairedAt: 2, expiresAt: Date.now() + 1000 });
      const deviceId = await ctx.db.insert("devices", {
        libraryId,
        ...phone,
        tokenHash: await sha256Hex(legacyToken),
        createdAt: 1,
        lastSeenAt: 1,
      });
      await ctx.db.insert("vault", { libraryId, provider: "spotify", sealed: btoa("old"), keyId: KEY_B, revision: 1, updatedAt: 1, updatedBy: deviceId });
      await ctx.db.insert("settings", { libraryId, key: "k", value: seal(KEY_B, "1"), updatedAt: 1, updatedBy: deviceId });
      await ctx.db.insert("invites", { libraryId, createdBy: deviceId, codeHash: "h", createdAt: 1, expiresAt: 2 });
      await ctx.db.insert("redeemFailures", { key: "redeem:global", windowStart: 1, count: 3 });
      return { libraryId, deviceId };
    });
    // Old builds' tokens fail even for the signed-in user: the library has no owner.
    await expect(t.query(api.devices.list, { token: legacyToken })).rejects.toMatchObject({ data: { code: "unauthorized" } });

    // The library, its device, vault row and setting, one invite and one counter.
    expect(await t.mutation(internal.legacy.sweep, {})).toEqual({ deleted: 6, more: false });
    expect(await t.run((ctx) => ctx.db.get(legacy.libraryId))).toBeNull();
    expect(await t.run((ctx) => ctx.db.get(legacy.deviceId))).toBeNull();
    for (const table of ["invites", "redeemFailures", "settings"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
    expect(await t.run((ctx) => ctx.db.query("vault").collect())).toEqual([]);
    // The account is untouched.
    expect((await t.query(api.devices.list, { token: mine.token })).devices).toHaveLength(1);
  });

  test("a huge old library is deleted in bounded runs that pick up where the last one stopped", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const mine = await register(t, mac, KEY_A);
    const sizes = { settingOps: 1500, commands: 700, devices: 3 };
    const libraryId = await t.run(async (ctx) => {
      const id = await ctx.db.insert("libraries", { createdAt: 1, keyId: KEY_B, pairedAt: 2 });
      const devices: Id<"devices">[] = [];
      for (let i = 0; i < sizes.devices; i++) {
        devices.push(await ctx.db.insert("devices", { libraryId: id, ...phone, tokenHash: `h${i}`, createdAt: 1, lastSeenAt: 1 }));
      }
      for (let i = 0; i < sizes.settingOps; i++) {
        await ctx.db.insert("settingOps", { libraryId: id, key: `k${i % 64}`, writeId: `w${i}`, deviceId: devices[0], updatedAt: 1, expiresAt: 9e15 });
      }
      for (let i = 0; i < sizes.commands; i++) {
        await ctx.db.insert("commands", {
          libraryId: id,
          fromDeviceId: devices[i % 3],
          toDeviceId: devices[(i + 1) % 3],
          command: { kind: "pause" },
          createdAt: 1,
          expiresAt: 9e15,
        });
      }
      return id;
    });
    const total = 1 + sizes.devices + sizes.settingOps + sizes.commands;

    const first = await t.mutation(internal.legacy.sweep, {});
    expect(first.more).toBe(true);
    expect(first.deleted).toBeLessThanOrEqual(1000);
    expect(await t.run((ctx) => ctx.db.get(libraryId))).not.toBeNull();

    let deleted = first.deleted;
    for (let run = 0; run < 10; run++) {
      const next = await t.mutation(internal.legacy.sweep, {});
      expect(next.deleted).toBeLessThanOrEqual(1000);
      deleted += next.deleted;
      if (!next.more) break;
    }
    expect(deleted).toBe(total);
    for (const table of ["libraries", "devices", "settingOps", "commands"] as const) {
      const rows = await t.run((ctx) => ctx.db.query(table).collect());
      expect(rows.filter((r) => ("libraryId" in r ? r.libraryId === libraryId : r._id === libraryId))).toEqual([]);
    }
    expect((await t.query(api.devices.list, { token: mine.token })).devices).toHaveLength(1);
    // Each full run scheduled the next one, so left alone the backlog drains by itself too.
    await settleScheduled(base);
  });

  test("invites and counters share what the libraries left of one run's budget", async () => {
    const t = convexTest(schema, modules).withIdentity(LEO);
    await t.run(async (ctx) => {
      // A library of 700 rows (finished in this run), then 600 invites and 600 counters.
      const libraryId = await ctx.db.insert("libraries", { createdAt: 1, keyId: KEY_B, pairedAt: 2 });
      const deviceId = await ctx.db.insert("devices", { libraryId, ...phone, tokenHash: "h", createdAt: 1, lastSeenAt: 1 });
      for (let i = 0; i < 698; i++) {
        await ctx.db.insert("settingOps", { libraryId, key: `k${i % 64}`, writeId: `w${i}`, deviceId, updatedAt: 1, expiresAt: 9e15 });
      }
      for (let i = 0; i < 600; i++) {
        await ctx.db.insert("invites", { libraryId, createdBy: deviceId, codeHash: `h${i}`, createdAt: 1, expiresAt: 2 });
        await ctx.db.insert("redeemFailures", { key: `redeem:${i}`, windowStart: 1, count: 1 });
      }
    });
    const runs = [];
    for (let run = 0; run < 5; run++) {
      const next = await t.mutation(internal.legacy.sweep, {});
      runs.push(next.deleted);
      if (!next.more) break;
    }
    expect(Math.max(...runs)).toBeLessThanOrEqual(1000);
    expect(runs.reduce((a, b) => a + b, 0)).toBe(700 + 1200);
    expect(await t.run((ctx) => ctx.db.query("invites").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("redeemFailures").collect())).toEqual([]);
  });
});

describe("playback", () => {
  test("publish with sealed content, anchor-only refreshes keep it, other devices read both", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.playback.publish, { token: a.token, anchor, content: content(KEY_A) });
    expect(first.positionAt).toBe(first.serverNow);
    expect(first.queueVersion).toBe(1);

    vi.advanceTimersByTime(20_000);
    const refresh = await t.mutation(api.playback.publish, {
      token: a.token,
      anchor: { ...anchor, positionMs: 32_000, positionAt: Date.now() - 50 },
    });
    expect(refresh.queueVersion).toBe(1);
    expect(refresh.positionAt).toBe(Date.now() - 50);

    const rows = await t.query(api.playback.list, { token: b.token });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ deviceId: a.deviceId, queueVersion: 1, content: seal(KEY_A, "now:track") });
    expect(rows[0].anchor.positionMs).toBe(32_000);

    expect(await t.query(api.playback.queue, { token: b.token, deviceId: a.deviceId })).toEqual({ content: seal(KEY_A, "now:queue"), version: 1 });
    expect(await t.query(api.playback.queue, { token: a.token, deviceId: b.deviceId })).toBeNull();

    const next = await t.mutation(api.playback.publish, { token: a.token, anchor, content: content(KEY_A, "next") });
    expect(next.queueVersion).toBe(2);
    expect((await t.query(api.playback.queue, { token: b.token, deviceId: a.deviceId }))?.content).toEqual(seal(KEY_A, "next:queue"));

    await t.mutation(api.playback.clear, { token: a.token });
    expect(await t.query(api.playback.list, { token: b.token })).toEqual([]);
  });

  test("a device without the key publishes its anchor alone, and null drops content it published before", async () => {
    const { t, a, b } = await twoDevices();
    const c = await register(t, { ...phone, name: "iPad" }, KEY_C);
    expect(c.keyState).toBe("requested");
    // The first publish needs no content: a device that can't seal still shows where it plays.
    await t.mutation(api.playback.publish, { token: c.token, anchor, content: null });
    await t.mutation(api.playback.publish, { token: c.token, anchor: { ...anchor, isPlaying: false } });
    const row = (await t.query(api.playback.list, { token: a.token })).find((r) => r.deviceId === c.deviceId);
    expect(row).toMatchObject({ content: null, anchor: { isPlaying: false, positionMs: 12_000 } });
    expect(await t.query(api.playback.queue, { token: a.token, deviceId: c.deviceId })).toBeNull();
    // It can't seal: it has no key, and any fingerprint but the account's is refused.
    await expect(t.mutation(api.playback.publish, { token: c.token, anchor, content: content(KEY_C) })).rejects.toMatchObject({ data: { code: "forbidden" } });

    await t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_A) });
    const dropped = await t.mutation(api.playback.publish, { token: b.token, anchor, content: null });
    expect(dropped.queueVersion).toBe(2);
    expect((await t.query(api.playback.list, { token: a.token })).find((r) => r.deviceId === b.deviceId)?.content).toBeNull();
    expect(await t.query(api.playback.queue, { token: a.token, deviceId: b.deviceId })).toBeNull();
  });

  test("positionAt is clamped to the last 10 s of server time", async () => {
    const { t, a } = await twoDevices();
    const future = await t.mutation(api.playback.publish, {
      token: a.token,
      anchor: { ...anchor, positionAt: Date.now() + 60_000 },
      content: content(KEY_A),
    });
    expect(future.positionAt).toBe(future.serverNow);
    const past = await t.mutation(api.playback.publish, { token: a.token, anchor: { ...anchor, positionAt: 0 } });
    expect(past.positionAt).toBe(past.serverNow - 10_000);
  });

  test("bad states are rejected", async () => {
    const { t, a } = await twoDevices();
    await expect(
      t.mutation(api.playback.publish, { token: a.token, anchor: { ...anchor, volume: 2 }, content: content(KEY_A) }),
    ).rejects.toThrow(/volume/);
    await expect(
      t.mutation(api.playback.publish, { token: a.token, anchor, content: { playback: seal(KEY_A, "t"), queue: seal(KEY_B, "q") } }),
    ).rejects.toThrow();
  });
});

describe("commands", () => {
  test("send, receive, ack, and see the result", async () => {
    const { t, a, b } = await twoDevices();
    const sent = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "seek", positionMs: 42_000 } });
    expect(sent.expiresAt - sent.serverNow).toBe(2 * 60_000);

    const pending = await t.query(api.commands.incoming, { token: a.token });
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({ id: sent.commandId, fromDeviceId: b.deviceId, command: { kind: "seek", positionMs: 42_000 } });
    expect(await t.query(api.commands.incoming, { token: b.token })).toEqual([]);

    // Only the target can ack.
    await expect(t.mutation(api.commands.ack, { token: b.token, commandId: sent.commandId, result: { ok: true } })).rejects.toThrow();
    await t.mutation(api.commands.ack, { token: a.token, commandId: sent.commandId, result: { ok: true } });
    await t.mutation(api.commands.ack, { token: a.token, commandId: sent.commandId, result: { ok: false, reason: "expired" } });
    expect(await t.query(api.commands.incoming, { token: a.token })).toEqual([]);

    const out = await t.query(api.commands.outgoing, { token: b.token });
    expect(out[0]).toMatchObject({ id: sent.commandId, kind: "seek", result: { ok: true } });
    expect(out[0].ackedAt).toBeDefined();
  });

  test("a failure says why as a code; its message travels only sealed", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "play" } });
    const second = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "play" } });
    await t.mutation(api.commands.ack, {
      token: a.token,
      commandId: first.commandId,
      result: { ok: false, reason: "playbackFailed", content: seal(KEY_A, "message") },
    });
    await t.mutation(api.commands.ack, { token: a.token, commandId: second.commandId, result: { ok: false } });
    const out = await t.query(api.commands.outgoing, { token: b.token });
    expect(out.find((c) => c.id === first.commandId)?.result).toEqual({ ok: false, reason: "playbackFailed", content: seal(KEY_A, "message") });
    expect(out.find((c) => c.id === second.commandId)?.result).toEqual({ ok: false, reason: "failed" });
    // No free text: a message in the clear, or a reason off the list, is refused by the validator.
    const third = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "play" } });
    const plain = { ok: false, message: "\"Get Lucky\" couldn't be loaded" };
    await expect(t.mutation(api.commands.ack, { token: a.token, commandId: third.commandId, result: plain as never })).rejects.toThrow(/message/);
    // @ts-expect-error reasons come from a fixed list
    await expect(t.mutation(api.commands.ack, { token: a.token, commandId: third.commandId, result: { ok: false, reason: "Get Lucky" } })).rejects.toThrow();
    await expect(t.mutation(api.commands.ack, { token: a.token, commandId: third.commandId, result: { ok: true, reason: "failed" } })).rejects.toThrow(/success/);
  });

  test("a send retried with the same clientId is stored once", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "toggle" }, clientId: "c-1" });
    const retry = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "toggle" }, clientId: "c-1" });
    expect(retry.commandId).toBe(first.commandId);
    await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "toggle" }, clientId: "c-2" });
    expect(await t.query(api.commands.incoming, { token: a.token })).toHaveLength(2);
  });

  test("takeOver carries its anchor in the clear and its queue sealed", async () => {
    const { t, a, b } = await twoDevices();
    const command = { kind: "takeOver" as const, anchor, content: seal(KEY_A, "handoff") };
    const sent = await t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command });
    const [incoming] = await t.query(api.commands.incoming, { token: b.token });
    expect(incoming.id).toBe(sent.commandId);
    if (incoming.command.kind !== "takeOver") throw new Error("expected takeOver");
    expect(incoming.command.anchor.positionAt).toBe(sent.serverNow);
    expect(incoming.command.content).toEqual(seal(KEY_A, "handoff"));
    await expect(
      t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command: { ...command, content: seal(KEY_B, "x") } }),
    ).rejects.toMatchObject({ data: { code: "forbidden" } });
    const plain = { kind: "takeOver", state: { queue: [], index: 0, anchor } };
    // @ts-expect-error the old plaintext takeover
    await expect(t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command: plain })).rejects.toThrow();
  });

  test("no commands to yourself; expired commands are swept", async () => {
    const { t, a, b } = await twoDevices();
    await expect(t.mutation(api.commands.send, { token: a.token, toDeviceId: a.deviceId, command: { kind: "play" } })).rejects.toThrow(/itself/);
    await t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command: { kind: "play" } });
    vi.advanceTimersByTime(60_000);
    expect(await t.mutation(internal.commands.sweep, {})).toEqual({ deleted: 0 });
    vi.advanceTimersByTime(61_000);
    expect(await t.mutation(internal.commands.sweep, {})).toEqual({ deleted: 1 });
    expect(await t.query(api.commands.incoming, { token: b.token })).toEqual([]);
  });
});

describe("vault", () => {
  const sealedV1 = btoa("nonce+ciphertext+tag v1");
  const sealedV2 = btoa("nonce+ciphertext+tag v2");

  test("stores only ciphertext, last write wins, and other devices read it", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A });
    vi.advanceTimersByTime(5);
    const second = await t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV2, keyId: KEY_A });
    expect(second.updatedAt).toBeGreaterThan(first.updatedAt);
    // Same millisecond: still ordered after the stored write.
    const third = await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A });
    expect(third.updatedAt).toBeGreaterThan(second.updatedAt);

    // Writers from before revisions (no baseRevision) keep the row at revision 0, the only one v1 blobs open at.
    const list = await t.query(api.vault.list, { token: b.token });
    expect(list).toEqual([
      { provider: "spotify", sealed: sealedV1, cleared: false, keyId: KEY_A, revision: 0, updatedAt: third.updatedAt, updatedBy: a.deviceId },
    ]);
    const rows = await t.run((ctx) => ctx.db.query("vault").collect());
    expect(rows).toHaveLength(1);
    expect(Object.keys(rows[0]).sort()).toEqual(["_creationTime", "_id", "keyId", "libraryId", "provider", "revision", "sealed", "updatedAt", "updatedBy"]);
  });

  test("writes are compare-and-swap on the revision, and a retry of a landed write is idempotent", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A, baseRevision: 0 });
    expect(first.revision).toBe(1);
    // The same write again (socket, then HTTP): the stored one comes back, nothing changes.
    const retry = await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A, baseRevision: 0 });
    expect(retry).toMatchObject({ revision: 1, updatedAt: first.updatedAt });
    // B wrote from a stale base: refused, told the stored revision.
    const stale = t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV2, keyId: KEY_A, baseRevision: 0 });
    await expect(stale).rejects.toThrow(/Another device changed this sign-in first/);
    const error = await stale.catch((e: unknown) => e);
    expect(error).toMatchObject({ data: { code: "conflict", revision: 1 } });
    const second = await t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV2, keyId: KEY_A, baseRevision: 1 });
    expect(second.revision).toBe(2);
  });

  test("an old blob can't undo sign out everywhere", async () => {
    const { t, a, b } = await twoDevices();
    const signedIn = await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A, baseRevision: 0 });
    const out = await t.mutation(api.vault.signOutEverywhere, { token: a.token, provider: "spotify", baseRevision: signedIn.revision });
    expect(out.revision).toBe(2);
    // B replays the blob it saw before, with the revision it had then, or the way old clients write (no revision).
    await expect(t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A, baseRevision: 0 })).rejects.toThrow(/changed this sign-in/);
    await expect(t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A, baseRevision: 1 })).rejects.toThrow(/changed this sign-in/);
    await expect(t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A })).rejects.toThrow(/changed this sign-in/);
    const [entry] = await t.query(api.vault.list, { token: b.token });
    expect(entry).toMatchObject({ sealed: null, revision: 2 });
    // A sign-out retried is idempotent; one from a stale base is refused.
    expect((await t.mutation(api.vault.signOutEverywhere, { token: a.token, provider: "spotify", baseRevision: 1 })).revision).toBe(2);
    await expect(t.mutation(api.vault.signOutEverywhere, { token: b.token, provider: "spotify", baseRevision: 0 })).rejects.toThrow(/changed this sign-in/);
    // Signing in again on top of the tombstone, at its revision, works.
    expect((await t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV2, keyId: KEY_A, baseRevision: 2 })).revision).toBe(3);
  });

  test("a legacy row is migrated once with compare and swap, and legacy writers can't write over it after", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A });
    expect((await t.query(api.vault.list, { token: a.token }))[0].revision).toBe(0);
    // Two current clients migrate at once: one wins revision 1, the other gets a conflict.
    expect((await t.mutation(api.vault.put, { token: b.token, provider: "spotify", sealed: sealedV2, keyId: KEY_A, baseRevision: 0 })).revision).toBe(1);
    await expect(t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: btoa("other v2"), keyId: KEY_A, baseRevision: 0 })).rejects.toThrow(
      /changed this sign-in/,
    );
    // A client from before revisions can no longer put v1 data there.
    await expect(t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A })).rejects.toThrow(/changed this sign-in/);
    expect((await t.query(api.vault.list, { token: a.token }))[0]).toMatchObject({ sealed: sealedV2, revision: 1 });
  });

  test("rejects a key the library doesn't use, and non-base64 data", async () => {
    const { t, a } = await twoDevices();
    await expect(t.mutation(api.vault.put, { token: a.token, provider: "youtubeMusic", sealed: sealedV1, keyId: KEY_B })).rejects.toThrow(/key the library/);
    await expect(t.mutation(api.vault.put, { token: a.token, provider: "youtubeMusic", sealed: "not base64!", keyId: KEY_A })).rejects.toThrow(/base64/);
    await expect(t.mutation(api.vault.put, { token: a.token, provider: "youtubeMusic", sealed: sealedV1, keyId: "short" })).rejects.toThrow(/32 hex/);
  });

  test("sign out everywhere leaves a tombstone with its author", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.vault.put, { token: a.token, provider: "youtubeMusic", sealed: sealedV1, keyId: KEY_A });
    const out = await t.mutation(api.vault.signOutEverywhere, { token: b.token, provider: "youtubeMusic" });
    const [entry] = await t.query(api.vault.list, { token: a.token });
    expect(entry).toMatchObject({ provider: "youtubeMusic", sealed: null, updatedBy: b.deviceId, updatedAt: out.updatedAt });
    // Signing in again replaces the tombstone, but only from a writer that names the tombstone's revision:
    // a write without one (clients from before revisions) can't overwrite it.
    await expect(t.mutation(api.vault.put, { token: b.token, provider: "youtubeMusic", sealed: sealedV2, keyId: KEY_A })).rejects.toThrow(/changed this sign-in/);
    await t.mutation(api.vault.put, { token: b.token, provider: "youtubeMusic", sealed: sealedV2, keyId: KEY_A, baseRevision: entry.revision });
    expect((await t.query(api.vault.list, { token: a.token }))[0].sealed).toBe(sealedV2);
  });

  test("accounts are isolated: another user's devices see none of it", async () => {
    const { base, t, a } = await twoDevices();
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A });
    const other = base.withIdentity(ANNA);
    const anna = await register(other, { ...mac, name: "Anna's Mac" }, KEY_B);
    expect(anna.libraryId).not.toBe(a.libraryId);
    expect(await other.query(api.vault.list, { token: anna.token })).toEqual([]);
    expect((await other.query(api.devices.list, { token: anna.token })).devices.map((d) => d.name)).toEqual(["Anna's Mac"]);
    await expect(other.mutation(api.vault.put, { token: anna.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A })).rejects.toThrow(/key the library/);
    await other.mutation(api.vault.put, { token: anna.token, provider: "spotify", sealed: sealedV2, keyId: KEY_B });
    expect((await t.query(api.vault.list, { token: a.token }))[0].sealed).toBe(sealedV1);
  });

  test("the last device leaving deletes the vault and settings", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    await t.mutation(api.vault.put, { token: a.token, provider: "spotify", sealed: sealedV1, keyId: KEY_A });
    await t.mutation(api.settings.put, { token: a.token, key: "playback.autoplay", value: seal(KEY_A, "true") });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    // The next device starts a new library at once; the old one's rows go in the background.
    const next = await register(t, phone, KEY_B);
    expect(next).toMatchObject({ keyId: KEY_B, keyState: "holder" });
    expect(await t.query(api.vault.list, { token: next.token })).toEqual([]);
    await t.mutation(api.devices.remove, { token: next.token, deviceId: next.deviceId });
    await settleScheduled(base);
    for (const table of ["vault", "settings", "libraries", "deviceKeys", "devices"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
  });
});

describe("settings", () => {
  test("per-key last write wins, visible library-wide", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.settings.put, { token: a.token, key: "playback.crossfadeSeconds", value: seal(KEY_A, "4") });
    await t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: seal(KEY_A, "searches") });
    vi.advanceTimersByTime(10);
    await t.mutation(api.settings.put, { token: b.token, key: "playback.crossfadeSeconds", value: seal(KEY_A, "6") });
    const list = await t.query(api.settings.list, { token: a.token });
    const byKey = Object.fromEntries(list.map((s) => [s.key, s]));
    expect(byKey["playback.crossfadeSeconds"]).toMatchObject({ value: seal(KEY_A, "6"), updatedBy: b.deviceId });
    expect(byKey["search.recent"].value).toEqual(seal(KEY_A, "searches"));
  });

  test("a retried write with the same writeId changes nothing", async () => {
    const { t, a, b } = await twoDevices();
    const first = await t.mutation(api.settings.put, { token: a.token, key: "playback.autoplay", value: seal(KEY_A, "true"), writeId: "w1" });
    vi.advanceTimersByTime(10);
    const retry = await t.mutation(api.settings.put, { token: a.token, key: "playback.autoplay", value: seal(KEY_A, "true"), writeId: "w1" });
    expect(retry.updatedAt).toBe(first.updatedAt);
    await t.mutation(api.settings.put, { token: b.token, key: "playback.autoplay", value: seal(KEY_A, "false"), writeId: "w2" });
    const [row] = await t.query(api.settings.list, { token: a.token });
    expect(row).toMatchObject({ value: seal(KEY_A, "false"), writeId: "w2", updatedBy: b.deviceId });
  });

  test("a late retry of an old write can't overwrite a newer write from another device", async () => {
    const { base, t, a, b } = await twoDevices();
    const args = { token: a.token, key: "k", value: seal(KEY_A, "1"), writeId: "a-first" };
    const first = await t.mutation(api.settings.put, args);
    vi.advanceTimersByTime(10);
    await t.mutation(api.settings.put, { token: b.token, key: "k", value: seal(KEY_A, "2"), writeId: "b-newer" });
    vi.advanceTimersByTime(10);
    const retry = await t.mutation(api.settings.put, args);
    expect(retry.updatedAt).toBe(first.updatedAt);
    expect(await t.query(api.settings.list, { token: a.token })).toMatchObject([{ value: seal(KEY_A, "2"), updatedBy: b.deviceId }]);

    // Operations are forgotten after 10 minutes, and the last device leaving takes them along.
    vi.advanceTimersByTime(10 * 60_000);
    await t.mutation(api.settings.put, { token: a.token, key: "k", value: seal(KEY_A, "3"), writeId: "a-later" });
    expect(await t.mutation(internal.settings.sweepOps, {})).toEqual({ deleted: 2, more: false });
    expect(await t.run((ctx) => ctx.db.query("settingOps").collect())).toHaveLength(1);
    await t.mutation(api.devices.remove, { token: a.token, deviceId: b.deviceId });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    await settleScheduled(base);
    expect(await t.run((ctx) => ctx.db.query("settingOps").collect())).toEqual([]);
  });

  test("a first-sync fill-in never overwrites a value another device stored", async () => {
    const { t, a, b } = await twoDevices();
    await t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: seal(KEY_A, "a's"), ifAbsent: true });
    const fill = await t.mutation(api.settings.put, { token: b.token, key: "search.recent", value: seal(KEY_A, "b's"), ifAbsent: true });
    const [row] = await t.query(api.settings.list, { token: b.token });
    expect(row).toMatchObject({ value: seal(KEY_A, "a's"), updatedBy: a.deviceId, updatedAt: fill.updatedAt });
  });

  test("keys and sizes are checked", async () => {
    const { t, a } = await twoDevices();
    await expect(t.mutation(api.settings.put, { token: a.token, key: "bad key!", value: seal(KEY_A, "1") })).rejects.toThrow(/keys/);
    const huge = { v: 1 as const, keyId: KEY_A, sealed: "A".repeat(46 * 1024) };
    await expect(t.mutation(api.settings.put, { token: a.token, key: "k", value: huge })).rejects.toThrow(/base64/);
  });
});

describe("sealed content", () => {
  test("plaintext content is refused everywhere: playback, queues, takeovers, results and settings", async () => {
    const { t, a, b } = await twoDevices();
    const track = { providerID: "t1", provider: "youtubeMusic", title: "Get Lucky", artists: [{ name: "Daft Punk" }], isExplicit: false, isPlayable: true, extra: {} };
    const entries = [{ uid: "00000000-0000-0000-0000-000000000001", track, isAutoplay: false, isUserQueued: false }];
    const refused = [
      // The old wire format: the queue window and its track in the clear.
      () => t.mutation(api.playback.publish, { token: a.token, anchor, queue: { entries, index: 0 } } as never),
      () => t.mutation(api.playback.publish, { token: a.token, anchor, content: { playback: track, queue: { entries, index: 0 } } } as never),
      // A sealed field that's really plaintext: not base64, or JSON where the ciphertext goes.
      () => t.mutation(api.playback.publish, { token: a.token, anchor, content: { playback: { v: 1, keyId: KEY_A, sealed: JSON.stringify(track) }, queue: seal(KEY_A, "q") } }),
      () => t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command: { kind: "takeOver", state: { queue: entries, index: 0, anchor } } } as never),
      () => t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: JSON.stringify(["daft punk"]) } as never),
      () => t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: { v: 1, keyId: KEY_A, sealed: "[\"daft punk\"]" } }),
      () => t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: { v: 2, keyId: KEY_A, sealed: seal(KEY_A, "x").sealed } } as never),
    ];
    for (const call of refused) await expect(call()).rejects.toThrow();
    for (const table of ["playback", "queues", "commands", "settings"] as const) {
      expect(await t.run((ctx) => ctx.db.query(table).collect())).toEqual([]);
    }
  });

  test("a keyId other than the account's is refused, and malformed ones too", async () => {
    const { t, a, b } = await twoDevices();
    const forbidden = { data: { code: "forbidden" } };
    await expect(t.mutation(api.playback.publish, { token: a.token, anchor, content: content(KEY_B) })).rejects.toMatchObject(forbidden);
    await expect(t.mutation(api.settings.put, { token: a.token, key: "k", value: seal(KEY_C, "1") })).rejects.toMatchObject(forbidden);
    const sent = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "play" } });
    await expect(
      t.mutation(api.commands.ack, { token: a.token, commandId: sent.commandId, result: { ok: false, reason: "failed", content: seal(KEY_B, "m") } }),
    ).rejects.toMatchObject(forbidden);
    await expect(t.mutation(api.settings.put, { token: a.token, key: "k", value: seal("A".repeat(32), "1") })).rejects.toThrow(/32 hex/);
  });

  test("an account without a key takes no content at all", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    const b = await register(t, phone); // a new library, no key proposed
    expect(b.keyId).toBeNull();
    await expect(t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_A) })).rejects.toMatchObject({ data: { code: "forbidden" } });
    await t.mutation(api.playback.publish, { token: b.token, anchor, content: null });
  });

  test("a rotation re-seals every setting under the new key; playback under the old key is taken for a while", async () => {
    const { t, a, b } = await twoDevices();
    const c = await register(t, { ...mac, name: "Old Mac" }, KEY_C);
    await approve(t, a, c, KEY_A);
    await t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: seal(KEY_A, "searches") });
    await t.mutation(api.settings.put, { token: b.token, key: "playback.autoplay", value: seal(KEY_A, "true") });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: c.deviceId });
    const rows = await t.query(api.settings.list, { token: a.token });
    const at = Object.fromEntries(rows.map((r) => [r.key, r.updatedAt]));
    const KEY_D = "d".repeat(32);
    const rotate = (settings: FunctionArgs<typeof api.keys.rotate>["settings"]) =>
      t.mutation(api.keys.rotate, { token: a.token, fromKeyId: KEY_A, keyId: KEY_D, wraps: [{ deviceId: b.deviceId, wrapped: btoa("w") }], vault: [], settings });
    const conflict = { data: { code: "conflict" } };
    // Every row, at the time it was read, sealed under the new key.
    await expect(rotate([{ key: "search.recent", baseUpdatedAt: at["search.recent"], value: seal(KEY_D, "s2") }])).rejects.toMatchObject(conflict);
    await expect(rotate([
      { key: "search.recent", baseUpdatedAt: at["search.recent"] - 1, value: seal(KEY_D, "s2") },
      { key: "playback.autoplay", baseUpdatedAt: at["playback.autoplay"], value: seal(KEY_D, "a2") },
    ])).rejects.toMatchObject(conflict);
    await expect(rotate([
      { key: "search.recent", baseUpdatedAt: at["search.recent"], value: seal(KEY_A, "still the old key") },
      { key: "playback.autoplay", baseUpdatedAt: at["playback.autoplay"], value: seal(KEY_D, "a2") },
    ])).rejects.toMatchObject({ data: { code: "forbidden" } });
    await rotate([
      { key: "search.recent", baseUpdatedAt: at["search.recent"], value: seal(KEY_D, "s2") },
      { key: "playback.autoplay", baseUpdatedAt: at["playback.autoplay"], value: null }, // one it couldn't open
    ]);
    const after = await t.query(api.settings.list, { token: b.token });
    expect(after).toEqual([expect.objectContaining({ key: "search.recent", value: seal(KEY_D, "s2"), updatedBy: a.deviceId })]);
    expect(after[0].updatedAt).toBeGreaterThan(at["search.recent"]);

    // Settings take only the new key; what a device publishes about itself takes the old one for ten minutes.
    await expect(t.mutation(api.settings.put, { token: b.token, key: "k", value: seal(KEY_A, "1") })).rejects.toMatchObject({ data: { code: "forbidden" } });
    await t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_A) });
    const sent = await t.mutation(api.commands.send, { token: b.token, toDeviceId: a.deviceId, command: { kind: "takeOver", anchor, content: seal(KEY_A, "h") } });
    await t.mutation(api.commands.ack, { token: a.token, commandId: sent.commandId, result: { ok: false, reason: "unreadable" } });
    vi.advanceTimersByTime(10 * 60_000 + 1);
    await expect(t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_A) })).rejects.toMatchObject({ data: { code: "forbidden" } });
    await t.mutation(api.playback.publish, { token: b.token, anchor, content: content(KEY_D) });
  });

  test("a reset deletes the settings nobody can open any more", async () => {
    const base = convexTest(schema, modules);
    const t = base.withIdentity(LEO);
    const a = await register(t, mac, KEY_A);
    const c = await register(t, phone, KEY_C); // asks for the key, never gets it
    await t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: seal(KEY_A, "searches") });
    await t.mutation(api.devices.remove, { token: a.token, deviceId: a.deviceId });
    expect((await t.query(api.devices.list, { token: c.token })).keyId).toBeNull();
    expect(await t.query(api.settings.list, { token: c.token })).toEqual([]);
  });

  test("the raw tables hold no title, artist, album, track id, artwork URL or search text after a session", async () => {
    // The server-side half of the live dump check: everything the functions take is either metadata or sealed.
    const { t, a, b } = await twoDevices();
    await t.mutation(api.playback.publish, { token: a.token, anchor, content: content(KEY_A) });
    await t.mutation(api.settings.put, { token: a.token, key: "search.recent", value: seal(KEY_A, "searches") });
    const sent = await t.mutation(api.commands.send, { token: a.token, toDeviceId: b.deviceId, command: { kind: "takeOver", anchor, content: seal(KEY_A, "h") } });
    await t.mutation(api.commands.ack, { token: b.token, commandId: sent.commandId, result: { ok: true } });
    const dump = JSON.stringify(await t.run(async (ctx) => ({
      playback: await ctx.db.query("playback").collect(),
      queues: await ctx.db.query("queues").collect(),
      commands: await ctx.db.query("commands").collect(),
      settings: await ctx.db.query("settings").collect(),
    })));
    for (const field of ["title", "artists", "album", "providerID", "artwork", "url", "entries", "track\""]) expect(dump).not.toContain(field);
  });
});
