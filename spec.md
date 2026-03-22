# nvim-ai — Plugin Spec

## Vision

An AI integration for Neovim where **the developer stays in charge**. AI is invoked on demand, operates within explicit scopes, and never interrupts the editing flow. The mental model is async concurrency: dispatch a task, keep working, result arrives when ready.

---

## Core Principles

- **You drive, AI assists** — not the other way around
- **Scoped writes by default** — inline edits are limited to the region you explicitly selected
- **Non-blocking** — dispatching a task never pauses your editing
- **Claude Code transport only** — requests are executed through the local Claude Code CLI
- **Single provider** — no direct Anthropic HTTP integration in this plugin
- **Lazy-compatible loading** — plugin must work when installed/loaded via `lazy.nvim`

---

## Interaction Model

### Inline Scoped Task

The primary interaction:

1. **Select a scope** — visual selection. This is the task scope and the hard boundary for any edits.
2. **Dispatch** — trigger `<leader>ai`, write a prompt in a minimal input, and hit enter to fire. The prompt label is `AI prompt:`. Non-blocking. After dispatch is accepted, editor mode returns to Normal mode.
3. **Task runs async** — you keep editing while the request is in flight. No lock highlight/sign is shown in MVP.
4. **Result arrives** — task scope is tracked with moving buffer anchors, so edits above/below the scope do not invalidate it; if the selected text snapshot is unchanged, the result is auto-applied to the current anchored range and nowhere else.
5. **Stale protection** — if the scoped content itself changed while running, apply is aborted and the task is marked stale.

Only the selected scope is sent as inline/explain context by default.

Multiple concurrent tasks on different regions are supported. Dispatch is rejected if the new selection overlaps any currently running task.

### Agentic Job Task (Repo-Wide Edits)

Use case: start from a visual selection as focus, but let Claude Code modify any files in the current working directory.

1. **Select a focus scope** — visual selection provides local context for the job request.
2. **Dispatch** — trigger `<leader>aj`, enter a prompt, and dispatch asynchronously.
3. **Task runs async** — same in-progress visuals and overlap rejection behavior as other visual tasks. Isolated workspace preparation is asynchronous and must not block editing.
4. **Isolated execution** — Claude Code runs in an isolated workspace copy, so your real working tree is not modified while the job is running.
5. **Result arrives** — plugin computes a pure job patch from isolated baseline vs isolated final state, validates it, then applies it to the real working tree atomically.
6. **Buffer refresh** — after apply, unmodified file buffers are refreshed from disk so open windows reflect job changes immediately.

Job mode is intentionally not scope-limited for writes; it is the explicit "agentic repo edit" mode.
By default, job dispatch runs Claude Code with permission mode `bypassPermissions` so non-interactive writes are not blocked by approval prompts.

### Agentic Search Task

Use case: ask Claude Code to investigate the codebase and return actionable search hits, not just a single generated `rg` command.

1. **Open prompt** — trigger `<leader>as` in Normal mode.
2. **Dispatch** — enter a natural-language search goal (for example: `find all places where task stale logic is handled`).
3. **Task runs async** — Claude Code performs multi-step repository search autonomously (can run multiple commands/tools) and compiles normalized matches.
4. **Ready notification** — when complete, show `Search <id> results ready`.
5. **Open latest results** — trigger `<leader>aq` to populate and open quickfix with the latest completed search results.

Search is non-modifying: it never writes to buffers/files and never applies inline edits.

---

## Scope Enforcement

- Inline edit mode (`<leader>ai`) mechanically enforces the boundary — result is spliced into the current anchored scope that represents the original selection, no file-level rewrites.
- In inline edit mode, AI never creates new files or touches anything outside the dispatched scope.
- In inline edit mode, before apply, current anchored scope content is compared against the dispatch-time snapshot; mismatch means stale task and no write.
- Scope anchors move with buffer edits, so unrelated line inserts/deletes outside the scope do not trigger stale failures.
- Boundary inserts are treated as outside the original scope (insert at start stays before, insert at end stays after).
- Job mode (`<leader>aj`) is the explicit exception: writes may occur anywhere in the current working directory.

