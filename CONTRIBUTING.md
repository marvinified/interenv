# Contributing to inter-env

Contributions are welcome through issues and pull requests at
https://github.com/marvinified/interenv.

## Development

Install dependencies and build the server from the repository root:

```sh
yarn install
yarn build
```

Start the development server with automatic restarts:

```sh
yarn dev
```

Copy `.env.example` to `.env` when local server settings are needed. Use Yarn,
not npm, for dependency and script changes.

## Testing

Run the integration suite after building:

```sh
yarn build
./tests/inter_env_test.sh
```

The test starts a local server and covers setup, pairing, one-time sharing,
nested env files, `.envignore`, sync metadata, cleanup, project limits, deletion,
watcher retry behavior, and uninstall behavior.

For CLI changes, also verify shell syntax:

```sh
sh -n bin/interenv
sh -n install.sh
sh -n tests/inter_env_test.sh
```

## Guidelines

- Keep the CLI compatible with POSIX `sh` on macOS and Linux.
- Do not add Node.js or other runtime dependencies to the CLI.
- Never send plaintext env contents or encryption keys to the server.
- Keep changes focused and include tests for behavior changes.
- Update the README when commands, configuration, or user workflows change.

## Pull Requests

Describe the problem, the chosen behavior, and how it was tested. Keep unrelated
refactors out of the same pull request and make sure generated files, local data,
and `.env` files are not committed.
