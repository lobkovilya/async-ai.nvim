local M = {}

local state = {
  next_id = 1,
  tasks = {},
  task_history_order = {},
  task_history_by_id = {},
  explain_results = {
    order = {},
    by_id = {},
  },
  latest_search_result = nil,
  commands_registered = false,
  ui = {
    ns = nil,
    timer = nil,
    spinner_index = 1,
  },
}

local config = {
  claude_cmd = { "claude", "-p" },
  job = {
    permission_mode = "bypassPermissions",
  },
  keymaps = {
    enabled = true,
    inline = "<leader>ai",
    job = "<leader>aj",
    explain_dispatch = "<leader>ae",
    explain_open = "<leader>ae",
    search_dispatch = "<leader>as",
    search_open = "<leader>aq",
    list = nil,
    task_browser = {
      ["<leader>al"] = { "COMPLETED", "UNREAD" },
      ["<leader>aa"] = {},
    },
  },
  ui = {
    enabled = true,
    spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    update_ms = 120,
    label_format = "Task %d in progress",
    range_hl_group = "AsyncAITaskRange",
    label_hl_group = "AsyncAITaskLabel",
  },
  explain = {
    window = "float",
    max_width = 120,
    max_height = 30,
    wrap = true,
    filetype = "markdown",
    auto_open = false,
  },
  task_browser = {
    history_limit = 200,
  },
}

local filter_order = { "COMPLETED", "INPROGRESS", "UNREAD", "SEARCH", "EXPLAIN", "EDIT", "JOB" }

local success_statuses = {
  completed_applied = true,
  completed_job_done = true,
  completed_explain_ready = true,
  completed_search_ready = true,
}

local terminal_statuses = {
  completed_applied = true,
  completed_job_done = true,
  completed_explain_ready = true,
  completed_search_ready = true,
  stale = true,
  failed = true,
  cancelled = true,
}

local cancel_running_task

local function task_kind(mode)
  if mode == "search" then
    return "SEARCH"
  end
  if mode == "explain" then
    return "EXPLAIN"
  end
  if mode == "job" then
    return "JOB"
  end
  return "EDIT"
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "async-ai.nvim" })
end

local function is_before_or_equal(a_row, a_col, b_row, b_col)
  return a_row < b_row or (a_row == b_row and a_col <= b_col)
end

local function ranges_overlap(a, b)
  if a.bufnr ~= b.bufnr then
    return false
  end

  if is_before_or_equal(a.end_row, a.end_col, b.start_row, b.start_col) then
    return false
  end

  if is_before_or_equal(b.end_row, b.end_col, a.start_row, a.start_col) then
    return false
  end

  return true
end

local function split_lines(text)
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function push_explain_result(result)
  state.explain_results.by_id[result.task_id] = result
  table.insert(state.explain_results.order, result.task_id)
end

