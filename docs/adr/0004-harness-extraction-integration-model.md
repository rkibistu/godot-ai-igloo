# Harness extraction: the multi-repo integration model

---
Status: accepted
---

Phases 1–5 built the system as a single repo that *is* both the harness and the game it
works on (`rkibistu/godot-ai-igloo`, with the Godot project under `game/`). To use it on
**any** Godot project, we extract a **global, install-once harness** that is *pointed at*
arbitrary game repos. This ADR records the integration model decided in the 2026-06-25
grilling session; Phase 7 in `plan_implementation.md` is its build plan.

The driving requirement: the harness is iterated on **a lot**, so updating it across many
games must be cheap — ideally "update once, every game benefits." That biases every
decision toward *one global thing to update* and *per-game state that the harness never
auto-touches*.

## The model in one picture

```
~/.igloo/
  harness/                      ← the harness clone (git pull to update)
    bin/igloo                   ← thin bash dispatcher (symlinked onto PATH)
    scripts/  skills/ (presets)  docker/  game/ (fixture + self-test + addon source)
  .env                          ← GLOBAL secrets (bot token, Claude token) — set once

<your-game-repo>/               ← any Godot C# project, its own GitHub repo
  .igloo.yml                    ← per-game config (committed, self-documenting)
  .igloo/skills/                ← per-game skills, seeded from presets then hand-tuned (committed)
  game project (project.godot, gdUnit4, test/scenes/issue_<n>.tscn, addons/godot_ai gitignored)
```

`igloo run <issue#>` / `igloo review <issue#>` are run **from inside the game repo**; the
dispatcher resolves `~/.igloo/harness` as `HARNESS_HOME`, sources `~/.igloo/.env`, walks up
from cwd to find `.igloo.yml`, and dispatches. `agent-run` needs only the repo **slug** +
secrets (the container clones the game fresh from GitHub — the amnesiac model of ADR-0001 is
unchanged); only `review-setup` touches a local checkout.

## Decisions

1. **Global harness, per-game config (not vendored).** One install pointed at game repos;
   the alternative (copy/submodule the harness into each game) fails the "update once"
   requirement. Update = `git pull` + conditional image rebuild, in one place.

2. **Mechanism is global; policy is per-game.** The **spine** (classifier, routing, PR
   plumbing, container lifecycle, secret injection) and the **done-gate** are global harness
   mechanism — never hand-edited per project. **Skills** are per-game freeform prose
   (`.igloo/skills/`), *meant* to diverge per project. The gate stays global because its
   verdict is trustworthy precisely *because* it is uniform and not vibe-tuned (ADR-0001:
   "the script decides; never trust the LLM for a transition"). Per-project flex on the gate
   comes from **`.igloo.yml` declarations** + optional **extra-clause hooks** (paths to
   pass/fail scripts in the game repo, each must exit 0), never from editing gate logic.

3. **The mechanical contract has a single source of truth: `.igloo.yml`.** The issue-scene
   path/script/class, `test_command`, `game_subdir`, and `godot_version` are written **only**
   in `.igloo.yml` and consumed by **both** (a) the global gate (to verify/boot/record) and
   (b) the harness prompt-builder (which injects a generated "contract block" into the agent's
   user prompt so the agent is told exactly what the gate will check). Because both derive
   from the same file, agent output and gate check **cannot drift**. **Skills must not restate
   the contract** — the path is not their job; they carry quality guidance only. If a skill
   contradicts the contract, the gate catches it as a hard failure (never silent).

4. **Config split.** *Global secrets* live in `~/.igloo/.env`: `BOT_GH_TOKEN`,
   `CLAUDE_CODE_OAUTH_TOKEN` (+ optional host `GODOT_BIN`/`GODOT_ZIP` for review). *Everything
   describing a game* lives in committed `.igloo.yml`, which travels with the clone so the
   container gets it for free. **No secrets in `.igloo.yml`.** Repo slug is **auto-detected**
   from `git remote origin` (override allowed).

