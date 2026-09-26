# Provenance

This repository is a **fork of [OpenSpec](https://github.com/Fission-AI/OpenSpec)**
by Fission-AI, licensed under the MIT License. The full upstream license is kept
verbatim in [LICENSE](LICENSE).

## Fork point

| | |
|---|---|
| Upstream | https://github.com/Fission-AI/OpenSpec |
| Upstream version at fork | **v1.13.0** |
| Upstream commit | `9d4e597` — "Version Packages (#1822)" |
| Forked on | 2026-09-15 |

The complete upstream git history (843 commits) is preserved in this repository,
so `git log`, `git blame`, and `git merge upstream/main` all work normally.

## What this fork contains

This is a **templates-only** personal fork. The OpenSpec CLI is **not** forked —
it installs from npm as usual and is pointed at the schema in this repo.
See [README.md](README.md) for how that works.

Kept from upstream:

| Path | Why |
|---|---|
| `schemas/spec-driven/` | Pristine upstream schema — the baseline we diff our own against |
| `skills/` | Upstream agent skill instructions, kept as read-only reference |
| `docs/` | Upstream documentation, notably `docs/customization.md` |
| `LICENSE` | Required by MIT |

Added here (paths upstream does not use, so they never cause merge conflicts):

| Path | Why |
|---|---|
| `schemas/casadei/` | **The customized schema** — this is the one that gets edited |
| `tools/` | Install and upstream-sync helpers, and their tests |
| `.github/workflows/installers.yml` | CI for the scripts and schema (upstream's own workflows stay removed) |
| `.github/workflows/upstream-sync.yml` | Weekly automatic merge of upstream, via PR and CI |
| `NOTICE.md`, `README.md` | This fork's own documentation |

Removed from upstream (1171 files → 49): the CLI source (`src/`, `test/`, `bin/`,
build and lint config, `package.json`), upstream's own dogfooded project data
(`openspec/` — 632 files), their documentation site (`website/`, `docs-lab/`),
`assets/`, and their release automation (`.changeset/`, `.github/`).

## Modifications

Per the MIT License, changes from upstream are noted here.

- `schemas/casadei/` — copied from `schemas/spec-driven/` at v1.13.0, with
  `name` and `description` changed. All further customization happens in this
  directory.