local function get_latest_explain_result()
  local order = state.explain_results.order
  if #order == 0 then
    return nil
  end
  local id = order[#order]
  return state.explain_results.by_id[id]
end

local function history_limit()
  local value = tonumber(config.task_browser and config.task_browser.history_limit) or 200
  if value < 1 then
    value = 1
  end
  return math.floor(value)
end

local function trim_task_history()
  local limit = history_limit()
  while #state.task_history_order > limit do
    local oldest_id = table.remove(state.task_history_order, 1)
    state.task_history_by_id[oldest_id] = nil
  end
end

local function ensure_task_history(task)
  local existing = state.task_history_by_id[task.id]
  if existing then
    return existing
  end

  local bufnr = nil
  local bufname = nil
  if task.range and task.range.bufnr and vim.api.nvim_buf_is_valid(task.range.bufnr) then
    bufnr = task.range.bufnr
    bufname = vim.api.nvim_buf_get_name(task.range.bufnr)
  end

  local entry = {
    id = task.id,
    mode = task.mode,
    kind = task_kind(task.mode),
    prompt = task.prompt,
    status = task.status or "running",
    created_at = os.time(),
    updated_at = os.time(),
    read = false,
    bufnr = bufnr,
    bufname = bufname,
    range = task.range,
    snapshot = task.snapshot,
  }
  state.task_history_by_id[task.id] = entry
  table.insert(state.task_history_order, task.id)
  trim_task_history()
  return entry
end

local function update_task_history(task, patch)
  local entry = ensure_task_history(task)
  for key, value in pairs(patch or {}) do
    entry[key] = value
  end
  entry.updated_at = os.time()
  return entry
end

local function history_entry(task_id)
  return state.task_history_by_id[task_id]
end

local function format_result_title(result)
  local name = result.bufname
  if not name or name == "" then
    name = "[No Name]"
  else
    name = vim.fn.fnamemodify(name, ":~:.")
  end
  return string.format("Async AI Explain #%d - %s", result.task_id, name)
end

local function open_result_in_split(result)
  local lines = split_lines(result.text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = config.explain.filetype
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd("belowright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, format_result_title(result))
end

local function open_result_in_float(result)
  local lines = split_lines(result.text)
  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end

  local max_width = math.max(40, math.min(config.explain.max_width, vim.o.columns - 4))
  local width = math.max(40, math.min(max_width, content_width + 2))
  local max_height = math.max(8, math.min(config.explain.max_height, vim.o.lines - 4))
  local height = math.max(6, math.min(max_height, #lines + 2))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = config.explain.filetype
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = format_result_title(result),
  })

  vim.wo[win].wrap = config.explain.wrap

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set("n", "p", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    open_result_in_split(result)
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', result.text)
    notify("Explain output yanked")
  end, { buffer = buf, silent = true, nowait = true })
end

local function open_explain_result(result)
  if not result then
    notify("No explain result to open", vim.log.levels.WARN)
    return
  end

  if config.explain.window == "split" then
    open_result_in_split(result)
    return
  end

  open_result_in_float(result)
end

local function list_explain_result_items()
  local items = {}
  for i = #state.explain_results.order, 1, -1 do
    local id = state.explain_results.order[i]
    local result = state.explain_results.by_id[id]
    if result then
      local name = result.bufname
      if name == "" then
        name = "[No Name]"
      else
        name = vim.fn.fnamemodify(name, ":~:.")
      end
      table.insert(items, {
        label = string.format("#%d %s", result.task_id, name),
        result = result,
      })
    end
  end
  return items
end

local function open_explain_picker()
  local items = list_explain_result_items()
  if #items == 0 then
    notify("No explain results yet", vim.log.levels.WARN)
    return
  end

  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and snacks and snacks.picker and snacks.picker.select then
    local ok_picker = pcall(snacks.picker.select, items, {
      prompt = "Explain results",
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if item then
        open_explain_result(item.result)
      end
    end)

    if ok_picker then
      return
    end
  end

  vim.ui.select(items, {
    prompt = "Explain results",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      open_explain_result(item.result)
    end
  end)
end

local function make_filter_set(filters)
  local set = {}
  for _, key in ipairs(filters or {}) do
    if type(key) == "string" and key ~= "" then
      set[key] = true
    end
  end
  return set
end

local function is_unread(entry)
  if entry.status == "running" then
    return true
  end
  return not entry.read
end

local function matches_unread_filter(entry)
  if entry.status == "running" then
    return false
  end
  return not entry.read
end

local function matches_filters(entry, active)
  local any = false
  for _ in pairs(active) do
    any = true
    break
  end

  if not any then
    return true
  end

  local status_match = true
  local has_status_filter = active.COMPLETED or active.INPROGRESS or active.UNREAD
  if has_status_filter then
    status_match = false
    if active.COMPLETED and success_statuses[entry.status] then
      status_match = true
    end
    if active.INPROGRESS and entry.status == "running" then
      status_match = true
    end
    if active.UNREAD and matches_unread_filter(entry) then
      status_match = true
    end
  end

  local type_match = true
  local has_type_filter = active.SEARCH or active.EXPLAIN or active.EDIT or active.JOB
  if has_type_filter then
    type_match = active[entry.kind] == true
  end

  return status_match and type_match
end

local function status_badge(entry)
  if entry.status == "running" then
    return "INPROGRESS"
  end
  if success_statuses[entry.status] then
    return "COMPLETED"
  end
  return string.upper(entry.status)
end

local function build_task_browser_rows(active)
  local rows = {}
  for i = #state.task_history_order, 1, -1 do
    local id = state.task_history_order[i]
    local entry = state.task_history_by_id[id]
    if entry and matches_filters(entry, active) then
      local short_prompt = vim.trim(entry.prompt or "")
      if #short_prompt > 70 then
        short_prompt = short_prompt:sub(1, 67) .. "..."
      end
      local unread_badge = is_unread(entry) and " UNREAD" or ""
      local text = string.format("#%d %-9s %-10s%s %s", entry.id, entry.kind, status_badge(entry), unread_badge, short_prompt)
      table.insert(rows, {
        text = text,
        entry = entry,
      })
    end
  end
  return rows
end

local function filters_text(active)
  local chips = {}
  for _, name in ipairs(filter_order) do
    if active[name] then
      table.insert(chips, "[" .. name .. "]")
    end
  end
  if #chips == 0 then
    return "[ALL]"
  end
  return table.concat(chips, " ")
end

local function open_text_result(title, text, filetype)
  local lines = split_lines(text or "")
  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end

  local width = math.max(50, math.min(vim.o.columns - 4, content_width + 4))
  local height = math.max(8, math.min(vim.o.lines - 4, #lines + 2))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = filetype or "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if (filetype or "markdown") == "diff" then
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd("silent! syntax enable")
      vim.cmd("silent! setlocal syntax=diff")
    end)
  end
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = title,
  })

  vim.wo[win].wrap = (filetype or "markdown") ~= "diff"
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, silent = true, nowait = true })
end

local function split_nonempty_lines(text)
  return vim.split(text or "", "\n", { plain = true, trimempty = true })
end

local function write_workspace_tree(cwd)
  local add_obj = vim.system({ "git", "add", "-A", "--", "." }, {
    text = true,
    cwd = cwd,
  }):wait()
  if add_obj.code ~= 0 then
    return nil, vim.trim(add_obj.stderr or "git add failed")
  end

  local write_tree = vim.system({ "git", "write-tree" }, {
    text = true,
    cwd = cwd,
  }):wait()
  if write_tree.code ~= 0 then
    return nil, vim.trim(write_tree.stderr or "git write-tree failed")
  end

  local tree = vim.trim(write_tree.stdout or "")
  if tree == "" then
    return nil, "empty tree hash"
  end
  return tree, nil
end

local function create_isolated_job_workspace_async(source_cwd, callback)
  local isolated_dir = vim.fn.tempname()
  vim.fn.mkdir(isolated_dir, "p")

  local script = table.concat({
    "set -euo pipefail",
    "src=\"$1\"",
    "dst=\"$2\"",
    "cd \"$src\"",
    "git ls-files -co --exclude-standard -z | while IFS= read -r -d '' rel; do",
    "  mkdir -p \"$dst/$(dirname \"$rel\")\"",
    "  cp -p \"$src/$rel\" \"$dst/$rel\"",
    "done",
    "cd \"$dst\"",
    "git init -q",
    "git add -A -- .",
    "git write-tree",
  }, "\n")

  vim.system({ "bash", "-lc", script, "async-ai-job", source_cwd, isolated_dir }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.fn.delete(isolated_dir, "rf")
        local reason = vim.trim(obj.stderr or "")
        if reason == "" then
          reason = "failed to prepare isolated job workspace"
        end
        callback(nil, nil, reason)
        return
      end

      local baseline_tree = vim.trim(obj.stdout or "")
      if baseline_tree == "" then
        vim.fn.delete(isolated_dir, "rf")
        callback(nil, nil, "isolated workspace baseline tree is empty")
        return
      end

      callback(isolated_dir, baseline_tree, nil)
    end)
  end)
end

local function diff_workspace_trees(cwd, before_tree, after_tree)
  if not before_tree or before_tree == "" or not after_tree or after_tree == "" then
    return nil, nil
  end

  if before_tree == after_tree then
    return "", {}
  end

  local diff_obj = vim.system({ "git", "diff", "--binary", "--no-color", before_tree, after_tree }, {
    text = true,
    cwd = cwd,
  }):wait()
  local names_obj = vim.system({ "git", "diff", "--name-only", before_tree, after_tree }, {
    text = true,
    cwd = cwd,
  }):wait()

  if diff_obj.code ~= 0 or names_obj.code ~= 0 then
    return nil, nil
  end

  return diff_obj.stdout or "", split_nonempty_lines(names_obj.stdout)
end

local function apply_job_patch(cwd, patch_text)
  if not patch_text or patch_text == "" then
    return true, nil
  end

  local check_obj = vim.system({ "git", "apply", "--check", "--binary", "--whitespace=nowarn", "-" }, {
    text = true,
    cwd = cwd,
    stdin = patch_text,
  }):wait()
  if check_obj.code ~= 0 then
    return false, vim.trim(check_obj.stderr or "git apply --check failed")
  end

  local apply_obj = vim.system({ "git", "apply", "--binary", "--whitespace=nowarn", "-" }, {
    text = true,
    cwd = cwd,
    stdin = patch_text,
  }):wait()
  if apply_obj.code ~= 0 then
    return false, vim.trim(apply_obj.stderr or "git apply failed")
  end

  return true, nil
end

local function refresh_unmodified_file_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.bo[bufnr].buftype == "" and not vim.bo[bufnr].modified then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent! checktime")
          end)
        end
      end
    end
  end
