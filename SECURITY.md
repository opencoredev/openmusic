# Security policy

## Reporting a vulnerability

Report security problems privately through GitHub: [open a private vulnerability report](https://github.com/opencoredev/openmusic/security/advisories/new). Only the maintainers see it. Please don't open a public issue, discussion or pull request for a vulnerability before it is fixed.

Include what you can of:

- what is affected (app and platform, sync backend, or the encryption) and which version or commit;
- what an attacker can do, and what they need first (network position, a stolen device, a malicious sync server, another app on the same machine);
- steps to reproduce, or a proof of concept;
- anything you've found about the cause.

Leave out real credentials: don't include your cookies, tokens, keys or anyone else's personal data. Use a test account if you need one.

The maintainers will acknowledge the report, keep you updated in the advisory, and credit you when the fix is published unless you'd rather not be named.

## Scope

In scope:

- The OpenMusic apps for Mac, iPhone and Windows in this repository, including how they store sign-ins (Keychain, the Mac's Keychain XPC service, Windows DPAPI) and what they log.
- The sync backend in `sync/convex/`, the self-hosting setup in `sync/self-host/`, and the hosted beta server's configuration.
- The sync encryption and key exchange: content sealing, the six-digit device approval, key rotation, and the vault for service sign-ins ([docs/sync-design.md](docs/sync-design.md), [docs/accounts-design.md](docs/accounts-design.md)).

Out of scope: vulnerabilities in YouTube, Spotify, Clerk, Convex or other third-party services themselves (report those to their owners), and problems that need an already compromised device or operating system.

## Supported versions

Security fixes go into the latest release and the `main` branch. Older releases don't get fixes; update to the latest.
