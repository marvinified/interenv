# inter-env

`inter-env` syncs `.env` and `.env.*` files across machines for the same Git project.

The CLI command is `interenv`. By default it uses the hosted free service at `https://interenv.bytode.dev`. Run `interenv setup` once per machine, then run `interenv init` inside each repo you want to sync.

Each user has one inter-env account key. Env files are encrypted on the device before upload, and the backend stores only encrypted files.

## Install

Install the client:

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

### First Machine

```sh
interenv setup    # choose "Set up fresh account"
interenv init     # run inside each repo to sync
```

Keep the recovery key printed during setup private.

### Another Machine

```sh
# On an existing machine
interenv pair # returns a 6-character pairing code

# On the new machine
interenv setup    # choose "Link this device" and enter the pairing code
interenv init     # run inside each repo to sync
```



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

Every five seconds, the client compares a small cloud metadata record with an account-keyed hash of local env paths and contents. Matching hashes require no env download. Blank lines, trailing newlines, and `CRLF` versus `LF` do not change the hash, but changing an env value or file path does.

When hashes differ, a newer cloud timestamp pulls the encrypted snapshot; otherwise the local snapshot is packaged with `tar`, encrypted with the account key, and uploaded. The server never receives plaintext env contents or an unkeyed content hash.

On a repo's first `interenv init`, the client pulls an existing cloud copy before it considers uploading local files. Local files are uploaded only when no cloud copy exists. Creating a pairing code also refreshes registered project blobs so the new machine can pull even after normal server cleanup.

Pairing codes use six uppercase, ambiguity-free characters. They are one-time, expire after 15 minutes by default, and protect the temporary key bundle with a deliberately expensive key-derivation step. Active codes are reserved atomically; if a collision occurs, the client generates another code before displaying it.

To point the CLI at a private or self-hosted backend, pass a URL with a token:

```sh
INTER_ENV_SERVER_URL="https://private.example.com/my-token" interenv setup
```

or:

```sh
interenv setup --fresh --server "https://private.example.com/my-token"
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

## Account Deletion

To permanently delete the account, all of its server data, and local inter-env state:

```sh
interenv account delete
```

Deletion requires the account id as confirmation and a separate deletion secret shared between paired devices. The deletion secret cannot decrypt env files. The server keeps only a zero-byte revocation marker so another paired machine cannot recreate the deleted account.

To remove only the CLI and keep the account:

```sh
interenv uninstall
```

## Commands

```sh
interenv setup                               Create an account or link this machine
interenv setup --fresh --server URL[/token]  Create an account non-interactively
interenv setup --link --server URL[/token] --code CODE
interenv init [repo]                         Register and sync a Git repo
interenv pair                                Create a one-time pairing code
interenv account delete                      Delete the account and local state
interenv sync [repo]                         Pull then push changed env files
interenv pull [repo]                         Pull env files from the server
interenv push [repo]                         Upload local env files
interenv watch                               Run the watcher in the foreground
interenv start                               Start the watcher in the background
interenv stop                                Stop the watcher
interenv status                              Verify account and show watcher/repo status
interenv list                                List registered repos
interenv upgrade                             Upgrade the CLI
interenv uninstall                           Remove the CLI only
interenv version                             Print the version
```



## Security Model

- Env files are encrypted before upload.
- The backend stores encrypted blobs only while a known device still needs to pull them.
- The account key stays in `~/.inter-env/config` on linked devices.
- Account deletion uses a separate secret that cannot decrypt env files.
- Pairing transfers the account key through a one-time encrypted bundle.
- The backend has no database.
- If someone gets your account key or recovery key, they can decrypt your env files.

By default, deletion is not synced. If a linked project is missing an env file that exists in the encrypted server copy, `interenv pull` restores it.