end

local function open_edit_result(entry)
  if entry.mode == "job" then
    local changed_files = entry.job_diff_files or {}
    local diff_text = entry.job_diff or ""

    local text = nil
    if #changed_files > 0 or diff_text ~= "" then
      text = table.concat({
        "Changed files:",
        (#changed_files > 0 and table.concat(changed_files, "\n") or "(none)"),
        "",
        "Diff:",
        (diff_text ~= "" and diff_text or "(empty diff output)"),
      }, "\n")
      open_text_result(string.format("Async AI Job #%d", entry.id), text, "diff")
      return
    end

    text = table.concat({
      "No isolated diff captured for this job.",
      "",
      "Instruction:",
      entry.prompt or "",
      "",
      "Job result:",
      entry.generated or "",
    }, "\n")
    open_text_result(string.format("Async AI Job #%d", entry.id), text, "markdown")
    return
  end

  local before = entry.snapshot or ""
  local after = entry.generated or ""
  local text = nil
  if vim.diff then
    text = vim.diff(before, after, { result_type = "unified", ctxlen = 3 })
  end
  if not text or text == "" then
    text = table.concat({
      "Instruction:",
      entry.prompt or "",
      "",
      "Result:",
      after,
    }, "\n")
  end

  open_text_result(string.format("Async AI Edit #%d", entry.id), text, "diff")
end

local function open_search_result(entry)
  local items = entry.search_items or {}
  vim.fn.setqflist({}, " ", {
    title = string.format("Async AI Search #%d", entry.id),
    items = items,
  })
  vim.cmd("copen")
end

local function mark_entry_read(entry)
  if not entry then
    return
  end
  entry.read = true
  entry.updated_at = os.time()
end

local function open_task_history_entry(entry)
  if not entry then
    return false
  end

  if entry.status == "running" then
    return false
  end

  mark_entry_read(entry)

  if entry.kind == "EXPLAIN" and success_statuses[entry.status] then
    local result = {
      task_id = entry.id,
      text = entry.explain_text or entry.generated or "",
      bufnr = entry.bufnr,
      bufname = entry.bufname,
      range = entry.range,
    }
    open_explain_result(result)
    return true
  end

  if entry.kind == "SEARCH" and success_statuses[entry.status] then
    open_search_result(entry)
    return true
  end

  if (entry.kind == "EDIT" or entry.kind == "JOB") and success_statuses[entry.status] then
    open_edit_result(entry)
    return true
  end

  local message = entry.error or ("Task status: " .. entry.status)
  notify("Task " .. entry.id .. ": " .. message, vim.log.levels.WARN)
  return false
end

local function open_task_browser(default_filters)
  local ok_snacks, snacks = pcall(require, "snacks")
  if not ok_snacks or not snacks or not snacks.picker then
    notify("snacks.nvim is required for task browser", vim.log.levels.ERROR)
    return
  end

  local picker_state = {
    active = make_filter_set(default_filters),
  }

  local function finder()
    return build_task_browser_rows(picker_state.active)
  end

  local function refresh(picker)
    picker.title = "Async AI Tasks " .. filters_text(picker_state.active)
    picker:update_titles()
    picker:find({ refresh = true })
  end

  local function toggle(name)
    return function(picker)
      picker_state.active[name] = not picker_state.active[name]
      refresh(picker)
    end
  end

  local function clear_all(picker)
    picker_state.active = {}
    refresh(picker)
  end

  local function cancel_selected(picker)
    local item = picker:current()
    local entry = item and item.entry or nil
    if not entry or entry.status ~= "running" then
      return
    end

    vim.ui.select({ "No", "Yes" }, { prompt = string.format("Cancel task #%d?", entry.id) }, function(choice)
      if choice ~= "Yes" then
        return
      end

      local task = state.tasks[entry.id]
      if task and task.status == "running" then
        cancel_running_task(task)
      end
      refresh(picker)
    end)
  end

  local function confirm_entry(picker, item)
    local row = item or picker:current()
    if not row or not row.entry then
      return
    end

    local opened = open_task_history_entry(row.entry)
    if opened then
      picker:close()
      return
    end

    refresh(picker)
  end

  snacks.picker({
    title = "Async AI Tasks " .. filters_text(picker_state.active),
    focus = "list",
    finder = finder,
    format = "text",
    preview = "none",
    layout = { preset = "select" },
    confirm = confirm_entry,
    actions = {
      toggle_completed = toggle("COMPLETED"),
      toggle_inprogress = toggle("INPROGRESS"),
      toggle_unread = toggle("UNREAD"),
      toggle_search = toggle("SEARCH"),
      toggle_explain = toggle("EXPLAIN"),
      toggle_edit = toggle("EDIT"),
      toggle_job = toggle("JOB"),
      clear_filters = clear_all,
      cancel_task = cancel_selected,
    },
    win = {
      list = {
        keys = {
          ["c"] = "toggle_completed",
          ["i"] = "toggle_inprogress",
          ["u"] = "toggle_unread",
          ["s"] = "toggle_search",
          ["e"] = "toggle_explain",
          ["d"] = "toggle_edit",
          ["j"] = "toggle_job",
          ["0"] = "clear_filters",
          ["x"] = "cancel_task",
        },
      },
    },
  })
end

local function get_namespace()
  if not state.ui.ns then
    state.ui.ns = vim.api.nvim_create_namespace("async_ai")
  end
  return state.ui.ns
end

local function set_task_anchor(task)
  if not task.range then
    return true
  end

  local range = task.range
  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return false, "Task buffer is no longer valid"
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, range.bufnr, get_namespace(), range.start_row, range.start_col, {
    end_row = range.end_row,
    end_col = range.end_col,
    right_gravity = true,
    end_right_gravity = false,
  })

  if not ok or not mark_id then
    return false, "Failed to anchor task range"
  end

  task.anchor_bufnr = range.bufnr
  task.anchor_mark_id = mark_id
  return true
