# OpenSpec, my way

[![CI](https://github.com/vcasadei/openspec-casadei/actions/workflows/installers.yml/badge.svg?branch=main)](https://github.com/vcasadei/openspec-casadei/actions/workflows/installers.yml)

My personal fork of [OpenSpec](https://github.com/Fission-AI/OpenSpec) v1.13.0,
set up the way I like to work.

The whole point of this repo is [`schemas/casadei/`](schemas/casadei/) — the
templates and instructions that decide how proposals, specs, designs, and task
lists get written, with my engineering standards baked in.

I don't fork the CLI. It installs from npm like normal; it just reads my schema
instead of the stock one.

---

# Setup

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| **Node.js ≥ 20.19.0** | The CLI runs on Node | `node --version` |
| **Git** | To clone this repo | `git --version` |

If Node is missing or too old:

```powershell
# Windows
winget install OpenJS.NodeJS.LTS
```

```bash
# macOS
brew install node

# Linux (Debian/Ubuntu) — distro packages are often too old, so use nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
nvm install --lts
```

## Step 1 — Install the OpenSpec CLI

Same command everywhere:

```bash
npm install -g @fission-ai/openspec@latest
```

Verify:

```bash
openspec --version
```

> If `openspec` isn't found, your global npm bin directory isn't on `PATH`.
> `npm prefix -g` prints where it installed; add that directory's `bin` to `PATH`.

## Step 2 — Clone this repo

Clone it once, somewhere permanent. You'll come back to it to install the schema
into new projects and to pull upstream updates.

```powershell
# Windows (PowerShell)
mkdir $env:USERPROFILE\workspace -Force
cd $env:USERPROFILE\workspace
git clone git@github.com:vcasadei/openspec-casadei.git
cd openspec-casadei
```

```bash
# macOS / Linux
mkdir -p ~/workspace && cd ~/workspace
git clone git@github.com:vcasadei/openspec-casadei.git
cd openspec-casadei
```

## Step 3 — Install the schema

Two scopes. Pick based on who else touches the project.

Each mode does more than copy files:

| Mode | Also does |
|---|---|
| `--user` | Writes the **authorship rule** into `~/.claude/CLAUDE.md`, so it applies to *every* session — not just an `/opsx:apply` run |
| `--project` | **Selects the schema** in that project's `openspec/config.yaml`, so there's nothing left to edit by hand. Add `--claude` to also write the **authorship rule** into `<project>/CLAUDE.md`, and `--secrets medium\|high` to add **secret protection** ([below](#secret-protection)) |

### Option A — machine-wide (recommended for my own projects)

Installs once, works in every project on this machine, nothing committed.

```powershell
# Windows (PowerShell), from the repo root
.\tools\install.ps1 -User
```

```bash
# macOS / Linux, from the repo root
./tools/install.sh --user
```

Where the files land:

| OS | Destination |
|---|---|
| Windows | `%LOCALAPPDATA%\openspec\schemas\casadei\` |
| macOS | `~/.local/share/openspec/schemas/casadei/` |
| Linux | `~/.local/share/openspec/schemas/casadei/` |

> **macOS note:** it really is `~/.local/share`, not `~/Library/Application Support`.
> OpenSpec uses the XDG convention on every non-Windows platform. If
> `$XDG_DATA_HOME` is set, that wins instead.

It also writes the authorship rule into `~/.claude/CLAUDE.md`, inside a
delimited block:

```text
<!-- BEGIN openspec-casadei: authorship -->
...
<!-- END openspec-casadei: authorship -->
```

Re-running only rewrites that block, so anything else in the file is kept. If
the file doesn't exist it's created; if it exists without the block, the block
is appended. Pass `--no-claude-md` (or `-NoClaudeMd`) to skip this entirely.

**Why it lives there and not only in the schema:** the schema's `apply`
instruction is only in context during an `/opsx:apply` run. A plain
"commit this" would never see it. The rule is in both places on purpose —
see [Where each standard lives](#where-each-standard-lives).

### Option B — per-project (required for shared repos)

Copies the schema into the project and commits it alongside the code.

```powershell
# Windows
.\tools\install.ps1 -Project C:\path\to\your-project
```

```bash
# macOS / Linux
./tools/install.sh --project /path/to/your-project
```

To also commit the authorship rule with the repo, add `--claude` (or `-Claude`):

```powershell
# Windows
.\tools\install.ps1 -Project C:\path\to\your-project -Claude
```

```bash
# macOS / Linux
./tools/install.sh --project /path/to/your-project --claude
```

That writes the same delimited block as `--user` into `<project>/CLAUDE.md`
instead of `~/.claude/CLAUDE.md`. It's created if missing, appended if the file
has no block yet, and only the block is rewritten on re-runs. Because
Claude Code loads the project `CLAUDE.md` in every session, the rule then
applies to every session in that repo for **everyone** who clones it, not just to
`/opsx:apply` runs and not just on my machine. `--claude` is rejected with
`--user`, which already writes `~/.claude/CLAUDE.md`.

#### Secret protection

Keeping secrets out of git works at three levels. The first always applies; the
other two are opt-in per project:

| Level | How | What you get |
|---|---|---|
| default | nothing to pass | The schema's rules: no real secrets or personal data in proposals, designs, tasks, or issue bodies; new secrets named (never valued) in Impact and design, with `.env.example` and store tasks; before every commit, read `git diff --staged`, stage by name, keep secret files gitignored; never bypass or allowlist a scanner finding unasked; a committed secret means stop and rotate |
| `medium` | `--secrets medium` | The default, plus tools that **enforce** it: a delimited block of secret ignore rules in `.gitignore`, a [gitleaks](https://github.com/gitleaks/gitleaks) pre-commit hook in `.pre-commit-config.yaml`, and `.github/workflows/secret-scan.yml`, which scans the whole history on every push and PR |
| `high` | `--secrets high` | `medium`, plus `openspec/secrets-policy.md`: runtime secret storage (a secret manager instead of long-lived plaintext `.env`, OIDC instead of stored cloud keys in CI, GitHub Environments for production, rotation periods) and a leak runbook. The schema tells the agent to follow it and to ask while its "Where secrets live" table still says `TBD` |

```powershell
# Windows
.\tools\install.ps1 -Project C:\path\to\your-project -Secrets high
```

```bash
# macOS / Linux
./tools/install.sh --project /path/to/your-project --secrets high
```

What each file does on a re-run:

| File | First run | Re-run |
|---|---|---|
| `.gitignore` | Block created or appended; your rules are kept | Only the block is rewritten |
| `.pre-commit-config.yaml` | Created | Left alone. An existing file without gitleaks is **not** edited; you get a warning and the entry to add |
| `.github/workflows/secret-scan.yml` | Created | Left alone if it differs, with a warning |
| `openspec/secrets-policy.md` (`high`) | Created | **Never overwritten**, since you're meant to fill it in |

If the project is a git repo, the installer also lists committed files that now
match the ignore rules (a tracked `.env`, say). Ignoring a file doesn't untrack
it, and the secret is already in history, so rotate it before
`git rm --cached`.

Two steps the installer can't do for you, and prints at the end:

1. `pre-commit install` in every clone. The hook does nothing until then; the
   CI scan is the backstop for a clone that skipped it.
2. Turning on GitHub **secret scanning and push protection** (Settings → Code
   security). It needs a repo admin, and private repos need GitHub Advanced
   Security.

The workflow downloads gitleaks from its release and checks a pinned SHA-256,
rather than using `gitleaks-action`, which needs a paid license for
organization-owned repos. To bump the version, change `rev:` in
`tools/secrets/pre-commit-config.yaml` and both `GITLEAKS_*` values in
`tools/secrets/secret-scan.yml`, taking the hash from the release's
`checksums.txt`.

Lands in `<project>/openspec/schemas/casadei/`, **and selects it** in the
project's `openspec/config.yaml`. What it reports depends on what it finds:

| `config.yaml` says | What happens |
|---|---|
| `schema: spec-driven` | Rewritten to `casadei`, and it says so |
| `schema: casadei` | Left alone — "already selects" |
| `schema: something-else` | **Left alone**, with a warning. It won't silently retarget a workflow you chose deliberately |
| no `schema:` key | One is added as the first line |
| no `config.yaml` at all | Schema installs, plus a warning that it is **not selected**. Run `openspec init`, then re-run |

Only a top-level `schema:` line is touched; the rest of the file is byte-identical.

**Use this whenever anyone else works in the repo.** A machine-wide install is
invisible to your teammates — if the project's `config.yaml` says
`schema: casadei` and they don't have it, their CLI errors out.

> **Windows execution policy:** if PowerShell refuses to run the script, either
> run `Set-ExecutionPolicy -Scope Process Bypass` first, or invoke it directly:
> `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -User`

## Step 4 — Set up a project

The command is identical for a brand-new project and a 10-year-old codebase.
What differs is what you do *after*.

### 4a — A new project

```bash
mkdir my-project && cd my-project
git init
openspec init
```

`openspec init` prompts for your AI tool. To skip the prompt:

```bash
openspec init --tools claude
```

It creates:

```text
openspec/
├── config.yaml              # schema: spec-driven
├── specs/                   # capability specs accumulate here
└── changes/archive/         # completed changes land here
.claude/
├── commands/opsx/           # /opsx:propose, /opsx:apply, ...
└── skills/                  # agent skill instructions
```

Now point it at my schema. **Order matters here:** run `openspec init` first so
`config.yaml` exists, *then* the installer — it selects the schema for you:

```powershell
# Windows, from the fork's repo root
.\tools\install.ps1 -Project C:\path\to\my-project
```

```bash
# macOS / Linux, from the fork's repo root
./tools/install.sh --project /path/to/my-project
```

It prints `Set 'schema: casadei' in openspec/config.yaml (was 'spec-driven')`.
Nothing left to edit.

<details>
<summary>If you already installed before running <code>openspec init</code></summary>

The installer warns that the schema is installed but **not selected**, because
there was no `config.yaml` to write to. Just re-run it after `init`, or set the
line yourself:

```powershell
# Windows
(Get-Content openspec\config.yaml) -replace '^schema: spec-driven','schema: casadei' | Set-Content openspec\config.yaml
```

```bash
# macOS / Linux
sed -i.bak 's/^schema: spec-driven/schema: casadei/' openspec/config.yaml && rm openspec/config.yaml.bak
```

</details>

### 4b — An existing / legacy project

Exactly the same, run from the project root:

```bash
cd /path/to/legacy-project
openspec init
# then, from the fork's repo root:
./tools/install.sh --project /path/to/legacy-project
```

**You do not have to spec the existing codebase.** OpenSpec is delta-first:
a change describes only what's *changing* relative to today's behavior. Your
`openspec/specs/` starts empty and fills in only for the parts you actually
touch. Eighty thousand lines of untouched legacy code stay untouched and
unspecified, and that is the intended state — not technical debt.

So the first real change on a legacy repo looks like:

```text
/opsx:explore     # optional — have the AI read the area you're about to touch
/opsx:propose     # a small, real change you actually need
/opsx:apply
/opsx:archive
```

After archiving, `openspec/specs/` describes precisely the slice that change
touched. Repeat, and coverage grows where it earns its keep.

For a guided walkthrough on a brownfield repo, the `onboard` workflow exists —
it isn't in the default profile, so add it with `openspec config profile`.

> **Don't pass `--language pt-BR`.** That flag makes OpenSpec write *spec
> artifacts* in Portuguese. This schema deliberately keeps specs in English
> (the validator's `SHALL`/`MUST` check is English-only) while requiring `/docs/`
> deliverables in PT-BR — that split is already handled in the instructions.

## Step 5 — Verify

From inside the project:

```bash
openspec schema which casadei
```

Expected — `Source: project` for a per-project install, `user` for machine-wide:

```text
Schema: casadei
Source: project
Path: /path/to/your-project/openspec/schemas/casadei
```

And to confirm both schemas coexist:

```bash
openspec schema which --all
```

```text
Project schemas:
  casadei

Package schemas:
  spec-driven
```

If `casadei` doesn't appear, the schema isn't where the CLI looks — re-run
Step 3, and check the destination table above.

---

# What's different from stock OpenSpec

Measured against `schemas/spec-driven/`, which this repo keeps pristine on
purpose: **+406 lines, −17, across 5 files.** Almost entirely additive.

Reproduce it yourself at any time:

```bash
git diff --no-index schemas/spec-driven schemas/casadei
```

## At a glance

| Area | Stock OpenSpec | This fork |
|---|---|---|
| Scenario format | `**WHEN**` / `**THEN**` | Adds a required `**AS A**` actor line |
| Scenario coverage | Happy path is enough | Failure/edge case expected too |
| Breaking changes | Mark with `**BREAKING**` | Must also state the deprecation path |
| Dependencies | No position | Must be named in Impact and user-approved |
| `design.md` template | Context, Goals, Decisions, Risks | Adds **Migration Plan**, **Security & Observability**, **Open Questions** |
| DB migrations | No position | Expand-and-contract, plus a tested `down` migration |
| Tests | Each task group lands its own tests and docs | Also: a mandatory test per feature or fix, mapped to its BDD scenario; coverage threshold checked in Quality Gates |
| `/docs/` | No position | Updated in the same commit, PT-BR, table-dense |
| Git/commits | No position | Conventional Commits, branch naming, no direct-to-`main` |
| Authorship | No position | Human author only; no AI co-author trailers |
| Docblocks | No position | Required on every exported symbol, with `@param`/`@returns`/`@throws` |
| Quality gates | No position | Build, lint, static analysis, strict types before review |

## The four things actually *changed* (not added)

Everything else is appended. These are the only upstream lines rewritten:

1. **Schema identity** — `name` and `description`.
2. **The scenario-format line** in the `specs` instruction, expanded from
   "`#### Scenario: <name>` with WHEN/THEN format" into the full BDD block with
   the actor line.
3. **The worked example** in the `specs` instruction, rewritten to use the new
   format and to show a second, non-happy-path scenario.
4. **The tasks example and template.** Upstream's example ends with a single
   docs task; mine replaces it with a scenario-mapped test and a `/docs/` task,
   and closes with a Quality Gates group. The template keeps upstream's
   "tests and docs inside each group" shape, with slots for both in every
   group, a Migration group, and Quality Gates.

## What each artifact gained

Each instruction ends with an `## Engineering standards` block, so mine is
visually separable from upstream's.

**`proposal`** — ask instead of inventing when requirements are underspecified;
semver and a mandatory deprecation path for every `**BREAKING**`; new
dependencies named in Impact and approved before design; Impact must call out
personal data, DB schema, queues, public API surface, and new secrets (by name,
never by value); no real secrets or personal data in any artifact.

**`specs`** — the BDD format above; idempotency contracts for state-mutating
endpoints and workers; retry ceilings and DLQ routing for consumers; LGPD data
minimization with a named retention window; no PII or credentials in logs,
metrics, or telemetry; correlation IDs and OpenTelemetry propagation. Plus an
explicit warning that the validator checks the requirement *body* for
`SHALL`/`MUST`.

**`design`** — YAGNI, with any abstraction required to name the concrete second
use case justifying it; grounding in existing project conventions; dependency
rationale; expand-and-contract migrations with a functional `down` for every
step; feature flags with a stated removal criterion; where secrets load from
(each new secret and its store per environment) and how PII is redacted.

**`tasks`** — test and `/docs/` tasks live inside the group whose work they
cover, so each group is built, tested and documented before the next builds on
it (upstream's rule, made concrete); at least one automated test per feature or
fix, mapped onto the spec's scenarios; per-step migration tasks plus rollback
verification; `/docs/` updated in the same commit; `.env.example`, gitignore
and secret-store tasks for every new secret; a closing quality-gate group
naming the project's real commands, including the coverage threshold and the
secret scanner when one is configured.

**`apply`** — human authorship with no AI trailers; never commit to `main`
unasked; JIRA or GitHub Issues/Projects (ask if it's not already obvious) —
JIRA branches as `<type>/<JIRA-KEY>-<kebab-case-title>`, GitHub has the agent
create a story issue plus one sub-issue per task group via `gh issue create
--parent`, add them to the project board, branch as
`<type>/<issue-number>-<kebab-case-title>`, and move each issue's board
Status as tasks start and finish; Conventional Commits and linear history;
minimal diff; idiomatic code matching existing patterns; standardized
docblocks; no hardcoded secrets, a `git diff --staged` check before every
commit, no `git add -A`, no bypassing the secret scanner, and stop-and-rotate
for a committed secret; `/docs/` in PT-BR; ask when ambiguous;
verify build, lint, types before declaring the branch ready.

## What's deliberately unchanged

The **artifact graph** is stock: `proposal` → (`specs`, `design`) → `tasks`,
with `tasks` requiring both. No artifact was added, removed, or reordered, and
no `requires:` edge was rewired. Everything upstream says about delta specs,
`## Purpose`, MODIFIED workflow, capability paths, and `skip_specs` is intact.

## Constraints worth knowing

**Requirement text must contain literal uppercase `SHALL` or `MUST`.** The
validator tests `/\b(SHALL|MUST)\b/` against the requirement *body* — a keyword
appearing only in the header does not count. Normally a warning; under
`openspec validate --strict` it's fatal. Both behaviors verified.

**Scenario bodies are free text.** `SCENARIO_HEADER` is just `/^####\s+/`;
OpenSpec never parses `WHEN`/`THEN`. That's why adding `**AS A**` is safe —
confirmed passing under both `validate` and `validate --strict`. It also means
the keywords could be translated to Portuguese later without breaking anything.

---

# How the override works

OpenSpec resolves a schema name through three tiers, first match wins:

| Priority | Location | Installed by |
|---|---|---|
| 1 | `<project>/openspec/schemas/<name>/` | `install --project` |
| 2 | `$XDG_DATA_HOME/openspec/schemas/<name>/`<br>Linux/macOS: `~/.local/share/openspec/schemas/`<br>Windows: `%LOCALAPPDATA%\openspec\schemas\` | `install --user` |
| 3 | `<npm package>/schemas/<name>/` | the CLI itself |

Because the schema is named `casadei` rather than shadowing `spec-driven`, both
stay available — handy for diffing my workflow against stock behavior.

This is a supported extension point, not a hack: OpenSpec ships an
`openspec schema fork` command for exactly this, and documents the resolution
order in [`docs/customization.md`](docs/customization.md).

> Upstream marks the `openspec schema *` commands experimental. The resolution
> tiers are stable; the command names could move between releases.

---

# Where each standard lives

The standards live in the schema itself rather than a separate rules document,
so there's essentially one place to edit. This maps each one to the text you'd
change.

| Standard | Lives in |
|---|---|
| **§1 Identity & git governance** | `apply.instruction` — **plus** the authorship rule in `~/.claude/CLAUDE.md` and/or `<project>/CLAUDE.md` (see below) |
| **§2 Anti-bloat & code standards** | `apply.instruction`, with design-time judgment in `design.instruction` and dependency approval in `proposal.instruction` |
| **§3 Resilience & migrations** | `specs.instruction` (contract) and `design.instruction` (mechanism), tasks in `tasks.instruction` |
| **§4 Documentation (`/docs/`, PT-BR)** | `tasks.instruction` and `apply.instruction` |
| **§5 Testing & BDD scenarios** | BDD format in `specs.instruction`; test and coverage tasks in `tasks.instruction` |
| **§6 Security, LGPD & observability** | `specs.instruction` (contract) and `design.instruction` (technical choice); keeping secrets out of git in every instruction, most of it in `apply.instruction`. Enforcement comes from `install --project --secrets` ([Secret protection](#secret-protection)), plus `openspec/secrets-policy.md` at `high` |
| **§7 AI guardrails** | `proposal.instruction` and `apply.instruction` |

## The one deliberate duplication

The **authorship rule** is the single exception: it lives in
`apply.instruction` *and* in a `CLAUDE.md` — `~/.claude/CLAUDE.md` via `--user`,
`<project>/CLAUDE.md` via `--project --claude`, or both. No single location
covers the whole surface on its own:

| Location | Covers | Misses |
|---|---|---|
| `apply.instruction` | Any `/opsx:apply` run in a project carrying the schema — including a teammate's checkout | Everything else. A plain "commit this" never loads it |
| `~/.claude/CLAUDE.md` | Every session on **my** machine, whatever the project or prompt | Anyone else's machine — it's personal config, not repo config |
| `<project>/CLAUDE.md` | Every session in **that repo**, on any machine that clones it | Projects installed without `--claude` |

Since this is the one rule I least want missed, it's in more than one place.

The CLAUDE.md copy is **not** embedded in the installers — both read
[`tools/authorship.md`](tools/authorship.md), so the bash and PowerShell paths
cannot drift (verified: both produce a byte-identical block). That leaves two
places to keep in sync when the rule changes:

| File | How it propagates |
|---|---|
| `schemas/casadei/schema.yaml` → `apply.instruction` | Re-run `install --project` / `--user` to push the schema out |
| `tools/authorship.md` | Re-run `install --user` and/or `install --project <path> --claude` to rewrite the CLAUDE.md block |

The schema block carries an inline note saying so, so whoever edits one is told
about the other.

---

# Changing how it works

Everything lives in [`schemas/casadei/`](schemas/casadei/):

```text
schemas/casadei/
├── schema.yaml          # artifact graph + the instructions the agent follows
└── templates/
    ├── proposal.md      # Why / What Changes / Capabilities / Impact
    ├── spec.md          # Purpose / ADDED Requirements / BDD scenarios
    ├── design.md        # Context / Goals / Decisions / Security / Migration / Risks
    └── tasks.md         # groups with their own tests + docs, Migration, Quality Gates
```

Two knobs, and the difference matters:

- **`templates/*.md`** — the *skeleton* written to disk when an artifact is
  created. Headings, placeholder comments, required structure.
- **`schema.yaml` → `instruction:`** — the *prose the agent reads* while filling
  that skeleton in. How it reasons, what it researches, what it refuses to do.

The `artifacts:` list is also fair game — drop an artifact, add one, or rewire
`requires:` to change the order.

After any edit:

```bash
openspec schema validate casadei
```

Then reinstall (Step 3) so projects pick up the change — the installer copies
files, it doesn't symlink.

### Tests and CI

The installers have their own test suites, which run against throwaway
directories and never touch your real `~/.claude/CLAUDE.md`:

```bash
./tools/tests/install.test.sh                                 # install.sh
```

```powershell
.\tools\tests\install.tests.ps1 -Shell pwsh                   # install.ps1 under PowerShell 7
.\tools\tests\install.tests.ps1 -Shell powershell             # ...and Windows PowerShell 5.1
```

The sync scripts have them too, built on throwaway local repos:

```bash
./tools/tests/sync-upstream.test.sh                           # sync-upstream.sh
```

```powershell
.\tools\tests\sync-upstream.tests.ps1 -Shell pwsh            # sync-upstream.ps1
```

[`.github/workflows/installers.yml`](.github/workflows/installers.yml) runs on
every pull request, every push to `main`, and weekly:

| Job | Checks |
|---|---|
| ShellCheck | Every `.sh` in `tools/` |
| bash scripts | `install.sh` and `sync-upstream.sh` tests, Linux and macOS |
| PowerShell scripts | `install.ps1` and `sync-upstream.ps1` tests, Windows, PowerShell 7 and 5.1 |
| Schema validates (npm CLI) | `openspec schema validate casadei` with the latest release from npm, in a fresh `openspec init` project |
| Schema validates (upstream CLI) | The same, with the CLI built from the newest upstream commit merged into this fork |

### Per-project tweaks that don't need a schema change

For one-off rules, `openspec/config.yaml` in the project injects extra context
without touching the schema:

```yaml
schema: casadei

context: |
  Tech stack, domain vocabulary, and conventions for this specific project.

rules:
  specs:
    - Requirements must state observable behavior, not implementation.
  tasks:
    - Include a rollback task for any migration.

operations:
  apply:
    guidance:
      - Keep test summaries concise.
```

Schema = how I always work. `config.yaml` = what's true of one repo.

---

# Pulling in upstream changes

This fork keeps full upstream history, so upstream merges in like any branch.
It happens **automatically every Monday**, and you can also run it by hand.

## Automatically

[`.github/workflows/upstream-sync.yml`](.github/workflows/upstream-sync.yml)
runs weekly (Mondays 06:17 UTC) and on demand from the Actions tab:

1. Runs `tools/sync-upstream.sh` on a `chore/sync-upstream-<sha>` branch
2. Runs the test suites, then opens a PR
3. Waits for [CI](#tests-and-ci), which also validates the schema against the
   CLI **built from the exact upstream commit being merged**
4. Merges the PR (always a merge commit: squashing would drop upstream's history
   and break the next sync) and deletes the branch

| What happens | Result |
|---|---|
| Already up to date | Nothing |
| A sync PR for the same upstream commit is already open | Left alone |
| An older sync PR is open | Closed as superseded, then a new one opens |
| Conflict in a tracked path | No PR. The run fails and, if issues are enabled, opens or updates an issue with the conflicting files |
| CI fails | PR left open with a comment. The run fails |
| Upstream changed `schemas/spec-driven/` | Merged normally; the PR calls it out, because porting into `schemas/casadei/` is still manual |

A failed run is the alert: GitHub emails you when a scheduled workflow fails.
Merge commits are authored as the author of `main`'s tip, never as a bot.

To test it without pushing anything, run it from the Actions tab with
**dry run** checked. It merges and runs the tests on the runner, then stops.

### One-time setup: the `SYNC_TOKEN` secret

The workflow needs a token of yours, because `GITHUB_TOKEN` can't do the job:
PRs opened with it don't trigger CI, and it can't push commits that touch
`.github/workflows/` (upstream's history does).

1. Create a **fine-grained personal access token** at
   <https://github.com/settings/personal-access-tokens/new>
   - Repository access: **Only select repositories** → `openspec-casadei`
   - Repository permissions, all **Read and write**: **Contents**,
     **Pull requests**, **Issues**, **Workflows**
2. Save it as a repository secret named `SYNC_TOKEN`:

   ```bash
   gh secret set SYNC_TOKEN --repo vcasadei/openspec-casadei
   ```

When the token expires, the next run fails at "Check for SYNC_TOKEN" or at
checkout; create a new one and set the secret again.

## By hand

```bash
./tools/sync-upstream.sh          # or: tools\sync-upstream.ps1
```

It fetches and merges `upstream/main`, treating each path by what it is:

| Path | On merge |
|---|---|
| **Tracked** — `schemas/`, `skills/`, `docs/`, `LICENSE`, `.gitattributes`, `.gitignore` | Merged normally. A conflict here is real, and the script stops for you to resolve it |
| **Fork-owned** — `README.md`, `NOTICE.md`, `tools/`, our workflows | Kept exactly as they were, even when upstream edits a file of the same name (upstream has its own `README.md`) |
| **Upstream-only** — the CLI source, tests, website, everything else | Kept out, whether upstream modifies or re-adds them |

Put differently: outside the tracked paths, a sync never changes the fork's
tree. To start following a new upstream path, add it to `TRACKED_PREFIXES` in
both `sync-upstream.sh` and `sync-upstream.ps1`.

What it leaves for you is the part that needs judgment: changes to
`schemas/spec-driven/`. See what upstream improved and whether it's worth porting:

```bash
diff -ru schemas/spec-driven/ schemas/casadei/
```

Keeping `schemas/spec-driven/` untouched is what makes that diff meaningful — it
is the control my changes are measured against.

---

# Reference

| Document | What it covers |
|---|---|
| [docs/customization.md](docs/customization.md) | Schema structure, resolution order, worked examples |
| [docs/existing-projects.md](docs/existing-projects.md) | Adopting OpenSpec on a legacy codebase |
| [docs/writing-specs.md](docs/writing-specs.md) | Requirement and scenario conventions |
| [docs/concepts.md](docs/concepts.md) | Changes, specs, capabilities, deltas |
| [docs/cli.md](docs/cli.md) | Full command reference |
| [skills/](skills/) | Upstream agent skill instructions (read-only reference) |
| [NOTICE.md](NOTICE.md) | Fork provenance, license, what was removed |

MIT, inherited from upstream. See [NOTICE.md](NOTICE.md).
