# Workspace duplication design

Status: implemented. Tagged app and unit-test target builds pass; both workspace duplication tests and all 10 shortcut JSON compatibility tests pass.

## Settled requirements

- Add Duplicate Workspace to the workspace context menu.
- Recreate the source workspace layout and resume its agents.
- Bind Control-D to duplication, editable in Settings. The user explicitly chose to override terminal Control-D behavior.
- Keep the source workspace's exact name (no Copy suffix).
- Place the duplicate below its source, in the same group, activate it, and retain color, description, and pinned status.
- Duplicate selected workspaces consistently from the context menu and keyboard action. With multiple workspaces selected, duplicate all of them; during normal single-workspace use, Control-D duplicates only the active workspace.
- Start with fresh notification and activity state.
- Codex is the required agent provider. Prefer composing existing layout restoration and agent resume functionality over introducing new mechanisms.
- Use the existing non-forked Codex resume command for detected resumable terminal conversations.
- Terminals without a resumable Codex conversation open fresh shells in the same directories; do not replay arbitrary commands.
- Copy browser URLs using the same browser profile, reopen the same files, and create fresh remote connections instead of attaching to original terminal sessions.

## Implementation defaults

- Expose the same selection-aware action in the command palette.
- Place each duplicate directly below its source; focus the duplicate of the active workspace if selected, otherwise the first selected workspace's duplicate. Collapse selection to that focused duplicate through the existing sidebar-selection path.
- Use existing restoration behavior for other supported panels. Native agent panels do not currently preserve conversation identity; the Codex resume requirement targets terminal Codex sessions.
- Do not copy unread notifications or running progress. If an existing Codex resume command fails, keep its terminal error visible rather than silently forking or starting another conversation.
- The user ended the interview and explicitly requested implementation without further questions.

## Code constraints

- Workspace snapshot/restore already reconstructs layout and creates fresh panel identities.
- Raw restoration also carries session bindings and runtime state, so duplication requires an explicit policy.
- Agent conversation fork actions already exist; provider support needs verification before choosing semantics.
- The user requested verification that the same non-forked conversation can coexist in different workspaces before deciding conversation identity semantics.
- Cmd-Shift-D and Cmd-Option-Shift-D are already assigned to splitting; Cmd-Control-Shift-D opens the diff viewer.
- Existing hook storage keys records by agent session ID and stores one workspace/surface association per record (`CLI/cmux.swift`, `upsert`). Duplication reuses the existing non-forked resume behavior; it does not redesign provider concurrency or hook tracking. Simultaneous live writes to the same Codex conversation were not exercised against user conversations.
- Existing session resume entry points already launch a saved conversation in another terminal/workspace (`SessionEntryResumeCoordinator.resume`, `Workspace.handleSessionDrop`). Reuse underlying resume commands rather than building another command generator.
- Control-D was proposed by the user; it conflicts with terminal EOF/delete behavior. Cmd-Control-D was initially suggested, but an existing shortcut comment identifies the macOS Look Up conflict, so it is not a good default either.
