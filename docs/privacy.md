# Privacy: the hosted sync beta

This page covers OpenMusic's hosted sync server, the default when you sign in to sync. OpenMusic works without it. If you never sign in to sync, the server stores nothing about you: the apps still make an anonymous request to it at launch to read its sign-in settings (retried if it fails), which shows the server your IP address and the sync library's version like any web request, and otherwise talk only to YouTube Music, Spotify and LRCLIB. If you run [your own server](self-hosting.md), you are its operator and this page describes what your server stores instead.

## The hosted server is a beta

The hosted server runs on a development setup of its sign-in provider. That means:

- It is limited: the number of accounts it can hold is capped, and it can stop accepting new ones.
- Sign-in pages may show a banner saying the sign-in provider is in development mode.
- It may be reset, which deletes every account on it. Your devices keep their music sign-ins and settings; you sign in to sync again.

[Self-hosting](self-hosting.md) is the stable option.

## Who runs it

The OpenMusic maintainers ([github.com/opencoredev](https://github.com/opencoredev)) operate the hosted server. Two services process data for it:

- **Convex** hosts the sync backend: the database and the functions in `sync/convex/`.
- **Clerk** handles sign-in. Clerk holds your email address and, if you sign in with Apple or Google, the name and picture those services share. The sync server itself never receives your email address or name.

Both see the network address your devices connect from, as any web service does, and keep their own operational logs under their own policies.

## What the server stores

Everything that says what you listen to or search for is encrypted on your devices with a key the server never has: the current song, your queue, handoffs between devices, error messages that could name a song, your recent searches, your setting values, and your YouTube Music and Spotify sign-ins. The server stores those as encrypted blobs it can't open.

It stores in readable form:

- **Your account:** a Clerk user ID (Clerk's address plus a random ID), when the account was made, and when it expires.
- **Each device:** the name you give it, which can identify you (for example "Riley's iPhone"), its platform, hardware model and app version, when it joined and when it was last seen.
- **A hash of each device's token.** Each device sends its token with every call to prove which device it is; the server keeps only the SHA-256 hash.
- **Timing and position of playback:** for each device, whether it is playing, the position, playback rate, volume, shuffle and repeat, the length of the current song, and when this last changed.
- **Remote commands:** their kind (pause, next, seek, set volume), sender, target, the seek position or volume, and when they were sent and acknowledged.
- **Which settings changed and when**, and which services have a synced sign-in, without their values.
- **Key-exchange data:** public keys, fingerprints of the encryption key, and the encrypted copies of it made for each approved device.

[What the server can see](sync-design.md#what-the-server-can-see) lists every field.

## What it can infer

From the readable parts, whoever runs the server can tell when you listen, on which device, and for how long, how often you skip, roughly how long your queue and recent-searches list are, and the length of each song. Song length together with skip times could, with effort, be matched against a catalogue to guess a song. It can't read what you play, what you search for, or your sign-ins.

## How long it keeps data

- Remote commands expire 2 minutes after they are sent; a cleanup that runs every minute then deletes them, so an expired command can stay a little longer before it is gone.
- Each device's playback row holds only its latest state, replaced on every change, and is deleted with the device.
- A device's rows (playback, queue, commands, key data) are deleted when it signs out or is removed.
- An account no device has used for 60 days is deleted with everything in it, by a cleanup that runs every hour. An account is also deleted when its last device signs out.
- Records that refuse the tokens of removed devices are kept for 30 days, also removed by the hourly cleanup. Rate-limit counters and remembered setting writes expire within minutes.

Clerk keeps your Clerk account (email address, sign-in history) until it is deleted; see below.

## Deleting your data

1. **Sign out of sync on every device** (Settings › Account › Sign Out on the Mac and iPhone; Settings, OpenMusic account, Sign Out on Windows). Each sign-out removes that device and its data from the server, and the last one deletes the account's sync data. If the server can't be reached when you sign out, the device signs out locally and the removal waits: it is retried the next time that device signs in to the same account. A device that never signs in again keeps its data on the server for as long as any other device on the account is in use (the 60-day cleanup only removes accounts that are idle as a whole), so sign out while online, or remove that device from another device's list. A device you no longer have can be removed from another device's device list.
2. **To delete your Clerk account too** (your email address), open a ["Delete my sync account" issue](https://github.com/opencoredev/openmusic/issues/new?template=delete-sync-account.yml). The form asks for nothing personal; a maintainer follows up to confirm which account is yours before deleting it.

Security problems go through [private vulnerability reporting](../SECURITY.md), not issues.

## The alternative

[Run your own server](self-hosting.md): the same backend on a machine you control, with a Clerk app you create. Then you are the only operator, and nothing leaves your machine and your Clerk app.
