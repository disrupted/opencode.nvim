# Upstream Alignment Plan

Handoff document for implementation agents. Read fully before starting any phase.

## Goal

Make `pi.nvim` a thin layer on top of upstream `sudo-tee/opencode.nvim` so upstream changes arrive via a plain `git merge opencode/main` with few or no conflicts. Pi support is implemented as a **protocol adapter** (`protocols/pi/`) in the same seam upstream uses for Opencode `v1`/`v2`, not as a replaced backend plus a renamed module tree.

Secondary goal: shape the core patches so they can be proposed upstream (provider-agnostic backend: Opencode v1/v2 and Pi side by side).

## Why the current fork is expensive to maintain

- The fork renamed `lua/opencode` to `lua/pi` and replaced identifiers wholesale. Git sees nearly every file as rename plus edit; 113 files changed on both sides since the merge-base (`e708ba3`).
- The backend was replaced in place (`api_client`, `event_manager`, `session`, `renderer/events`). Upstream has since refactored exactly that seam (v2 protocol, `protocols/`, `services/`, renderer split, session tabs).
- Experiments in this repo (script `scripts/sync-upstream.sh`) showed that even "leaf" UI files are coupled: `output_window` requires upstream's `ui/keymap`, `scroll` requires `output_window.on_user_navigation`, `ui.lua` requires the session tab strip. Per-file syncing and cherry-picking do not scale.

## Target architecture

```
upstream core (unmodified where possible)
  ui/**, renderer/**, services/**, commands/**, context/**, state/**
          │  consumes normalized observation state
          ▼
  protocols/connection.lua     ← registry patch (P1): no hard-coded {v1, v2}
          │
  ┌───────┼───────────────┐
  v1/     v2/            pi/        ← new, owned by this fork
                          │
                 transport: stdio JSONL (`pi --mode rpc`)
```

Upstream already provides (verified on `opencode/main` @ `494e474`):

- `lua/opencode/protocols/{v1,v2}/` each with `connection`, `operations`, `observation`, `normalize`, `types`, plus `v1/server`.
- Shared lifecycle in `protocols/observation.lua` (adapter implements an `OpencodeObservationRuntime`), `protocols/submission.lua`, `protocols/reply.lua`, `protocols/entries.lua`.
- Observation resources: `session, children, messages, inbox, execution, permissions, questions, files`; per-resource sync state includes `unsupported`.
- Operations surface to implement: see `protocols/v1/operations.lua` (`list_sessions`, `create_session`, `get_session`, `list_messages`, `submit`, `submit_async`, `interrupt`, `rename_session`, `fork_session`, `summarize_session`, `revert_message`, `list_permissions`/`reply_permission`, `list_questions`/`reply_question`, `list_commands`, `find_files`, `list_providers`/`get_model_catalog`, `list_skills`, `subscribe_events`, ...). Unsupported operations should fail with an explicit error or return empty results; follow how v2 handles gaps.
- Server lifecycle in `server_job.lua` (`ensure_server`, `spawn_local_server`, health probe selects protocol).

Limits of the seam today (these require the core patches below):

- `protocols/connection.lua` hard-codes `adapters = { v1, v2 }`; `probe()` and `check_health()` are HTTP/curl based.
- `transport.lua` and `OpencodeServer` assume a URL and credential.
- `server_job.ensure_server` assumes an HTTP server launched via the opencode CLI.

## Naming and branding decisions (defaults)

1. **Internal namespace stays `opencode`** (`lua/opencode/...`). No mass rename. This is the single most important decision for merge cost.
2. **User-facing Pi branding via thin shims**:
   - `plugin/pi.lua`: `:Pi` command (delegating to the same command dispatcher).
   - `lua/pi/init.lua`: `setup(opts)` calling `require('opencode').setup(vim.tbl_deep_extend('force', { backend = 'pi' }, opts or {}))`.
   - `ftplugin/pi.lua`, `ftplugin/pi_output.lua`: keep filetype names the fork already exposes; they must not require edits to upstream files.
