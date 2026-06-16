# Godot + Claude Code Dev Environment — Setup Handoff

Status: planning complete, environment not yet built. This doc captures the decisions made and the reasoning behind them, so setup can resume without re-deriving context.

## Goal

Run an AI coding agent (Claude Code) against a Godot project with full permissions to act autonomously on tasks, while keeping the host machine safe from anything the agent or its tooling does. Work happens across two machines: a Linux laptop (work) and a Windows laptop (home).

## Stack decisions

| Decision | Choice | Why |
|---|---|---|
| Engine | Godot 4.x | Lighter weight than Unity; open source, no licensing terms to track |
| Scripting language | C# | Existing C# experience; want real classes/interfaces/OOP patterns, which GDScript supports more weakly (dynamically typed, looser OOP idioms) |
| MCP server | [`godot-ai`](https://github.com/hi-godot/godot-ai) (hi-godot) | Backed by Aura/Coplay — the team behind `unity-mcp` (10k+ stars, actively maintained, official-adjacent credibility). Not a lone anonymous maintainer; verified directly in the `unity-mcp` README, which sponsors and points to `godot-ai` as a sibling project. |
| Agent | Claude Code | — |
| Isolation | Docker container, agent side only | See "Isolation model" below |

### Known gap to watch

`godot-ai`'s current toolset (as of the version reviewed) is GDScript/Python in its own stack, with no C#-specific tooling (no `.cs` patching, no binding audit, GDScript-only test runner). It will handle scene/node/editor-state operations fine regardless of script language, but won't have special insight into C# script content. Re-check the repo before building — this is an actively developed project and may have added C# support since this doc was written. If C#-aware tooling is still missing, consider running `godot-dotnet-mcp` alongside it as a secondary server for the scripting-specific work.

## Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│         HOST MACHINE          │         │      DOCKER CONTAINER          │
│                                │         │                                │
│  Godot Editor (native)         │ WebSocket│  godot-ai Python server       │
│   - GDScript/C# plugin         │◄─────────┤   (port 8000 HTTP / connects  │
│   - addons/godot_ai/           │  :9500   │    out to host :9500)         │
│   - your real project files    │         │                                │
│                                │         │  Claude Code                  │
│                                │  HTTP    │   - talks to MCP server       │
│                                │◄─────────┤     locally inside container  │
│                                │  :8000   │                                │
└─────────────────────────────┘         └──────────────────────────────┘
        bind-mount: ONLY the project directory, nothing wider on host
```

### Isolation model — what this protects against, and what it doesn't

Containerizing only the agent + MCP server (not the Godot editor) was a deliberate choice after working through the threat model:

- **The editor does not need to be containerized.** Claude Code's only path to the editor is through `godot-ai`'s defined MCP tools (HTTP → WebSocket → `EditorInterface`/`SceneTree` APIs). There is no side channel. Containing the editor process buys nothing, because the project files and the editor have to exist somewhere for work to happen, and the meaningful exposure (what MCP tool calls can do to the project) is identical whether the editor runs in a container or natively.
- **What containerizing the agent side *does* protect against:** a compromised or buggy dependency in the Python MCP server, or Claude Code's own shell/file tools doing something outside the intended scope (touching files outside the project, unexpected network calls, installing unwanted things). The container boundary limits blast radius for those failure modes specifically.
- **What containerizing does *not* protect against:** the agent doing damage *through legitimate MCP tool calls* — e.g., misunderstanding a task and deleting/rewriting nodes or files it had every permission to touch. This isn't a containment problem, it's a "full permissions means full permissions within the project" reality. Mitigate with git discipline, not Docker:
  - Commit before every agent session.
  - Treat agent work like an untrusted PR — review the diff, discard with `git checkout`/`git reset` if it's wrong, rather than trusting it to self-correct.
  - Don't run agent sessions directly on a branch you can't easily throw away.

### Bind mount discipline

Mount **only** the project directory into the container — nothing wider on the host filesystem. "Full permissions, isolated" means: full permissions *within* the project, isolated from everything outside it. If the mount is broader than the project folder, the isolation claim stops being true.

Output/result extraction from the container should be deliberate, not a live two-way sync: `git push` from inside the container to a remote, or an explicit copy-out step you control.

## Cross-platform notes (Linux work laptop / Windows home laptop)

- **Same container image/Compose file on both machines.** Only difference is where Godot's native editor binary lives (Linux binary vs Windows .exe).
- **WSL on Windows, if not running the agent in Docker directly on Windows:** native Godot editor stays on Windows; Claude Code + container tooling can run from WSL for shell/tooling consistency with the Linux laptop. Test `localhost` resolution between WSL2 and Windows-native early — may need the WSL2 VM's IP instead, depending on Windows/WSL version and network mode.
- **Docker networking specifics to verify per host:**
  - Docker Desktop on Windows: container reaches host via `host.docker.internal:9500`.
  - Docker on Linux: depends on network mode — `--network host` is simplest if isolation-from-network isn't a concern; otherwise use the bridge/host LAN IP.
- **Git line endings — set this up before the first commit:**
  - Add `.gitattributes` at project root: `* text=auto eol=lf` (or at minimum `*.gd text eol=lf`, `*.cs text eol=lf`).
  - `git config --global core.autocrlf input` on Linux.
  - `git config --global core.autocrlf true` on Windows.
- **`.gitignore` must exclude** `.godot/` (editor cache/state, regenerable, machine-specific) and check `export_presets.cfg` for any machine-specific absolute paths before committing it.
- **Avoid absolute filesystem paths** anywhere in project settings or custom scripts/build steps — Godot's own internal references use `res://`-relative paths by default; the risk is in custom tooling you add later (e.g., export presets with hardcoded SDK paths).
- **C# specifics:** requires the Mono/.NET-enabled build of Godot (not the standard GDScript-only build) plus the .NET SDK on whichever machine runs the editor natively. Create the project using Godot's C# template from the start, not retrofitted — avoids a class of `.csproj`/`.sln` scaffolding bugs.

## Open items / next steps

1. Re-check `godot-ai` repo for current C# tooling support before finalizing the MCP server choice.
2. Build and test the Dockerfile/Compose setup for the agent + MCP server container (Python + `uv` based, per `godot-ai`'s install instructions).
3. Validate the WebSocket connection from container → host editor plugin on both OSes.
4. Decide and document the actual output-extraction workflow (git remote push vs. manual copy-out) before running the first real agent session.
5. Set up `.gitattributes`/`.gitignore`/autocrlf config before first commit.
6. Confirm whether a secondary C#-aware MCP server (e.g. `godot-dotnet-mcp`) is still needed once `godot-ai`'s current C# support is checked.