end

local function resolve_task_range(task)
  if not task or not task.anchor_bufnr or not task.anchor_mark_id then
    return nil
  end

  if not vim.api.nvim_buf_is_valid(task.anchor_bufnr) then
    return nil
  end

  local mark = vim.api.nvim_buf_get_extmark_by_id(task.anchor_bufnr, get_namespace(), task.anchor_mark_id, {
    details = true,
  })
  if type(mark) ~= "table" or type(mark[1]) ~= "number" or type(mark[2]) ~= "number" then
    return nil
  end

  local details = mark[3]
  if type(details) ~= "table" or type(details.end_row) ~= "number" or type(details.end_col) ~= "number" then
    return nil
  end

  return {
    bufnr = task.anchor_bufnr,
    start_row = mark[1],
    start_col = mark[2],
    end_row = details.end_row,
    end_col = details.end_col,
  }
end

local function task_runtime_range(task)
  return resolve_task_range(task) or task.range
end

local function set_default_highlights()
  if not config.ui or not config.ui.enabled then
    return
  end

  vim.api.nvim_set_hl(0, config.ui.range_hl_group, {
    default = true,
    bg = "#2a3343",
  })

  vim.api.nvim_set_hl(0, config.ui.label_hl_group, {
    default = true,
    fg = "#7fb7ff",
    bold = true,
  })
end

local function format_task_label(task, frame)
  local base = string.format(config.ui.label_format, task.id)
  if frame and frame ~= "" then
    return frame .. " " .. base
  end
  return base
end

local function upsert_task_label(task, frame)
  if not config.ui or not config.ui.enabled then
    return
  end

  local range = task_runtime_range(task)
  if not range then
    return
  end

  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, range.bufnr, get_namespace(), range.start_row, 0, {
    id = task.ui_label_mark_id,
    virt_lines = {
      {
        { format_task_label(task, frame), config.ui.label_hl_group },
      },
    },
    virt_lines_above = true,
  })

  if ok then
    task.ui_label_mark_id = mark_id
  end
end

local function clear_task_indicators(task)
  if not task then
    return
  end

  if task.anchor_mark_id and task.anchor_bufnr and vim.api.nvim_buf_is_valid(task.anchor_bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, task.anchor_bufnr, get_namespace(), task.anchor_mark_id)
    task.anchor_mark_id = nil
    task.anchor_bufnr = nil
  end

  if not config.ui or not config.ui.enabled then
    return
  end

  local range = task_runtime_range(task)
  if not range then
    return
  end

  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return
  end

  local ns = get_namespace()
  if task.ui_range_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, range.bufnr, ns, task.ui_range_mark_id)
    task.ui_range_mark_id = nil
  end

  if task.ui_label_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, range.bufnr, ns, task.ui_label_mark_id)
    task.ui_label_mark_id = nil
  end
end

local function has_running_tasks()
  for _, task in pairs(state.tasks) do
    if task.status == "running" and task.range then
      return true
    end
  end
  return false
end

