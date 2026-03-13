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

---

## Interaction Model

### Inline Scoped Task

The primary interaction:

1. **Select a scope** — visual selection. This is the task scope and the hard boundary for any edits.
2. **Dispatch** — trigger keymap, write a prompt in a minimal input. Hit enter to fire. Non-blocking.
3. **Lock indicator** — the selected region gets a subtle highlight + gutter sign indicating "AI working here." This is a visual mutex — signals don't edit this region while the task is pending.
4. **Result arrives** — inline diff appears within the locked region, never outside it. A notification or gutter change signals completion without interrupting cursor position.
5. **Accept or discard** — single keypress to apply or reject. Lock releases. Buffer returns to normal.

Multiple concurrent tasks on different regions are supported. Each has its own lock and resolves independently.

### Ask Without Editing

For questions and exploration — select a region or leave cursor in place, trigger a "ask" mode. Response appears in a floating window or scratch split. AI does not touch the buffer. Dismiss and return to work.

---

## Scope Enforcement

- Apply logic mechanically enforces the boundary — result is spliced into the original selection range, no file-level rewrites.
- AI never creates new files or touches anything outside the dispatched scope.

---

## Implementation

### Stack

- Pure Lua, Neovim 0.10+
- HTTP via `vim.system()` + `curl` (no Lua HTTP lib)
- Async via `vim.schedule()` for buffer-safe callbacks
- `vim.api.nvim_buf_set_extmark()` for lock highlights and virtual text

### Lock Highlight

Use a dedicated highlight group (`AiLock`) with a subtle background. Gutter sign (`⟳` pending, `✓` done) via `vim.fn.sign_place`. Virtual text shows elapsed time while pending.

---

## Keymap Sketch

| Mode   | Key            | Action                          |
|--------|----------------|---------------------------------|
| Visual | `<leader>ai`   | Dispatch inline task            |
| Visual | `<leader>aq`   | Ask (no edit)                   |
| Normal | `<leader>aa`   | Accept pending result at cursor |
| Normal | `<leader>ax`   | Discard pending result at cursor|
| Normal | `<leader>al`   | List pending tasks (loclist)    |