---

## Implementation

### Stack

- Pure Lua, Neovim 0.10+
- Transport via `vim.system()` + Claude Code CLI (`claude`)
- Async via `vim.schedule()` for buffer-safe callbacks
- `vim.notify` for task lifecycle feedback
- Compatible with direct runtimepath loading and `lazy.nvim` plugin loading

### Runtime Requirements

- Claude Code CLI must be installed and available in `$PATH` as `claude`.
- User must be authenticated with Claude Code before dispatching tasks.
- Plugin invokes Claude Code per task; no long-running Claude Code instance is required.

### Task Lifecycle

- `running` — request is in flight
- `completed_applied` — response received and auto-applied to original selection
- `completed_job_done` — repo-wide job completed and isolated patch applied
- `completed_search_ready` — search response parsed and stored as latest quickfix payload
- `stale` — selection content changed since dispatch; response not applied
- `failed` — request error/invalid response
- `rejected_overlap` — dispatch denied due to overlap with a running task

### Concurrency Rules

- Multiple tasks can run concurrently as long as their selected ranges do not overlap.
- New dispatch with overlap is rejected immediately.
- No per-range visual lock is shown in MVP.

### Notifications

- Dispatch accepted
- Dispatch rejected (overlap)
- Task completed and applied (inline edit)
- Job completed
- Search results ready
- Task marked stale (selection changed)
- Task failed
- Task cancelled

### In-Progress Visual Indicators

Goal: show active task scope directly in the buffer without harming readability.

- No third-party dependency required; implement with Neovim core APIs (`nvim_buf_set_extmark`, virtual text/lines, timer).
- While a task is `running`, render a subtle highlight over its scoped range so syntax highlighting remains readable.
- Render a status label above the scoped region (virtual line above start row), for example: `⠋ Task 3 in progress`.
- Animate the status indicator with a lightweight spinner (braille or dots), updated on a shared timer.
- Support multiple concurrent running tasks; each task has independent extmarks and label text.
- Remove all task visuals immediately when the task reaches terminal state (`completed_applied`, `stale`, `failed`).
- Leaving Visual mode is part of dispatch UX: once a task is accepted, the visual selection is cleared and editing continues in Normal mode.

Suggested defaults:

