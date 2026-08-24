# inter-env

`inter-env` syncs `.env` and `.env.*` files across machines for the same Git project.

The CLI command is `interenv`. By default it uses the hosted free service at `https://interenv.bytode.dev`, so most users only install the CLI and run `interenv init` inside a repo.

Each user has one inter-env account key. Env files are encrypted on the device before upload, and the backend stores only encrypted files.

## Install

Install the client:

```sh
curl -fsSL https://interenv.bytode.dev/install.sh | sh
```

If `/usr/local/bin` needs permissions:

```sh
curl -fsSL https://interenv.bytode.dev/install.sh | sudo sh
```

## Requirements

Client machines need:

- `sh`
- `git`
- `curl`
- `openssl`
- `tar`

macOS and most Linux machines already have these, except Git may need to be installed separately. Windows users should run `interenv` through Git Bash or WSL, not `cmd.exe` or PowerShell directly.

Self-hosting the backend needs Node.js. The server is TypeScript and uses Express.

## Quick Start

### New Account

Inside a Git repo:

```sh
interenv init
```

Choose:

```text
1) Set up fresh account
```

The command creates an account id, private account key, device id, local config at `~/.inter-env/config`, a project id from the repo's Git `origin`, and a background watcher.

It also prints a recovery key. Keep it private. Anyone with that key can decrypt your synced env files.

### Pair Another Device

On an already linked device:

```sh
interenv pair
```

That prints a one-time pairing code.

On the new device, inside the same Git project:

```sh
interenv init
```

Choose:

```text
2) Link this device with a pairing code
```

Paste the pairing code. The new device downloads an encrypted key bundle, decrypts it locally using the pairing code, saves the account key, then pulls the project env files.

The server never receives the account key in plaintext. Pairing codes are one-time and expire after 15 minutes by default.

## How It Works

`inter-env` groups projects by normalized Git `origin` URL. These are treated as the same project:

```text
git@github.com:owner/app.git
https://github.com/owner/app.git
```

It syncs env files in the repo root and subdirectories:

```text
.env
.env.*
```

Examples:

```text
.env
.env.local
.env.production
.env.development
apps/api/.env
packages/web/.env.local
```

It skips common generated or dependency directories, including `.git`, `node_modules`, `vendor`, `dist`, `build`, `.next`, `.turbo`, `.cache`, and `coverage`.

When a watched env file changes, the client packages the env files with `tar`, encrypts the package with the local account key using `openssl`, and uploads the encrypted blob to the backend.

Other linked machines periodically pull the encrypted blob, decrypt it locally, and apply the env files to the matching Git project.

To point the CLI at a private or self-hosted backend, pass a URL with a token:

```sh
INTER_ENV_SERVER_URL="https://private.example.com/my-token" interenv init
```

or:

```sh
interenv init --fresh --server "https://private.example.com/my-token"
```

The client stores `https://private.example.com` as the server URL and sends `my-token` as an auth header on every request.

## Self-Hosting

On your server:

```sh
yarn install
yarn build
yarn start
```

For Coolify, use the repository root (`/`) with:

```text
Build command: yarn build
Start command: yarn start
Port: 4010
```

Mount persistent storage for the data directory and set `INTER_ENV_SERVER_DATA` to that mount path.

Optional settings:

```sh
HOST=0.0.0.0 \
PORT=4010 \
INTER_ENV_SERVER_DATA=/var/lib/inter-env \
INTER_ENV_SERVER_TOKEN=my-token \
yarn start
```

See `.env.example` for all server settings.

Use HTTPS in front of the backend for real devices. The env payloads are encrypted before upload, but HTTPS still protects pairing codes and request metadata in transit.

The backend stores files like this:

```text
data/
  accounts/<account-id>/projects/<project-id>/env.bin
  accounts/<account-id>/projects/<project-id>/env.rev
  accounts/<account-id>/projects/<project-id>/devices/<device-id>.rev
  pairs/<pair-id>.bin
```

`env.bin` is encrypted before it reaches the server. Pairing files are encrypted key bundles and are deleted after they are used.

## Server Cleanup

The server tracks a small revision acknowledgement per device and project. After at least two devices have registered a project, the server deletes `env.bin` when every known device has acknowledged the same latest encrypted revision.

That conserves storage while avoiding early deletion before another linked machine has pulled the env files. The server keeps only tiny revision files after cleanup.

If you link a brand-new device after cleanup, run this once on an existing device for that project:

```sh
interenv push
```

Then run `interenv pull` or `interenv sync` on the new device.

## Commands

```sh
interenv init [repo]                         Set up account/link device, register repo, sync
interenv pair                                Create a one-time pairing code
interenv sync [repo]                         Pull then push changed env files
interenv pull [repo]                         Pull env files from the server
interenv push [repo]                         Upload local env files
interenv watch                               Run the watcher in the foreground
interenv start                               Start the watcher in the background
interenv stop                                Stop the watcher
interenv status                              Show account, watcher, and repo status
interenv list                                List registered repos
interenv version                             Print the version
```

## Security Model

- Env files are encrypted before upload.
- The backend stores encrypted blobs only while a known device still needs to pull them.
- The account key stays in `~/.inter-env/config` on linked devices.
- Pairing transfers the account key through a one-time encrypted bundle.
- The backend has no database.
- If someone gets your account key or recovery key, they can decrypt your env files.

By default, deletion is not synced. If a linked project is missing an env file that exists in the encrypted server copy, `interenv pull` restores it.