local function stop_spinner_timer()
  if state.ui.timer then
    state.ui.timer:stop()
    state.ui.timer:close()
    state.ui.timer = nil
  end
end

local function spinner_frame()
  local frames = config.ui and config.ui.spinner_frames or nil
  if type(frames) ~= "table" or #frames == 0 then
    return ""
  end

  local index = state.ui.spinner_index
  if index < 1 or index > #frames then
    index = 1
  end

  local frame = frames[index]
  index = index + 1
  if index > #frames then
    index = 1
  end
  state.ui.spinner_index = index
  return frame
end

local function tick_spinner()
  if not config.ui or not config.ui.enabled then
    stop_spinner_timer()
    return
  end

  if not has_running_tasks() then
    stop_spinner_timer()
    return
  end

  local frame = spinner_frame()
  for _, task in pairs(state.tasks) do
    if task.status == "running" and task.range then
      upsert_task_label(task, frame)
    end
  end
end

local function start_spinner_timer()
  if not config.ui or not config.ui.enabled then
    return
  end

  if state.ui.timer then
    return
  end

  local interval = tonumber(config.ui.update_ms) or 120
  if interval < 50 then
    interval = 50
  end

  state.ui.timer = vim.uv.new_timer()
  state.ui.timer:start(interval, interval, vim.schedule_wrap(tick_spinner))
end

local function add_task_indicators(task)
  if not config.ui or not config.ui.enabled then
    return
  end

  local range = task_runtime_range(task)
  if not range then
    return
  end

  if not vim.api.nvim_buf_is_valid(range.bufnr) then
    return
  end

  local ok, range_mark_id = pcall(vim.api.nvim_buf_set_extmark, range.bufnr, get_namespace(), range.start_row, range.start_col, {
    end_row = range.end_row,
    end_col = range.end_col,
    hl_group = config.ui.range_hl_group,
    hl_mode = "combine",
  })

  if ok then
    task.ui_range_mark_id = range_mark_id
  end

  upsert_task_label(task, spinner_frame())
  start_spinner_timer()
end

local function leave_visual_mode()
  local mode = vim.fn.mode(1)
  if mode == "v" or mode == "V" or mode == "\022" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