3. Fork-only files live in clearly separate locations (see "Fork-owned inventory"). Avoid editing upstream files except through the numbered core patches.

If a decision above is reversed by the maintainer, record it in this file before continuing.

## Branching and history

- Do **not** rewrite or force-push `main` during the migration.
- Create `rebase/upstream` from `opencode/main` (fetch with `git fetch opencode`; the remote uses HTTPS).
- The current `main` remains the reference implementation until parity is reached. Tag or branch it as `legacy-pi` before any switch.
- The final cut-over (making `rebase/upstream` the new `main`) is a separate, explicitly approved step. Contributors with local clones (for example the author of the earlier PRs) must be told.
- Commit style: concise Conventional Commit subject, no body unless needed. No explanatory comments in code unless they explain *why*.
- Environment note: `tag.gpgsign=true` is configured; use branches, not plain `git tag`, for local markers.

## Working agreements for agents

- Follow upstream's `AGENTS.md` once on the new branch (stylua on changed files only, `make format-check`, `make typecheck` with zero errors, `make topology-check`). The fork's current `AGENTS.md` is superseded on that branch.
- Do not read snapshot files under `tests/` (very large). Use `git diff --stat` or `rg -l` first.
- Do not use real local data in tests: no files from `~/.config/pi`, no real `pi` binary. See `tests/unit/open_session_smoke_spec.lua` for the pattern (temp `PI_CODING_AGENT_SESSION_DIR`, fake RPC client).
- Keep each core patch (P1…) in its own commit with the rationale in the commit body, since each is intended for an upstream PR.
- Verify behavior, not only module loading. An earlier sync passed `require()` checks yet broke UI startup. Every phase must pass the smoke test (below).

## Phases

### Phase 0: Baseline and spike branch

Tasks:
- `git fetch opencode`; create `rebase/upstream` from `opencode/main`.
- Run `make check`, `make topology`; record results as the baseline in the PR/commit notes.
- Port the hermetic smoke test (see Testing) to `opencode` module names. It must fail until the Pi adapter exists.

Acceptance: branch exists, upstream tests green, smoke test present and failing for the expected reason.

### Phase 1: Core patches (upstreamable)

Each is a separate small commit.

- **P1 protocol registry.** Replace the hard-coded `adapters` table in `protocols/connection.lua` with a registry: `register(name, adapter)`, lookup by name. `v1` and `v2` register themselves. Probe order becomes a list, not nested callbacks, and custom adapters can opt out of probing.
- **P2 transport-agnostic connection.** Allow a connection kind that is not HTTP (stdio). Adapters own `check_health`; `OpencodeServer` carries `kind`, with `url`/`credential` only for HTTP. Adjust `transport.lua` callers to go through the adapter (or no-op for stdio).
- **P3 pluggable server launch.** Let `server_job.ensure_server` delegate spawn and shutdown to the selected adapter (HTTP adapters keep the current behavior verbatim). Add config `backend = 'opencode' | 'pi'` (default `'opencode'` upstream; the `lua/pi` shim defaults to `'pi'`).
- **P4 capability reporting.** Ensure features that need unsupported resources (session tabs, file watching, multi-session) degrade through the existing `unsupported` sync state instead of erroring. Add the minimum UI guards where upstream assumes a capability.

Acceptance: upstream tests and `make check` pass unchanged with `backend = 'opencode'`; no behavior change for v1/v2. `make topology-check` clean.

### Phase 2: Pi protocol adapter (`lua/opencode/protocols/pi/`)

Files and where today's code goes:

