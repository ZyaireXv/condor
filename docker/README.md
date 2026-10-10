# Condor Docker / GHCR

This image contains the compiled React dashboard and Condor's Python backend.
It does not include Hummingbot API, Gateway or Hummingbot trading containers.
It runs Python 3.12 as UID/GID 10001, with Chromium for chart exports and
FFmpeg for audio support. AI providers and optional external AI CLI tools
still need their own runtime configuration; no keys are built into the image.

## Start the local dashboard

From the repository root:

```bash
docker compose pull
docker compose up -d
docker compose logs -f condor
```

Open http://localhost:8088. The supplied Compose file explicitly enables
`CONDOR_MODE=local` and uses `ADMIN_USER_ID=1` for a new installation. Local
mode has no password; the host port is deliberately bound to `127.0.0.1`.
Keep this binding. On a VPS, use an SSH tunnel:

```bash
ssh -L 8088:127.0.0.1:8088 user@your-server
```

If your package is private, authenticate Docker to GHCR with your account's
existing package-read credentials before pulling. GitHub Actions publishing
uses its short-lived `GITHUB_TOKEN`; no repository PAT secret is required.

## Connect to Hummingbot API

Add your API server from Condor's dashboard, using its URL and credentials.
`localhost` inside Condor refers to the Condor container. If API runs in
another Compose project, attach Condor to that project's Docker network and
use the API service's actual DNS name, for example `http://hummingbot-api:8000`.
If API runs directly on a Linux host, explicitly configure an accessible host
address and network access. Do not publish an unauthenticated API to the
internet to make this connection work.

No wallet, exchange credential, Telegram bot or AI provider is configured by
building this image. Starting the supplied Compose file does not provision
trading bots or intentionally place orders.

## Data, migration and updates

| Volume | Content |
| --- | --- |
| `condor-data` → `/app/data` | `config.yml`, its backup, audit log, preferences, bot state and operational data |
| `condor-runtime` → `/app/.condor` | Conversations, local agents, runtime state |
| `condor-reports` → `/app/reports` | Saved reports and assets |

Named volumes receive the image's directory ownership on first creation.
For existing bind mounts, grant UID/GID 10001 appropriate access; do not use
world-writable permissions. Back up all three volumes before upgrading.
`docker compose down` preserves them; adding `--volumes` removes them.

For an existing installation, preserve its admin identity: set `ADMIN_USER_ID`
to the ID already in its `config.yml`, and copy its configuration, operational
data, `.condor` and reports to the corresponding volumes. Do not reset it to
`1` merely to enter local mode.

Update by pulling a new image and recreating the service:

```bash
docker compose pull
docker compose up -d
```

The dashboard's git-based source updater is not the container upgrade path.
The image excludes `.git`, local configuration and environment files. For
reproducible deployments, replace `:latest` with a published `:sha-<12 hex>`
tag or the digest shown in the successful workflow summary.

## Telegram mode

The image defaults to Telegram mode and refuses to start without a token.
To use Telegram, change the Compose environment to `CONDOR_MODE=telegram`,
provide `TELEGRAM_TOKEN` and your numeric `ADMIN_USER_ID` at runtime, and keep
those values out of git. Set `WEB_URL` to the dashboard URL including port
8088. The existing Telegram `/web` authentication flow is retained.

## Build and release

Pushes to `main` that change image inputs build and publish
`ghcr.io/zyairexv/condor:latest` and a commit-specific tag. The workflow also
supports manual runs from `main`. Pull requests only build and test.

The workflow compiles the frontend, installs Python dependencies from
`uv.lock`, tests an AMD64 container, validates Compose, then publishes a
multi-platform AMD64/ARM64 manifest with provenance and SBOM. Before publishing,
it also builds the ARM64 image and runs the same startup checks under emulation.
Those checks cover static assets, local admin login, authenticated API access,
configuration/session persistence after restart and graceful shutdown. They
use no real API account, wallet, exchange connection or trading transaction.
They do not verify live trading, external providers or Telegram connectivity.
If either architecture's startup check fails, publishing is skipped.

Actions are pinned to verified upstream commit SHAs. Only the container job
requests `packages: write`; it cannot modify repository contents. A newly
forked repository may require enabling Actions from the repository's Actions
tab before its first run. New GHCR packages may be private; this workflow does
not change package visibility.

Local build and smoke test, on a machine with Docker:

```bash
docker build -t condor:local .
bash docker/smoke-test.sh condor:local
```
