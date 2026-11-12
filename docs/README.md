# OpenMusic documentation

Start with the [README](../README.md) for what OpenMusic is and how to get it.

## Using OpenMusic

- [Troubleshooting](troubleshooting.md): sign-in problems, Spotify messages, playback failures, device approval, logs, updating and uninstalling.
- [Spotify](spotify.md): how Spotify sign-in works, switching to your own Client ID, and how Spotify playback works.
- [Privacy](privacy.md): what the hosted sync beta stores, who runs it, how long it keeps data, and how to delete it.
- [Running your own sync server](self-hosting.md): self-hosting the sync backend with Docker or Podman, backups, restore and upgrades.

## Contributing

- [CONTRIBUTING.md](../CONTRIBUTING.md): the repository map, building and testing each platform from a fresh clone, and what to check before a pull request.
- [iPhone app](../iOS/README.md) and [Windows app](../windows/README.md): platform specifics.
- [AGENTS.md](../AGENTS.md): architecture, invariants and rules, written for coding agents.
- [Maintainer tooling](maintainers.md): optional scripts for remote build machines, deployments and screenshots.
- [SECURITY.md](../SECURITY.md) and the [Code of Conduct](../CODE_OF_CONDUCT.md).

## Design

- [Sync design](sync-design.md): the sync contract between the backend, the clients and the apps; what the server can see; tables, functions and client internals.
- [Accounts design](accounts-design.md): accounts, device registration, the sign-in key and its six-digit verification exchange, rotation, and the threat model.
- [First run](onboarding.md): the first-run flow every app shows.
- [History](history.md): migrations, removed features and dated verification runs.