local function get_line(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
  return lines[1] or ""
end

local function normalize_visual_range(bufnr)
  local visual_mode = vim.fn.mode(1)
  local start_pos
  local end_pos

  if visual_mode == "v" or visual_mode == "V" or visual_mode == "\022" then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getcurpos()
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
    visual_mode = vim.fn.visualmode()
  end

  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil, "No active visual selection"
  end

  if visual_mode == "\022" then
    return nil, "Block selections are not supported"
  end

  local srow = start_pos[2] - 1
  local scol = math.max(start_pos[3] - 1, 0)
  local erow = end_pos[2] - 1
  local ecol_inclusive = math.max(end_pos[3] - 1, 0)

  if not is_before_or_equal(srow, scol, erow, ecol_inclusive) then
    srow, erow = erow, srow
    scol, ecol_inclusive = ecol_inclusive, scol
  end

  if visual_mode == "V" then
    scol = 0
    ecol_inclusive = math.max(#get_line(bufnr, erow) - 1, 0)
  end

  local end_line = get_line(bufnr, erow)
  local end_col = math.min(ecol_inclusive + 1, #end_line)

  if visual_mode == "V" then
    end_col = #end_line
  end

  return {
    bufnr = bufnr,
    start_row = srow,
    start_col = scol,
    end_row = erow,
    end_col = end_col,
  }
end

local function range_text(range)
  local text = vim.api.nvim_buf_get_text(
    range.bufnr,
    range.start_row,
    range.start_col,
    range.end_row,
    range.end_col,
    {}
  )
  return table.concat(text, "\n")
end

local function build_prompt(task)
  if task.mode == "search" then
    return table.concat({
      "You are a codebase search agent running inside Neovim via Claude Code CLI.",
      "Investigate the repository using as many steps/commands as needed.",
      "Return search hits only, as strict JSON with no markdown.",
      "Output format:",
      '{"results":[{"filename":"path/to/file","lnum":12,"col":3,"text":"matching context"}]}',
      "Rules:",
      "- filename must be repository-relative when possible.",
      "- lnum must be 1-based integer.",
      "- col is optional; default to 1 when unknown.",
      "- text should be a short single-line summary of why this hit is relevant.",
      "- If no matches, return: {\"results\":[]}",
      "- Do not include commentary before or after JSON.",
      "",
      "Search request:",
      task.prompt,
    }, "\n")
  end

  if task.mode == "explain" then
    return table.concat({
      "You are explaining a selected code scope from Neovim.",
      "Respond with a concise, helpful multiline explanation.",
      "",
      "Instruction:",
      task.prompt,
      "",
      "Selection:",
      task.snapshot,
    }, "\n")
  end

  if task.mode == "job" then
    return table.concat({
      "You are running an agentic repository edit task from Neovim via Claude Code CLI.",
      "You are executing inside an isolated workspace copy.",
      "Use the selected snippet as focus context, but you may read and modify files anywhere in this workspace.",
      "Apply the user's instruction directly by editing repository files when needed.",
      "Do not output patches or full file contents.",
      "When done, return a concise plain-text summary of what you changed.",
      "",
      "Instruction:",
      task.prompt,
      "",
      "Focus selection:",
      task.snapshot,
    }, "\n")
  end

  return table.concat({
    "You are editing a scoped selection in Neovim.",
    "Apply the user's instruction to the provided selection and return only replacement text.",
    "Do not include markdown fences or explanations.",
    "",
    "Instruction:",
    task.prompt,
    "",
    "Selection:",
    task.snapshot,
  }, "\n")
end

local function selection_overlaps_running_task(range)
  for _, existing in pairs(state.tasks) do
    local existing_range = task_runtime_range(existing)
    if existing.status == "running" and existing_range and ranges_overlap(existing_range, range) then
      return true
    end
  end
  return false
end

local function remove_task(task_id)
  local task = state.tasks[task_id]
  if task then
    task.proc = nil
    if task.job_isolated_dir and task.job_isolated_dir ~= "" then
      vim.fn.delete(task.job_isolated_dir, "rf")
      task.job_isolated_dir = nil
    end
  end
  clear_task_indicators(task)
  state.tasks[task_id] = nil

  if not has_running_tasks() then
    stop_spinner_timer()
  end
end

local function decode_json_maybe_fenced(text)
  local trimmed = vim.trim(text or "")
  if trimmed == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, trimmed)
  if ok then
    return decoded
  end

  local unfenced = trimmed:gsub("^```[%w_-]*\n", ""):gsub("\n```$", "")
  if unfenced ~= trimmed then
    local ok_fenced, decoded_fenced = pcall(vim.json.decode, unfenced)
    if ok_fenced then
      return decoded_fenced
    end
  end

  return nil
end

local function parse_search_results(generated)
  local decoded = decode_json_maybe_fenced(generated)
  if type(decoded) ~= "table" then
    return nil, "invalid JSON"
  end

  local rows = decoded.results or decoded
  if type(rows) ~= "table" then
    return nil, "missing results array"
  end

  local items = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local filename = row.filename or row.path or row.file
      local lnum = tonumber(row.lnum or row.line)
      if type(filename) == "string" and filename ~= "" and lnum and lnum >= 1 then
        local col = tonumber(row.col) or 1
        if col < 1 then
          col = 1
        end

        local text = row.text or row.message or ""
        if type(text) ~= "string" then
          text = tostring(text)
        end
        text = vim.trim(text:gsub("\n", " "))

        table.insert(items, {
          filename = filename,
          lnum = math.floor(lnum),
          col = math.floor(col),
          text = text,
        })
      end
    end
  end

  return items
end

local function complete_task(task, generated)
  if task.mode == "search" then
    local items, parse_err = parse_search_results(generated)
    if not items then
      fail_task(task, "Invalid search response: " .. parse_err)
      return
    end

    state.latest_search_result = {
      task_id = task.id,
      prompt = task.prompt,
      items = items,
      created_at = os.time(),
    }
    update_task_history(task, {
      status = "completed_search_ready",
      read = false,
      search_items = items,
      generated = generated,
    })
    remove_task(task.id)
    notify("Search " .. task.id .. " results ready")
    return
  end

  if task.mode == "job" then
    local job_range = task_runtime_range(task)
    local isolated_dir = task.job_isolated_dir
    local source_cwd = task.job_source_cwd or vim.fn.getcwd()

    if not isolated_dir or isolated_dir == "" then
      fail_task(task, "Missing isolated workspace for job task")
      return
    end

    local job_tree_after, tree_err = write_workspace_tree(isolated_dir)
    if not job_tree_after then
      fail_task(task, "Failed to snapshot isolated workspace: " .. (tree_err or "unknown error"))
      return
    end

    local job_diff, job_diff_files = diff_workspace_trees(isolated_dir, task.job_tree_before, job_tree_after)
    if job_diff == nil or job_diff_files == nil then
      fail_task(task, "Failed to generate isolated diff for job task")
      return
    end

    local applied, apply_err = apply_job_patch(source_cwd, job_diff)
    if not applied then
      fail_task(task, "Failed to apply job patch atomically: " .. (apply_err or "unknown error"))
      return
    end

    refresh_unmodified_file_buffers()

    update_task_history(task, {
      status = "completed_job_done",
      read = false,
      generated = generated,
      job_diff = job_diff,
      job_diff_files = job_diff_files,
      job_tree_before = task.job_tree_before,
      job_tree_after = job_tree_after,
      job_source_cwd = source_cwd,
      range = job_range,
      bufnr = job_range and job_range.bufnr or nil,
      bufname = job_range and vim.api.nvim_buf_get_name(job_range.bufnr) or nil,
    })
    remove_task(task.id)
    notify("Task " .. task.id .. " job completed")
    return
  end

  if task.mode == "explain" then
    local explain_range = task_runtime_range(task)
    if not explain_range then
      fail_task(task, "Task range was lost")
      return
    end

    push_explain_result({
      task_id = task.id,
      prompt = task.prompt,
      text = generated,
      bufnr = explain_range.bufnr,
      bufname = vim.api.nvim_buf_get_name(explain_range.bufnr),
      range = explain_range,
      created_at = os.time(),
    })
    update_task_history(task, {
      status = "completed_explain_ready",
      read = false,
      explain_text = generated,
      generated = generated,
      range = explain_range,
      bufnr = explain_range.bufnr,
      bufname = vim.api.nvim_buf_get_name(explain_range.bufnr),
    })
    remove_task(task.id)
    notify("Task " .. task.id .. " explanation ready")
    if config.explain.auto_open then
      open_explain_result(get_latest_explain_result())
    end
    return
  end

  local apply_range = task_runtime_range(task)
  if not apply_range then
    fail_task(task, "Task range was lost")
    return
  end

  local current_snapshot = range_text(apply_range)
  if current_snapshot ~= task.snapshot then
    update_task_history(task, {
      status = "stale",
      read = false,
      error = "selection changed",
      range = apply_range,
      bufnr = apply_range.bufnr,
      bufname = vim.api.nvim_buf_get_name(apply_range.bufnr),
    })
    remove_task(task.id)
    notify("Task " .. task.id .. " stale: selection changed", vim.log.levels.WARN)
    return
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_text(
      apply_range.bufnr,
      apply_range.start_row,
      apply_range.start_col,
      apply_range.end_row,
      apply_range.end_col,
      split_lines(generated)
    )
  end)

  remove_task(task.id)

  if not ok then
    update_task_history(task, {
      status = "failed",
      read = false,
      error = tostring(err),
      range = apply_range,
      bufnr = apply_range.bufnr,
      bufname = vim.api.nvim_buf_get_name(apply_range.bufnr),
    })
    notify("Task " .. task.id .. " failed to apply: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  update_task_history(task, {
    status = "completed_applied",
    read = false,
    generated = generated,
    range = apply_range,
    bufnr = apply_range.bufnr,
    bufname = vim.api.nvim_buf_get_name(apply_range.bufnr),
  })

  notify("Task " .. task.id .. " completed and applied")
