local M = {}

local state = {
  next_id = 1,
  tasks = {},
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
  keymaps = {
    enabled = true,
    inline = "<leader>ai",
    explain_dispatch = "<leader>ae",
    explain_open = "<leader>ae",
    search_dispatch = "<leader>as",
    search_open = "<leader>aq",
    list = "<leader>al",
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
}

local inline_context_options = {
  {
    key = "none",
    label = "No extra context",
  },
  {
    key = "whole_file",
    label = "Whole file",
  },
}

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

local function get_namespace()
  if not state.ui.ns then
    state.ui.ns = vim.api.nvim_create_namespace("async_ai")
  end
  return state.ui.ns
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

  if not vim.api.nvim_buf_is_valid(task.range.bufnr) then
    return
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, task.range.bufnr, get_namespace(), task.range.start_row, 0, {
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

  if not task.range then
    return
  end

  if not config.ui or not config.ui.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(task.range.bufnr) then
    return
  end

  local ns = get_namespace()
  if task.ui_range_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, task.range.bufnr, ns, task.ui_range_mark_id)
    task.ui_range_mark_id = nil
  end

  if task.ui_label_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, task.range.bufnr, ns, task.ui_label_mark_id)
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

  if not vim.api.nvim_buf_is_valid(task.range.bufnr) then
    return
  end

  local ok, range_mark_id = pcall(vim.api.nvim_buf_set_extmark, task.range.bufnr, get_namespace(), task.range.start_row, task.range.start_col, {
    end_row = task.range.end_row,
    end_col = task.range.end_col,
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

local function buffer_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

local function context_from_option(option, bufnr)
  local selected = option or inline_context_options[1]
  local context = {
    key = selected.key,
    label = selected.label,
  }

  if selected.key == "whole_file" then
    context.text = buffer_text(bufnr)
  end

  return context
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

  local context = task.context or context_from_option(nil, task.range.bufnr)

  if task.mode == "explain" then
    if context.key == "whole_file" then
      return table.concat({
        "You are explaining a selected code scope from Neovim.",
        "Respond with a concise, helpful multiline explanation.",
        "Use read-only whole-file context for additional understanding.",
        "",
        "Instruction:",
        task.prompt,
        "",
        "Selection:",
        task.snapshot,
        "",
        "Read-only context (whole file):",
        context.text or "",
      }, "\n")
    end

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

  if context.key == "whole_file" then
    return table.concat({
      "You are editing a scoped selection in Neovim.",
      "Apply the user's instruction to the provided selection and return only replacement text.",
      "Do not include markdown fences or explanations.",
      "The whole-file context is read-only and must not be rewritten directly.",
      "",
      "Instruction:",
      task.prompt,
      "",
      "Writable selection:",
      task.snapshot,
      "",
      "Read-only context (whole file):",
      context.text or "",
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
    if existing.status == "running" and ranges_overlap(existing.range, range) then
      return true
    end
  end
  return false
end

local function remove_task(task_id)
  local task = state.tasks[task_id]
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
    remove_task(task.id)
    notify("Search " .. task.id .. " results ready")
    return
  end

  if task.mode == "explain" then
    push_explain_result({
      task_id = task.id,
      prompt = task.prompt,
      text = generated,
      bufnr = task.range.bufnr,
      bufname = vim.api.nvim_buf_get_name(task.range.bufnr),
      range = task.range,
      created_at = os.time(),
    })
    remove_task(task.id)
    notify("Task " .. task.id .. " explanation ready")
    if config.explain.auto_open then
      open_explain_result(get_latest_explain_result())
    end
    return
  end

  local current_snapshot = range_text(task.range)
  if current_snapshot ~= task.snapshot then
    remove_task(task.id)
    notify("Task " .. task.id .. " stale: selection changed", vim.log.levels.WARN)
    return
  end

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_text(
      task.range.bufnr,
      task.range.start_row,
      task.range.start_col,
      task.range.end_row,
      task.range.end_col,
      split_lines(generated)
    )
  end)

  remove_task(task.id)

  if not ok then
    notify("Task " .. task.id .. " failed to apply: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  notify("Task " .. task.id .. " completed and applied")
end

local function fail_task(task, reason)
  remove_task(task.id)
  notify("Task " .. task.id .. " failed: " .. reason, vim.log.levels.ERROR)
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
  table.insert(cmd, prompt)

  vim.system(cmd, { text = true }, function(obj)
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

  local function dispatch_with_context(context)
    vim.ui.input({ prompt = "AI prompt (" .. context.label .. "): " }, function(user_prompt)
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
        context = context,
      }

      state.tasks[task_id] = task
      add_task_indicators(task)
      leave_visual_mode()
      if mode == "explain" then
        notify("Task " .. task_id .. " explain dispatched (" .. context.label .. ")")
      else
        notify("Task " .. task_id .. " dispatched (" .. context.label .. ")")
      end
      request_task(task)
    end)
  end

  vim.ui.select(inline_context_options, {
    prompt = "Context scope",
    format_item = function(item)
      return item.label
    end,
  }, function(option)
    if not option then
      return
    end

    dispatch_with_context(context_from_option(option, bufnr))
  end)
end

function M.dispatch_inline_task()
  dispatch_task("inline")
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

  vim.fn.setqflist({}, " ", {
    title = string.format("Async AI Search #%d", latest.task_id),
    items = latest.items,
  })
  vim.cmd("copen")
end

function M.list_running_tasks()
  local lines = {}
  for id, task in pairs(state.tasks) do
    if task.status == "running" then
      if task.mode == "search" then
        table.insert(lines, string.format("#%d [search] %s", id, task.prompt))
      elseif task.range then
        local name = vim.api.nvim_buf_get_name(task.range.bufnr)
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
            task.range.start_row + 1,
            task.range.start_col + 1,
            task.range.end_row + 1,
            task.range.end_col + 1
          )
        )
      else
        table.insert(lines, string.format("#%d [task] running", id))
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

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  set_default_highlights()

  if config.keymaps and config.keymaps.enabled then
    vim.keymap.set("x", config.keymaps.inline, M.dispatch_inline_task, {
      desc = "async-ai: dispatch inline task",
      silent = true,
    })

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

    vim.keymap.set("n", config.keymaps.list, M.list_running_tasks, {
      desc = "async-ai: list running tasks",
      silent = true,
    })
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

    state.commands_registered = true
  end
end

return M
