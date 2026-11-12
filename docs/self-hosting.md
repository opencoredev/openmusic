# Running your own OpenMusic server

OpenMusic syncs through OpenMusic's hosted server unless you give it another one. Your own server is the open-source Convex backend running `sync/convex/` on a machine you control, with sign-in through a Clerk app you control. The apps need one thing from you: the server's address. They read the rest (which Clerk app to sign in with) from the server.

What your server stores: each account's devices (names, models, app versions, last seen), where each device's playback is (position, playing or paused, volume, shuffle, repeat, the song's length), remote commands (pause, next, seek to a position), the names of synced settings and when they changed, and, encrypted end to end, what each device plays, its queue, recent searches, setting values and the YouTube Music and Spotify sign-ins. The server never holds the key to the encrypted parts, so even as its operator you can't read what anyone listens to or searches for. It stores no email addresses or names; those stay in Clerk. `docs/sync-design.md`, "What the server can see", lists every field.

## What you need

- A Linux or macOS machine that stays on, with Docker (with Compose) or Podman (with `podman-compose`), Node.js 20 or newer, curl, and this repository.
- A Clerk account ([clerk.com](https://clerk.com), free).
- A way to reach the machine over HTTPS from your devices. [Tailscale](https://tailscale.com) is the easiest: it gives the machine an HTTPS address only your own devices can reach. A domain with a reverse proxy works too.

## 1. Make a Clerk app

In the [Clerk dashboard](https://dashboard.clerk.com):

1. Create an application. Under **User & authentication › Email**, turn on sign-in with an email address and **Email verification code**. Turn passwords off, and don't require a username, phone number or name. OpenMusic signs in with only an email address and a code. If passwords stay required (Clerk's default), OpenMusic gives a new account a long random password that nobody sees.
2. Optional: turn on **Google** and **Apple** under **SSO connections**. OpenMusic shows a button for each one that is on.
3. Under **Configure › Native applications**, turn on the **Native API** and add `openmusic://oauth-callback` to the allowed redirect URLs (Google and Apple need it).
4. Create the JWT template OpenMusic asks for. It must be named `convex`, with the audience `convex`. Either activate the **Convex** integration (**Configure › Integrations › Convex**), or use **JWT templates › New template › Convex** and keep the name `convex`. OpenMusic needs only the `aud` claim. If the template has others, such as name or email, you can delete them so your server never receives them. Or make the template with one Backend API call, using the **Secret key** from **API keys**:

   ```bash
   read -rs -p "Clerk secret key: " CLERK_SECRET_KEY; echo
   printf 'header = "Authorization: Bearer %s"\n' "$CLERK_SECRET_KEY" |
     curl --config - -X POST https://api.clerk.com/v1/jwt_templates -H "Content-Type: application/json" \
       -d '{"name":"convex","claims":{"aud":"convex"},"lifetime":300,"allowed_clock_skew":10}'
   unset CLERK_SECRET_KEY
   ```

   The key goes to curl on its standard input, so it never shows in the process list or your shell history. It is needed only for this call. Keep it out of `.env`, the server and the apps.
5. From **API keys**, note the **Publishable key** (`pk_test_…` or `pk_live_…`) and the **Frontend API URL** (`https://verb-noun-12.clerk.accounts.dev`). Both are public.

A development instance is enough for a household. A Clerk production instance needs a domain of your own; if you have one, use its keys instead.

**Without Clerk:** nothing works today. The apps sign in only through Clerk's API, and the server accepts only tokens from the Clerk app named in its settings. Another sign-in service would need code in the apps and in `sync/convex/auth.config.ts`.

## 2. Start the server

```bash
cd sync/self-host
cp .env.example .env      # put your publishable key and Frontend API URL in it
./deploy.sh
```

`deploy.sh` starts the backend from `compose.yaml`, using `docker compose`, `podman compose` or `podman-compose`, whichever it finds first. The image is pinned to a tested version. The backend listens on `127.0.0.1:3210` only, so nothing outside the machine can reach it yet. The script then generates the admin key and installs the Convex CLI (`npm ci` in `sync/`). Next it sets `CLERK_JWT_ISSUER_DOMAIN` and `CLERK_PUBLISHABLE_KEY` on the backend, deploys `sync/convex`, and checks that the server's public `config:get` names your Clerk app. It stops with the reason if the two Clerk values belong to different Clerk instances.

The admin key can read and change everything on the server. `deploy.sh` saves it in `~/.config/openmusic-sync/openmusic-sync.admin-key`, readable by you only and outside the repository, and gives it to the Convex CLI through the environment, never on a command line. It makes the key once and reuses it while the backend accepts it. Don't share it, and don't put it in `.env`.

**On a shared machine:** the backend image's own key tool takes the backend's instance secret as a command-line argument, so while the key is being made (a fraction of a second, on the first run and after the data is reset), other users of the machine could read that secret in the process list. On a machine with other users you don't trust, mount `/proc` with `hidepid=2` first, or run the server on a machine of its own.

## 3. Give it an HTTPS address

OpenMusic connects to the backend's client port (3210) over HTTPS and a WebSocket on the same address. It doesn't use the backend's HTTP actions port (3211), so `compose.yaml` doesn't publish that port.

**With Tailscale** (the server and your devices on the same tailnet; in the Tailscale admin console, turn on MagicDNS and HTTPS certificates under **DNS**):

```bash
sudo tailscale serve --bg --https=3443 http://127.0.0.1:3210
```

The server is now at `https://<machine>.<tailnet>.ts.net:3443`, with a real certificate, and reachable only from your tailnet. Don't use `tailscale funnel`: it would put the server on the public internet. Any free port works in place of 3443. Funnel never serves ports other than 443, 8443 and 10000, so a port outside those stays tailnet-only even if Funnel is on for the machine. `tailscale serve --https=3443 off` removes it.

**With a domain:** point a name at the machine and put a reverse proxy in front of `127.0.0.1:3210` that passes WebSockets through. With Caddy, for example:

```
sync.example.com {
    reverse_proxy 127.0.0.1:3210
}
```

Put the address in `.env` as `OPENMUSIC_SERVER_URL` (scheme, host and port, no path) and run `./deploy.sh` again. It tells the backend its public address and checks that `config:get` answers there:

```
Done. Paste this into OpenMusic (Use your own server, or Settings › Account › Server):
https://my-server.my-tailnet.ts.net:3443
```

Plain `http://` works only for a server on the same computer (`http://localhost:3210`) or your local network (`http://192.168.1.20:3210`, `http://my-server.local:3210`), and the backend's port must be reachable there (by default it listens on this machine only). OpenMusic refuses it for anything else, Tailscale addresses included: macOS and iOS allow plain http only on the local network, and it would expose your sign-in token on the way.

## 4. Paste the address into OpenMusic

- **Mac:** on the welcome screen, click **Use your own server**; or open Settings › Account › Advanced › Server › **Use Your Own…**.
- **iPhone:** on the welcome screen, tap **Use your own server**; or open Settings › Account › Server.

OpenMusic asks the server for `config:get` before it switches, and refuses an address that doesn't answer or isn't set up, with the reason. Switching servers signs that device out of the old server. Do the same on each device, then sign in with the same email on each. The first device holds the key to your sign-ins. Each later device asks for it, and you allow it on a device that has it after comparing a six-digit code.

## Running it

- **Upgrade:** pull the repository and run `./deploy.sh` again. A server set up before the rename to OpenMusic has `MEDLEY_SERVER_URL` and `MEDLEY_PORT` in `.env`: `deploy.sh` stops and lists the steps (rename them to `OPENMUSIC_SERVER_URL` and `OPENMUSIC_PORT`, add `COMPOSE_PROJECT_NAME=medley-sync` so the server keeps its `medley-sync_data` volume, move the admin key from `~/.config/medley-sync` to `~/.config/openmusic-sync`). To move to a newer backend, change `CONVEX_VERSION` in `.env` to a newer tag from [the backend's image list](https://github.com/convex/convex-backend/pkgs/container/convex-backend) and run `./deploy.sh`. The data stays in the `openmusic-sync_data` volume. When an upgrade changes how stored rows look, Convex refuses to deploy until the rows match, and the release notes say which tables to clear first. The change that encrypted playback and settings is one: clear `playback`, `queues`, `commands`, `settings` and `settingOps` in the dashboard (see Look inside below; Data › the table › Clear table), then deploy and update every OpenMusic app. The server cleans up after itself: commands, rate-limit counters and remembered settings writes expire, and accounts nobody used for 60 days are deleted.
- **Look inside:** `./deploy.sh convex data devices` lists the devices table; `./deploy.sh convex logs` follows function logs. For a web dashboard, run `docker compose -p openmusic-sync --profile dashboard up -d dashboard` in `sync/self-host` (`podman-compose` takes the same arguments; it may print "no such container" while it starts, which is harmless), open `http://127.0.0.1:6791` on the server and paste the admin key. `… --profile dashboard stop dashboard` stops it.
- **Back up:** `umask 077; ./deploy.sh convex export --path ~/openmusic-backup.zip`, outside the repository so it can't end up in a commit (ignore the dashboard.convex.dev link it prints: that is for Convex Cloud). The file holds device rows, token hashes and the encrypted sign-ins, so keep it as private as the server.
- **Stop and start:** in `sync/self-host`, `docker compose -p openmusic-sync --profile dashboard down` (or `podman-compose` with the same arguments) stops the server, and the dashboard if it ran, and keeps the data; `./deploy.sh` starts it again. Docker restarts it after a reboot. Rootless Podman does only if you run `systemctl --user enable podman-restart.service` and `loginctl enable-linger $USER` once.
- **Two servers on one machine:** give the second copy its own `COMPOSE_PROJECT_NAME`, `OPENMUSIC_PORT` and `DASHBOARD_PORT` in its `.env`. The admin key file is named after the project.
- **Remove it:** `docker compose -p openmusic-sync --profile dashboard down -v` deletes the server and all its data. Then run `tailscale serve --https=3443 off` and delete `~/.config/openmusic-sync/openmusic-sync.admin-key`.

## On Convex Cloud instead

The backend runs on [Convex Cloud](https://convex.dev) too (the free tier is enough for a household). Create a project and deploy key as Convex's [production docs](https://docs.convex.dev/production/hosting/) describe. Then, from `sync/`, set `CLERK_JWT_ISSUER_DOMAIN` and `CLERK_PUBLISHABLE_KEY` with `npx convex env set` before the first `npx convex deploy`: Convex refuses `auth.config.ts` without the issuer. Paste the deployment's `https://<name>.convex.cloud` URL into OpenMusic, not the `.convex.site` one. This guide's tested path is the self-hosted one above.

## Troubleshooting

- **`deploy.sh` stops at "the server works on this machine, but … doesn't answer config:get".** The HTTPS step isn't in place: check `tailscale serve status` or the proxy, and that `OPENMUSIC_SERVER_URL` matches it exactly, port included.
- **`BadAdminKey: The provided admin key was invalid`** when running the Convex CLI by hand: generate the key with `exec -T` (`docker compose -p openmusic-sync exec -T backend ./generate_admin_key.sh`). Without `-T` the key ends in a carriage return. `env set` accepts that key; `deploy` rejects it. Or run the command through `./deploy.sh convex …`, which handles the key for you.
- **"This server isn't set up for sign-in yet."** `CLERK_PUBLISHABLE_KEY` is missing or malformed on the server: run `./deploy.sh` again.
- **"That address doesn't run the OpenMusic sync server."** The address answers, but not with this backend. Check you used the client address (port 3210 behind your HTTPS), not 3211 or the dashboard's 6791, and that `deploy.sh` finished.
- **"Plain http:// doesn't work over Tailscale."** Use the `https://…ts.net` address from step 3.
- **Signed in, but the device never shows up.** The server refuses the token. `CLERK_JWT_ISSUER_DOMAIN` must be exactly the Frontend API URL of the same Clerk instance as the publishable key (`deploy.sh` checks this), and the JWT template must be named `convex` with audience `convex`.
- **"…asks for a phone number…, which OpenMusic doesn't support."** Turn off the extra required fields in step 1 (a required password alone is handled).
