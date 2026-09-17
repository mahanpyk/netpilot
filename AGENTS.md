# Agent Rules — NetPilot Desktop

## Before you change anything

1. Read [`HANDOFF.md`](HANDOFF.md) first. It is the source of truth for architecture, file map, native contracts, and feature status.
2. Prefer extending existing modules over inventing parallel paths.

## When you change something

Update [`HANDOFF.md`](HANDOFF.md) in the **same change** if you:

- add, rename, move, or delete important source files/directories
- change MethodChannel / EventChannel / XPC message shapes
- change data models or persistence format
- add or remove a product capability
- change helper security, signing, entitlements, or privilege model
- revise architecture decisions or known limitations

Also append a short entry under **Changelog** in `HANDOFF.md`.

## Scope discipline

- macOS first; Windows is deferred.
- IPv4 only for MVP.
- Destinations: hostname / URL (hostname only) / IPv4 / CIDR — never URL path routing, never TLS MITM.
- Privileged route mutation goes only through the signed helper API (`add` / `delete` / `reconcile`). Never shell out with free-form user strings.

## Do not

- Commit secrets, Apple team IDs with private keys, or machine-local signing identities into the repo.
- Bypass the helper with ad-hoc `sudo` from Flutter.
- Leave `HANDOFF.md` stale after structural or contract changes.
