# nvim-ai — Plugin Spec

## Vision

An AI integration for Neovim where **the developer stays in charge**. AI is invoked on demand, operates within explicit scopes, and never interrupts the editing flow. The mental model is async concurrency: dispatch a task, keep working, result arrives when ready.

---

## Core Principles

- **You drive, AI assists** — not the other way around
- **Scoped writes** — AI can only modify the region you explicitly selected
- **Non-blocking** — dispatching a task never pauses your editing
- **No dependencies** — direct Anthropic API via curl, no plugin deps
- **Anthropic-first** — Claude models only, for now
- **Lazy-compatible loading** — plugin must work when installed/loaded via `lazy.nvim`

---

## Interaction Model

### Inline Scoped Task

The primary interaction:

1. **Select a scope** — visual selection. This is the task scope and the hard boundary for any edits.
2. **Choose context** — trigger `<leader>ai` to open a picker:
   - `No extra context` (default selected)
   - `Whole file`
3. **Dispatch** — after choosing context, write a prompt in a minimal input and hit enter to fire. The input prompt must include the chosen context scope (for example: `AI prompt (No extra context):` or `AI prompt (Whole file):`). Non-blocking. After dispatch is accepted, editor mode returns to Normal mode.
4. **Task runs async** — you keep editing while the request is in flight. No lock highlight/sign is shown in MVP.
5. **Result arrives** — if the selected text snapshot is unchanged, the result is auto-applied to that original selected range and nowhere else.
6. **Stale protection** — if selection content changed while running, apply is aborted and the task is marked stale.

Context is read-only. Even when `Whole file` is chosen, apply logic remains scoped to the original visual selection.

The chosen context scope must be visible in dispatch notifications/messages.

Multiple concurrent tasks on different regions are supported. Dispatch is rejected if the new selection overlaps any currently running task.

---

## Scope Enforcement

- Apply logic mechanically enforces the boundary — result is spliced into the original selection range, no file-level rewrites.
- AI never creates new files or touches anything outside the dispatched scope.
- Before apply, current selection content is compared against the dispatch-time snapshot; mismatch means stale task and no write.

---

## Implementation

### Stack

- Pure Lua, Neovim 0.10+
- HTTP via `vim.system()` + `curl` (no Lua HTTP lib)
- Async via `vim.schedule()` for buffer-safe callbacks
- `vim.notify` for task lifecycle feedback
- Compatible with direct runtimepath loading and `lazy.nvim` plugin loading

### Task Lifecycle

- `running` — request is in flight
- `completed_applied` — response received and auto-applied to original selection
- `stale` — selection content changed since dispatch; response not applied
- `failed` — request error/invalid response
- `rejected_overlap` — dispatch denied due to overlap with a running task

### Concurrency Rules

- Multiple tasks can run concurrently as long as their selected ranges do not overlap.
- New dispatch with overlap is rejected immediately.
- No per-range visual lock is shown in MVP.

### Notifications

- Dispatch accepted (must include chosen context scope)
- Dispatch rejected (overlap)
- Task completed and applied
- Task marked stale (selection changed)
- Task failed

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
| Visual | `<leader>ai`   | Open context picker, then dispatch inline task |
| Visual | `<leader>ae`   | Explain selected scope (no edit)|
| Normal | `<leader>ae`   | Open explain result list        |
| Normal | `<leader>al`   | List running tasks              |

---

## Explain Mode (Non-Modifying Output)

Use case: request an explanation or other generated text about a selected scope without modifying code.

### Behavior

- Explain mode reuses the same visual scope capture and async dispatch model as inline edit tasks.
- Explain dispatch also uses the same context picker as inline tasks:
  - `No extra context` (default selected)
  - `Whole file`
- The selected code is sent as context, but no buffer text is replaced on completion.
- While running, the same in-progress visual indicators are shown on the selected range.
- The input prompt must include chosen context scope, and dispatch accepted notifications/messages must include chosen context scope.

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