| New file | Source in current fork | Responsibility |
| --- | --- | --- |
| `pi/process.lua` | `lua/pi/pi_process.lua`, `rpc_client.lua` | spawn `pi --mode rpc`, JSONL framing, request/response ids, event dispatch |
| `pi/connection.lua` | `lua/pi/pi_server.lua`, `server_job.lua` (Pi parts) | adapter definition for the registry (P1–P3), health = process alive |
| `pi/server.lua` | `pi_server.lua` | launch command, `PI_CODING_AGENT_*` env handling |
| `pi/sessions.lua` | `lua/pi/pi_sessions.lua` | read session JSONL on disk, workspace listing, titles |
| `pi/normalize.lua` | `lua/pi/event_adapter.lua`, `prompt_adapter.lua` | Pi messages/events to upstream normalized entries and parts |
| `pi/observation.lua` | `lua/pi/event_manager.lua`, `api_client.lua` (Pi branches) | implement `OpencodeObservationRuntime` (`request_resource`, `apply_resource`, `route_event`, ...) |
| `pi/operations.lua` | `lua/pi/api_client.lua` (Pi branches) | the operations surface listed above |
| `pi/types.lua` | `lua/pi/types.lua` (Pi parts) | Pi wire types |

Behavioral requirements carried over from the current fork (must be preserved and covered by tests):

- **Tool results merge into their tool call part** by `toolCallId`, for both history (`get_messages`, session file) and live (`tool_execution_*`) paths. Result text goes to `state.output`; status `error` when `isError`; `bash` additionally exposes `metadata.output` and `metadata.command`. (Current implementation and tests: `lua/pi/event_adapter.lua`, `tests/unit/event_adapter_spec.lua`.) Tools without a dedicated formatter render output in a fenced block (`ui/formatter/tools/tool.lua`, see commit `feat(formatter): render generic tool output in a code fence`).
- Reasoning parts are distinct from text (`thinking` content).
- Stable part ids across tool planning, execution and final message events.
- Session naming events update the active session (`session_info_changed`).
- Pi `steer`/`follow_up` surface as queued messages if upstream's queued indicator supports a projection (`queued` on user entries).
- Extension UI requests from Pi map to `permissions`/`questions` observation resources where an equivalent exists; otherwise mark the resource `unsupported`.
- Single active session: `switch_session` is a Pi RPC command, so session switching must go through the adapter and be reflected in observation state.

Acceptance: smoke test passes on `rebase/upstream` with `backend = 'pi'` and a fake RPC client; adapter unit tests cover the bullets above (port from `tests/unit/event_adapter_spec.lua`, `pi_sessions_spec.lua`, `pi_process_spec.lua`).

### Phase 3: Fork-owned UI and tooling (small independent commits)

Re-apply each as its own commit, ideally additive files rather than edits to upstream files:

| Feature | Current location | Notes |
| --- | --- | --- |
| Markdown table rendering | `ui/markdown_table.lua` (743 lines) | check whether upstream's formatter now covers it; upstream it if not |
| Image preview / image support | `ui/image_preview.lua`, `image_handler` changes | compare with upstream's `image_handler` first |
| `vanilla` commands | `commands/handlers/vanilla.lua` | registers via upstream dispatcher |
| Pi extension commands (`get_commands`, slash) | `commands/*`, `prompt_adapter.lua` | map into upstream `list_commands` |
| `pin` and `bin/` scripts | `lua/pi/pin.lua`, `bin/` | fork-owned, additive |
| Pi LSP helper | `lsp/pi_ls.lua` | compare with upstream `lsp/` and reuse |
| Auto session naming extension | `extensions/` | independent of Lua tree |
| Model picker allowlist | `model_picker.lua` change (`0ac53a7`) | small config-driven patch; upstream candidate |
| Find file from chat, UI polish (`e35571c`, `3eee468`, `0ba9c46`) | various `ui/*` | re-evaluate against upstream's current UI; drop if superseded |

Each item: confirm it is still needed on top of upstream, implement minimally, add a test, and note whether it is an upstream PR candidate.

### Phase 4: Branding shims and docs

- `plugin/pi.lua`, `lua/pi/init.lua`, `ftplugin/*` as described above.
- README: Pi installation and config; link back to upstream; document `backend` option.
- Delete `IMPLEMENTATION_PLAN.md` and `scripts/sync-upstream.sh`/`UPSTREAM` on the new branch (obsolete once this plan lands); keep the Pi RPC reference portions of `IMPLEMENTATION_PLAN.md` in `docs/` if still useful.