end

local function fail_task(task, reason, status)
  update_task_history(task, {
    status = status or "failed",
    read = false,
    error = reason,
  })
  remove_task(task.id)
  if status == "cancelled" then
    notify("Task " .. task.id .. " cancelled")
  else
    notify("Task " .. task.id .. " failed: " .. reason, vim.log.levels.ERROR)
  end
end

cancel_running_task = function(task)
  if not task or task.status ~= "running" then
    return
  end

  if task.proc and type(task.proc.kill) == "function" then
    pcall(task.proc.kill, task.proc, 15)
  end

  fail_task(task, "cancelled by user", "cancelled")
end

local function request_task(task)
  if type(config.claude_cmd) ~= "table" or #config.claude_cmd == 0 then
    fail_task(task, "Invalid claude_cmd config")
    return
  end

  local executable = config.claude_cmd[1]
  if type(executable) ~= "string" or executable == "" then
    fail_task(task, "Invalid Claude CLI executable")
    return
  end

  if vim.fn.executable(executable) ~= 1 then
    fail_task(task, "Claude CLI not found in $PATH: " .. executable)
    return
  end

  local prompt = build_prompt(task)

  local cmd = vim.deepcopy(config.claude_cmd)

  if task.mode == "job" then
    local permission_mode = config.job and config.job.permission_mode or "bypassPermissions"
    if type(permission_mode) == "string" and permission_mode ~= "" then
      table.insert(cmd, "--permission-mode")
      table.insert(cmd, permission_mode)
    end
  end

  table.insert(cmd, prompt)

  local system_opts = { text = true }
  if task.mode == "job" and task.job_isolated_dir and task.job_isolated_dir ~= "" then
    system_opts.cwd = task.job_isolated_dir
  end

  task.proc = vim.system(cmd, system_opts, function(obj)
    vim.schedule(function()
      if not state.tasks[task.id] then
        return
      end

      if obj.code ~= 0 then
        local reason = obj.stderr ~= "" and obj.stderr or ("claude exit code " .. obj.code)
        fail_task(task, reason)
        return
      end

      if not obj.stdout or obj.stdout == "" then
        fail_task(task, "No text in Claude Code response")
        return
      end

      complete_task(task, obj.stdout)
    end)
  end)
end

local function dispatch_task(mode)
  local bufnr = vim.api.nvim_get_current_buf()
  local range, range_err = normalize_visual_range(bufnr)
  if not range then
    notify(range_err, vim.log.levels.WARN)
    return
  end

  if selection_overlaps_running_task(range) then
    notify("Dispatch rejected: selection overlaps a running task", vim.log.levels.WARN)
    return
  end

  local function dispatch()
    vim.ui.input({ prompt = "AI prompt: " }, function(user_prompt)
      if not user_prompt or vim.trim(user_prompt) == "" then
        return
      end

      if selection_overlaps_running_task(range) then
        notify("Dispatch rejected: selection overlaps a running task", vim.log.levels.WARN)
        return
      end

      local task_id = state.next_id
      state.next_id = state.next_id + 1

      local task = {
        id = task_id,
        status = "running",
        mode = mode,
        range = range,
        snapshot = range_text(range),
        prompt = user_prompt,
      }

      if mode == "job" then
        task.job_source_cwd = vim.fn.getcwd()
      end

      state.tasks[task_id] = task
      ensure_task_history(task)
      local anchored, anchor_err = set_task_anchor(task)
      if not anchored then
        update_task_history(task, {
          status = "failed",
          read = false,
          error = anchor_err,
        })
        state.tasks[task_id] = nil
        notify("Task " .. task_id .. " failed: " .. anchor_err, vim.log.levels.ERROR)
        return
      end

      add_task_indicators(task)
      leave_visual_mode()
      if mode == "explain" then
        notify("Task " .. task_id .. " explain dispatched")
      elseif mode == "job" then
        notify("Task " .. task_id .. " job dispatched (preparing isolated workspace)")
      else
        notify("Task " .. task_id .. " dispatched")
      end

      if mode == "job" then
        create_isolated_job_workspace_async(task.job_source_cwd, function(isolated_dir, baseline_tree, job_err)
          local current = state.tasks[task_id]
          if not current then
            if isolated_dir and isolated_dir ~= "" then
              vim.fn.delete(isolated_dir, "rf")
            end
            return
          end

          if not isolated_dir then
            fail_task(current, job_err or "failed to prepare isolated job workspace")
            return
          end

          current.job_isolated_dir = isolated_dir
          current.job_tree_before = baseline_tree
          request_task(current)
        end)
      else
        request_task(task)
      end
    end)
  end

  dispatch()
end

function M.dispatch_inline_task()
  dispatch_task("inline")
end

