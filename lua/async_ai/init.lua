local M = {}

local state = {
  next_id = 1,
  tasks = {},
  commands_registered = false,
  ui = {
    ns = nil,
    timer = nil,
    spinner_index = 1,
  },
}

local config = {
  api_url = "https://api.anthropic.com/v1/messages",
  api_key_env = "ANTHROPIC_API_KEY",
  model = "claude-sonnet-4-6",
  max_tokens = 1024,
  temperature = 0,
  keymaps = {
    enabled = true,
    inline = "<leader>ai",
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
    if task.status == "running" then
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
    if task.status == "running" then
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

local function extract_anthropic_text(decoded)
  if type(decoded) ~= "table" or type(decoded.content) ~= "table" then
    return nil
  end

  local chunks = {}
  for _, block in ipairs(decoded.content) do
    if block.type == "text" and type(block.text) == "string" then
      table.insert(chunks, block.text)
    end
  end

  if #chunks == 0 then
    return nil
  end

  return table.concat(chunks, "\n")
end

local function remove_task(task_id)
  local task = state.tasks[task_id]
  clear_task_indicators(task)
  state.tasks[task_id] = nil

  if not has_running_tasks() then
    stop_spinner_timer()
  end
end

local function complete_task(task, generated)
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
  local api_key = vim.env[config.api_key_env]
  if not api_key or api_key == "" then
    fail_task(task, "Missing " .. config.api_key_env)
    return
  end

  local prompt = table.concat({
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

  local payload = vim.json.encode({
    model = config.model,
    max_tokens = config.max_tokens,
    temperature = config.temperature,
    messages = {
      {
        role = "user",
        content = {
          {
            type = "text",
            text = prompt,
          },
        },
      },
    },
  })

  vim.system({
    "curl",
    "-sS",
    "-X",
    "POST",
    config.api_url,
    "-H",
    "content-type: application/json",
    "-H",
    "x-api-key: " .. api_key,
    "-H",
    "anthropic-version: 2023-06-01",
    "-d",
    payload,
  }, { text = true }, function(obj)
    vim.schedule(function()
      if not state.tasks[task.id] then
        return
      end

      if obj.code ~= 0 then
        local reason = obj.stderr ~= "" and obj.stderr or ("curl exit code " .. obj.code)
        fail_task(task, reason)
        return
      end

      local ok_decode, decoded = pcall(vim.json.decode, obj.stdout)
      if not ok_decode then
        fail_task(task, "Invalid JSON response")
        return
      end

      local text = extract_anthropic_text(decoded)
      if not text then
        if decoded.error and decoded.error.message then
          fail_task(task, decoded.error.message)
        else
          fail_task(task, "No text in API response")
        end
        return
      end

      complete_task(task, text)
    end)
  end)
end

function M.dispatch_inline_task()
  local bufnr = vim.api.nvim_get_current_buf()
  local range, range_err = normalize_visual_range(bufnr)
  if not range then
    notify(range_err, vim.log.levels.WARN)
    return
  end

  for _, existing in pairs(state.tasks) do
    if existing.status == "running" and ranges_overlap(existing.range, range) then
      notify("Dispatch rejected: selection overlaps a running task", vim.log.levels.WARN)
      return
    end
  end

  vim.ui.input({ prompt = "AI prompt: " }, function(user_prompt)
    if not user_prompt or vim.trim(user_prompt) == "" then
      return
    end

    local task_id = state.next_id
    state.next_id = state.next_id + 1

    local task = {
      id = task_id,
      status = "running",
      range = range,
      snapshot = range_text(range),
      prompt = user_prompt,
    }

    state.tasks[task_id] = task
    add_task_indicators(task)
    leave_visual_mode()
    notify("Task " .. task_id .. " dispatched")
    request_task(task)
  end)
end

function M.list_running_tasks()
  local lines = {}
  for id, task in pairs(state.tasks) do
    if task.status == "running" then
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
    end
  end

  if #lines == 0 then
    notify("No running tasks")
    return
  end

  table.sort(lines)
  notify("Running tasks:\n" .. table.concat(lines, "\n"))
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  set_default_highlights()

  if config.keymaps and config.keymaps.enabled then
    vim.keymap.set("x", config.keymaps.inline, M.dispatch_inline_task, {
      desc = "async-ai: dispatch inline task",
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

    state.commands_registered = true
  end
end

return M