5. **One global bot.** A single bot account reused across all games; its token is a global
   secret; each game just **grants it push access**. The bot **login is derived at runtime**
   (`gh api user --jq .login`) so it cannot drift from the token — replacing the hardcoded
   `justfortest1234` in `bot_init.sh` and the classifier. `.igloo.yml` says nothing about the
   bot.

6. **`igloo init` scaffolds igloo's own files; validates the rest.** It writes a
   self-documenting `.igloo.yml`, seeds `.igloo/skills/` from presets, appends `.gitignore`
   entries, and provisions the `godot_ai` addon into the local checkout. For invasive,
   build-touching pieces (gdUnit4 wiring) it **validates-and-instructs** (prints a checklist)
   rather than mutating `.csproj`/`project.godot`. init never breaks a project that already
   builds.

7. **`igloo update` is harness-only and never mutates project files.** It `git pull`s the
   harness and rebuilds the image if its inputs changed. It **reads** a project's `.igloo.yml`
   to **instruct** on config drift (see the future-implementation rules below) but writes
   nothing. **Skills are never auto-migrated** — refreshing a per-game skill is the human's
   call via explicit, opt-in `igloo skills diff` / `igloo skills update <name>`.

8. **`project.godot` is committed source; the `godot_ai` lines are committed canonically; no
   scrub.** `project.godot` carries real game source (input map, real autoloads, main scene)
   that issues legitimately change and that tests reference by name — under the amnesiac
   clone, un-committed = nonexistent, so it must be committed. The two `godot_ai` lines
   (`[editor_plugins]` enable + the `_mcp_game_helper` `[autoload]`) are committed **canonically
   on purpose**: that makes the container's runtime plugin-enable a **no-op**, so nothing leaks
   into the agent's commit and **no scrub is needed**. (We rejected *not* committing them: the
   plugin self-registers the autoload via `add_autoload_singleton` on every editor open, so
   omitting the lines doesn't remove the mutation — it just relocates and multiplies the scrub
   to the container *and* every local editor session.) Committing a manifest reference to a
   gitignored, provisioned dependency is the normal pattern (`package.json`→`node_modules`,
   `.csproj`→NuGet, and this repo's own gdUnit4), not a smell.

9. **The `godot_ai` addon is provisioned everywhere from one vendored source.** The addon is
   the editor-side half of the MCP bridge (111 `.gd` files, ~1.8 MB); its other half is the
   `uvx` MCP server in the image — the two are a **version-matched set**. Because it is
   gitignored in *consumer* games (kept out of PRs/history; avoids per-game version drift), it
   is absent from every fresh clone / worktree / new project, so it must be **copied in** at
   runtime from a known home. That home is the **harness fixture's own `game/addons/godot_ai/`,
   which is committed (vendored) in the harness** — so `git pull` carries addon updates and a
   fresh harness clone has it. Three provisioning sites copy from it: `igloo run` (mount → copy
   into the clone), `igloo review` (copy into the worktree), `igloo init` (copy into the local
   checkout). **Asymmetry:** the harness fixture **commits** the addon (it is the source);
   consumer games **gitignore** it (they are fed from the source). Updating the addon = update
   it in the fixture game where the harness's self-tests exercise it, commit, `igloo update`
   propagates — and bump the `uvx` server pin if it moved.

10. **Image: local build, no registry, tagged by `godot_version`.** Scripts/skills are not in
    the image (cloned/mounted), so the image changes only when the *toolchain* changes (rare).
    `igloo update` rebuilds only when image inputs changed; `igloo build` is explicit. The
    image is tagged `godot-ai-igloo:<godot_version>` (from the Dockerfile's existing
    `ARG GODOT_VERSION`); `.igloo.yml.godot_version` selects the tag. Multi-version is
    therefore **additive** (bump Godot → build a new tag; old games keep their tag), and a
    registry stays a clean future add-on.

11. **Install = clone + symlinked dispatcher under `~/.igloo/`.** A one-line installer clones
    the harness, symlinks `~/.local/bin/igloo`, and does a first `igloo build`. The dispatcher
    routes: `init`, `run`, `review`, `update`, `build`, `check`, `addon install`,
    `skills diff|update`. A package manager (npm/pipx/brew) was rejected — every harness change
    would need a publish, which fights "update a lot."

12. **The bundled `game/` is demoted to a fixture.** It stays in the harness as the reference
    implementation of the project contract, the harness's self-test target, and the vendored
    addon source. Real games are separate `igloo init`'d repos.

## Instructions for future implementations (load-bearing — do not violate)

These are the invariants any later change must preserve. Most concern **how to correctly add
or change a `.igloo.yml` field**, because that file is the contract surface multiple
components share.

**Adding or changing a `.igloo.yml` field:**

- **Document it inline.** The scaffolded template is the *only* documentation a user gets —
  every field carries a `#` comment with purpose, allowed values, and a sane default.
  "Self-documenting template" is an acceptance criterion of `init`, not a nicety.
- **Tag it in the harness config schema.** The harness ships a versioned schema (the canonical
  key list with required/optional, default, and *added-in-version*). `igloo update` and
  `igloo check` diff a project's `.igloo.yml` against it to **instruct** on drift. A new field
  with no schema entry is invisible to that machinery — always add the schema entry.
- **Be backward-compatible.** A new field must have a **default** so an older `.igloo.yml`
  without it still runs. Never make `update` fail or auto-write because a field is missing —
  it **instructs**, the human edits.
- **If the field is part of the mechanical contract** (anything the gate verifies *and* the
  agent must produce — paths, class names, the test command), it must be read from `.igloo.yml`
  by **both the gate and the prompt-builder**, and it must **never be restated in a skill**.
  One source, two consumers. Adding such a field means wiring both readers, not one.
- **Never put a secret in `.igloo.yml`.** Secrets are global, in `~/.igloo/.env`. `.igloo.yml`
  is committed; treat it as public.
- **Prefer auto-detection over a required field** where a value is already discoverable (repo
  slug from the git remote, `game_subdir` from where `project.godot` lives). Blank-means-detect
  beats a mandatory field a user can typo.

**System invariants (carry from ADR-0001, extended here):**

- **igloo writes a project's files only at `init` and at explicit user-invoked commands**
  (`addon install`, `skills update <name>`). `update` is **read-only** with respect to any game
  repo. Project state — skills, `.igloo.yml` — is never silently migrated.
- **The gate stays global and parameterized.** Per-project variation is `.igloo.yml`
  declarations + extra-clause hooks. Never ship a per-project, hand-editable gate; it would
  destroy the "Ready PR means the same thing everywhere" guarantee.
- **Skills carry quality guidance only and stay contract-free.** They must not encode the
  mechanical paths/commands the gate checks; those are injected from `.igloo.yml`.
- **The addon is committed only in the harness fixture; gitignored in consumer games.** Never
  commit the addon (or any vendored third-party addon) into a user's game repo.
- **The addon, the `uvx` MCP server, and the Godot version are one version-matched set.** Bump
  them together; the fixture's self-tests are the gate on an addon update before it reaches a
  real game.

## Consequences / deferred

- **Migration:** the current self-targeting (proofs operate on `rkibistu/godot-ai-igloo`) and
  the hardcoded `REPO`/bot/`game/`/scene-path constants move into the dispatcher + `.igloo.yml`
  + the schema. The addon's `game/.gitignore` entry flips to tracked **in the harness only**.
- **Multi-version concurrency** (running several Godot versions at once) is enabled structurally
  by version-tagged images but not exercised until a second version is actually used.
- **Registry distribution, multi-machine, and CI** are deliberately deferred — local build keeps
  the solo-dev loop self-contained.
- **The `gdUnit4` addon** parallels `godot_ai` (also gitignored, also a provisioned dependency).
  Whether the harness fixture vendors it the same way is left to Phase 7 implementation; the
  contract treats gdUnit4 as the project's responsibility (validate-and-instruct in `init`).