function M.dispatch_job_task()
  dispatch_task("job")
end

function M.dispatch_explain_task()
  dispatch_task("explain")
end

function M.dispatch_search_task()
  vim.ui.input({ prompt = "Search prompt: " }, function(user_prompt)
    if not user_prompt or vim.trim(user_prompt) == "" then
      return
    end

    local task_id = state.next_id
    state.next_id = state.next_id + 1

    local task = {
      id = task_id,
      status = "running",
      mode = "search",
      prompt = user_prompt,
    }

    state.tasks[task_id] = task
    ensure_task_history(task)
    notify("Search " .. task_id .. " dispatched")
    request_task(task)
  end)
end

function M.open_latest_search_quickfix()
  local latest = state.latest_search_result
  if not latest then
    notify("No search results yet", vim.log.levels.WARN)
    return
  end
  open_search_result({ id = latest.task_id, search_items = latest.items })
end

function M.list_running_tasks()
  local lines = {}
  for id, task in pairs(state.tasks) do
    if task.status == "running" then
      if task.mode == "search" then
        table.insert(lines, string.format("#%d [search] %s", id, task.prompt))
      else
        local runtime_range = task_runtime_range(task)
        if not runtime_range then
          table.insert(lines, string.format("#%d [task] running", id))
        else
          local name = vim.api.nvim_buf_get_name(runtime_range.bufnr)
          if name == "" then
            name = "[No Name]"
          else
            name = vim.fn.fnamemodify(name, ":~:.")
          end

          table.insert(
            lines,
            string.format(
              "#%d %s (%d:%d -> %d:%d)",
              id,
              name,
              runtime_range.start_row + 1,
              runtime_range.start_col + 1,
              runtime_range.end_row + 1,
              runtime_range.end_col + 1
            )
          )
        end
      end
    end
  end

  if #lines == 0 then
    notify("No running tasks")
    return
  end

  table.sort(lines)
  notify("Running tasks:\n" .. table.concat(lines, "\n"))
end

function M.open_latest_explain_result()
  open_explain_result(get_latest_explain_result())
end

function M.open_explain_result_list()
  open_explain_picker()
end

function M.open_task_browser(filters)
  open_task_browser(filters)
end

function M.open_task_browser_for_key(lhs)
  local presets = config.keymaps and config.keymaps.task_browser or {}
  open_task_browser(presets[lhs] or {})
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  set_default_highlights()

  if config.keymaps and config.keymaps.enabled then
    vim.keymap.set("x", config.keymaps.inline, M.dispatch_inline_task, {
      desc = "async-ai: dispatch inline task",
      silent = true,
    })

    if config.keymaps.job and config.keymaps.job ~= "" then
      vim.keymap.set("x", config.keymaps.job, M.dispatch_job_task, {
        desc = "async-ai: dispatch job task",
        silent = true,
      })
    end

    vim.keymap.set("x", config.keymaps.explain_dispatch, M.dispatch_explain_task, {
      desc = "async-ai: dispatch explain task",
      silent = true,
    })

    vim.keymap.set("n", config.keymaps.explain_open, M.open_explain_result_list, {
      desc = "async-ai: open explain result list",
      silent = true,
    })

    vim.keymap.set("n", config.keymaps.search_dispatch, M.dispatch_search_task, {
      desc = "async-ai: dispatch search task",
      silent = true,
    })

    vim.keymap.set("n", config.keymaps.search_open, M.open_latest_search_quickfix, {
      desc = "async-ai: open latest search quickfix",
      silent = true,
    })

    if config.keymaps.list and config.keymaps.list ~= "" then
      vim.keymap.set("n", config.keymaps.list, M.list_running_tasks, {
        desc = "async-ai: list running tasks",
        silent = true,
      })
    end

    local browser_maps = config.keymaps.task_browser or {}
    for lhs, filters in pairs(browser_maps) do
      local default_filters = vim.deepcopy(filters)
      vim.keymap.set("n", lhs, function()
        open_task_browser(default_filters)
      end, {
        desc = "async-ai: open task browser",
        silent = true,
      })
    end
  end

  if not state.commands_registered then
    vim.api.nvim_create_user_command("AsyncAIDispatch", M.dispatch_inline_task, {
      desc = "Dispatch async AI task for current visual selection",
    })

    vim.api.nvim_create_user_command("AsyncAIList", M.list_running_tasks, {
      desc = "List running async AI tasks",
    })

    vim.api.nvim_create_user_command("AsyncAIExplain", M.dispatch_explain_task, {
      desc = "Dispatch explain task for current visual selection",
      range = true,
    })

    vim.api.nvim_create_user_command("AsyncAIJob", M.dispatch_job_task, {
      desc = "Dispatch async AI job task from current visual selection",
      range = true,
    })

    vim.api.nvim_create_user_command("AsyncAIExplainLast", M.open_latest_explain_result, {
      desc = "Open latest explain result",
    })

    vim.api.nvim_create_user_command("AsyncAIExplainList", M.open_explain_result_list, {
      desc = "Open picker for explain results",
    })

    vim.api.nvim_create_user_command("AsyncAISearch", M.dispatch_search_task, {
      desc = "Dispatch async AI search task",
    })

    vim.api.nvim_create_user_command("AsyncAISearchQuickfix", M.open_latest_search_quickfix, {
      desc = "Open latest async AI search results in quickfix",
    })

    vim.api.nvim_create_user_command("AsyncAITasks", function()
      open_task_browser(config.keymaps and config.keymaps.task_browser and config.keymaps.task_browser["<leader>al"] or {})
    end, {
      desc = "Open async AI task browser",
    })

    state.commands_registered = true
  end
end

return M