- Spinner style: braille frames (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`)
- Update interval: `120ms`
- Label format: `Task <id> in progress`
- Highlight groups (user-overridable):
  - `AsyncAITaskRange` (subtle background tint)
  - `AsyncAITaskLabel` (status text color/style)

---

## Keymap Sketch

| Mode   | Key            | Action                          |
|--------|----------------|---------------------------------|
| Visual | `<leader>ai`   | Dispatch inline task |
| Visual | `<leader>aj`   | Dispatch repo-wide job task (selection provides focus context) |
| Visual | `<leader>ae`   | Explain selected scope (no edit)|
| Normal | `<leader>as`   | Open agentic search prompt and dispatch async search |
| Normal | `<leader>aq`   | Open quickfix with latest search results |
| Normal | `<leader>ae`   | Open explain result list        |
| Normal | `<leader>al`   | Open task browser (default filters: `COMPLETED` + `UNREAD`) |

---

## Task Browser (Snacks UI)

Use case: inspect recent tasks in one place, quickly filter by status/type, and open results without leaving editing flow.

### UI

- Implement with `snacks.nvim` picker-style modal only.
- If `snacks.nvim` is not available, show an error notification and abort opening.
- Rows are ordered newest to oldest.
- Keep in-memory history of the latest 200 tasks.

### Filters

- Filter chips are toggled with single keys inside the browser:
  - `c` => `COMPLETED`
  - `i` => `INPROGRESS`
  - `u` => `UNREAD`
  - `s` => `SEARCH`
  - `e` => `EXPLAIN`
  - `d` => `EDIT`
  - `j` => `JOB`
  - `0` => clear all filters
  - `a` => enable all filters
- The active filter set is configurable per binding: different bindings can open the same browser with different default filters.
- `<leader>al` must open with default filters `COMPLETED + UNREAD`.
- If no filters are active, show all tasks (including `stale`, `failed`, `cancelled`).

### Read/Unread Semantics

- `UNREAD` is meaningful for completed tasks.
- `INPROGRESS` tasks are always treated as unread.
- Pressing `<Enter>` on a completed task marks it as read.
- Pressing `<Enter>` on terminal error states (`stale`, `failed`, `cancelled`) marks read and shows an error/status message.

### Row Actions

- `<Enter>` behavior:
  - `EXPLAIN` completed task => open explanation output
  - `SEARCH` completed task => open quickfix with that task's results
  - `EDIT` completed task => open inline diff
  - `JOB` completed task => open per-job changed-file list + isolated patch diff (exact patch that was applied)
  - `INPROGRESS` task => no action
- `x` on `INPROGRESS` task asks for confirmation, then cancels task if confirmed.

### Task History States

- Browser history includes running and terminal tasks.
- `COMPLETED` filter matches successful tasks only.
- Non-success terminal tasks (`stale`, `failed`, `cancelled`) are visible when filter selection allows them (always visible when no filters are active).

---

## Search Mode (Agentic, Quickfix Output)

### Behavior

- Search dispatch is initiated from Normal mode via `<leader>as`.
- Prompt is free-form natural language; no visual selection is required.
- Claude Code is expected to run a proper investigative flow (multiple commands/steps as needed), then return structured hits.
- Plugin converts hits into quickfix entries (`filename`, `lnum`, optional `col`, `text`) and stores them in an in-memory latest-search slot.
- On completion, only a notification is shown; quickfix does not auto-open.

### Output Access

- `<leader>aq` opens quickfix populated with the latest completed search.
- If no completed search exists yet, show a warning notification.
- Opening quickfix is pull-based so it never steals focus when a task completes.

### Rationale

- Claude Code as an agent can produce substantially better search outcomes than one-shot command generation.
- Async notification + pull-based quickfix keeps editing flow uninterrupted.
- Quickfix provides native jump/navigation UX for search-driven code exploration.

---

## Explain Mode (Non-Modifying Output)

Use case: request an explanation or other generated text about a selected scope without modifying code.

### Behavior

- Explain mode reuses the same visual scope capture and async dispatch model as inline edit tasks.
- The selected code is sent as context, but no buffer text is replaced on completion.
- While running, the same in-progress visual indicators are shown on the selected range.
- The input prompt label is `AI prompt:`.

### Output Display (Recommended)

- Do not auto-open output UI when response arrives.
- On completion, show a notification like: `Task <id> explanation ready`.
- Persist explain responses in an in-memory task result store.
- Open output only on explicit user action (pull-based UX), e.g. command or keymap.
- Recommended reader UI when invoked: scratch floating window (no file, wipe on close) with multiline support.
- Suggested in-window keymaps:
  - `q` close window
  - `p` pin output into a normal split for persistent reading
  - `y` yank full output text

### Rationale

- Better than notifications for multiline text.
- Async workflow is preserved: completion never steals focus.
- Less disruptive than auto-opening a window or split.
- Keeps explain workflow fast while preserving editing context.

### Suggested Config

- `explain.window = "float"` (default)
- `explain.max_width`, `explain.max_height`
- `explain.wrap = true`
- `explain.filetype = "markdown"`
- `explain.auto_open = false` (default)

### Accessing Ready Results

- Bind `<leader>ae` in normal mode to open the explain result list.
- If multiple explain tasks are completed, provide a simple picker/list to choose which result to open (use snacks picker).
- Keep notification-only behavior for completion; reading is always user-initiated.

---

## Validation

- Validate plugin behavior in a normal runtimepath setup.
- Validate plugin behavior when loaded through `lazy.nvim`.
- During MVP development, prefer testing via `lazy.nvim` to match real-world usage.

## Developer Workflow Requirement

- Provide a `Makefile` with a target that opens Neovim using the user's `~/.config/nvim` config and also loads the local `async-ai.nvim` plugin from the current working tree.