### Phase 5: Tests, CI, cut-over

- Port or replace tests that currently target stale opencode snapshots; the new branch inherits upstream's up-to-date test suite, so only Pi-specific tests are added.
- CI job (weekly and on demand): `git merge --no-commit opencode/main` on a scratch branch; report conflicting files. Fail loudly on conflicts in core files outside the numbered patches.
- Cut-over checklist: parity checklist below is green, `legacy-pi` preserved, contributors notified, README updated. Only then update `main`.

### Phase 6: Upstream collaboration (parallel, owned by the maintainer)

- Open a discussion/RFC with the upstream author using P1–P4 as the concrete proposal (registry, non-HTTP connection, pluggable launch, capability reporting).
- If accepted, offer the Pi adapter either in-tree (`protocols/pi`) or as an external plugin that registers via the registry. The fork then reduces to branding and fork-only features.

## Testing

Smoke test (mandatory gate for every phase, runs headless):

1. Create a temp session dir; set `PI_CODING_AGENT_SESSION_DIR` to it.
2. Write a fixture session `.jsonl` with: a user message, an assistant message with a text part and a `bash` tool call, and the matching `toolResult`.
3. Replace the Pi RPC client with an in-memory fake (`get_state`, `switch_session`, `get_messages`, process `start`/`stop`; any other method resolves with an empty table).
4. Open the UI through the runtime entry point and wait for the output buffer.
5. Assert: no promise rejection, an active session is set, the output buffer contains the tool output text.

Reference implementation on the legacy branch: `tests/unit/open_session_smoke_spec.lua`. It is known to fail when the UI cannot open (verified by reintroducing a faulty sync).

Also required:
- Adapter unit tests (see Phase 2 acceptance).
- Upstream's own test suite must stay green for `backend = 'opencode'`.
- Never run or edit large snapshot files without need; prefer targeted specs (`./run_tests.sh -t <file>`; upstream: `make test TEST=<path>`).

## Parity checklist (cut-over gate)

- Open sidebar, restore the last workspace session on startup, render history including tool calls with formatted output.
- Send a prompt, stream assistant text, reasoning and tool calls; abort works.
- Session picker lists workspace sessions; switching loads history.
- Model and thinking-level pickers; set/cycle model.
- Slash commands including Pi extension commands; skill completion.
- Queued (steer/follow-up) messages shown.
- Images attach and preview; `@` file mentions and context bar.
- Permissions/questions via extension UI where supported; clear message where not.
- Auto session naming updates the title.
- `backend = 'opencode'` still works unchanged against an opencode server (regression guard).

## Fork-owned inventory (what the fork must keep carrying)

Backend (moves under `protocols/pi/`): `pi_process`, `rpc_client`, `pi_server`, `pi_sessions`, `event_adapter`, `prompt_adapter`, Pi branches of `api_client`/`event_manager`.
Additive features: `markdown_table`, `image_preview`, `vanilla` commands, `pin`, `lsp/pi_ls`, `extensions/`, `bin/`, `ftplugin/pi*.lua`, `plugin/pi.lua`, `lua/pi/init.lua`.
Core patches to upstream files: P1–P4 only.

Keep this list current. If a change touches an upstream file outside P1–P4, it needs a justification in the commit body and an upstream-PR note.

## Risks and open questions

- Pi has one active session and no server-side multi-session; session tabs must degrade cleanly (P4).
- Permissions/questions: Pi's mechanism is extension UI requests, not first-class permission events. Decide per request type whether to map or mark unsupported.
- Snapshot/revert/diff features depend on opencode server semantics (`revert_message`, `files`); likely `unsupported` for Pi at first.
- Upstream may reject or reshape P1–P3. The fork must then carry them; keep them tiny and isolated to limit merge cost.
- Contributor coordination for the history switch (see Branching).
- `history` of local `main` includes work by other contributors (`bae0b5d`, `5930485`); preserve attribution when re-applying features (cherry-pick with `-x` where feasible).
