local M = {}

local DETAIL_NAMES = { compact = "Compact", standard = "Standard", ["first-principles"] = "First-principles" }
local BACKEND_FLAG_PAIRS = {
  { "backend", "--backend" },
  { "model", "--model" },
  { "mlx_runner", "--mlx-runner" },
  { "mlx_command", "--mlx-command" },
}

local defaults = {
  command = { "rexplain" },
  -- Rex routes physical Shift+Cmd+E to F13 for Neovim. Never map <D-S-e>.
  keymap = "<F13>",
  backend = nil,
  model = nil,
  mlx_runner = nil,
  mlx_command = nil,
}

local state = { active_job = nil, active_win = nil, active_buf = nil }

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_badge(value)
  local cleaned = type(value) == "string" and trim(value) or ""
  return cleaned ~= "" and cleaned or "On-device"
end

local function clear_model_overrides()
  defaults.backend, defaults.model, defaults.mlx_runner, defaults.mlx_command = nil, nil, nil, nil
end

M._deps = {
  jobstart = function(cmd, opts) return vim.fn.jobstart(cmd, opts) end,
  jobstop = function(job) return vim.fn.jobstop(job) end,
  chansend = function(job, data) return vim.fn.chansend(job, data) end,
  chanclose = function(job, stream) return vim.fn.chanclose(job, stream) end,
  ui_select = function(items, opts, on_choice) vim.ui.select(items, opts, on_choice) end,
  ui_input = function(opts, on_confirm) vim.ui.input(opts, on_confirm) end,
  notify = function(msg, level) vim.notify(msg, level) end,
  system = function(argv)
    if vim.system then
      local obj = vim.system(argv, { text = true }):wait()
      return { code = obj.code or 1, stdout = obj.stdout or "", stderr = obj.stderr or "" }
    end
    local out = vim.fn.system(argv)
    return { code = vim.v.shell_error, stdout = out or "", stderr = "" }
  end,
}

function M.backend_cli_args()
  local args = {}
  for _, pair in ipairs(BACKEND_FLAG_PAIRS) do
    local val = defaults[pair[1]]
    if type(val) == "string" and trim(val) ~= "" then
      vim.list_extend(args, { pair[2], trim(val) })
    end
  end
  return args
end

local function run_cli_json(sub_args)
  local cmd = vim.list_extend(vim.deepcopy(defaults.command), sub_args)
  local res = M._deps.system(cmd)
  if type(res) ~= "table" or res.code ~= 0 then
    return nil, type(res) == "table" and trim(res.stderr ~= "" and res.stderr or res.stdout) or "Command failed"
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout or "")
  if not ok or type(decoded) ~= "table" then return nil, "Failed to decode JSON response from rexplain" end
  return decoded, nil
end

function M.query_config_show()
  local decoded = run_cli_json(vim.list_extend({ "config", "show", "--json" }, M.backend_cli_args()))
  if type(decoded) == "table" and type(decoded.display_badge) == "string" and decoded.display_badge ~= "" then
    return decoded
  end
  return { backend = "fmf", display_badge = "On-device", active_model = "Apple Foundation Model" }
end

function M.query_config_models()
  return run_cli_json(vim.list_extend({ "config", "models", "--json" }, M.backend_cli_args()))
end

function M.get_selection()
  local mode = vim.fn.mode()
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  if not ok or not lines then return nil, "Could not read the Visual selection." end

  local text = table.concat(lines, "\n")
  if trim(text) == "" then return nil, "The Visual selection is empty." end

  return { text = text, visual_mode = mode }
end

local function stop_job(job)
  if not job or job <= 0 then return end
  pcall(M._deps.chansend, job, vim.json.encode({ cmd = "close" }) .. "\n")
  pcall(M._deps.chanclose, job, "stdin")
  pcall(M._deps.jobstop, job)
end

local function close_active_window_and_worker()
  local job = state.active_job
  state.active_job = nil
  stop_job(job)
  if state.active_win and vim.api.nvim_win_is_valid(state.active_win) then
    local w = state.active_win
    state.active_win = nil
    pcall(vim.api.nvim_win_close, w, true)
  end
  state.active_buf = nil
end

local function open_explanation_window(detail, badge)
  close_active_window_and_worker()

  local active_badge = normalize_badge(badge)
  local detail_name = DETAIL_NAMES[detail] or "Compact"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = "nofile", "wipe", false, "markdown"

  local width = math.min(100, math.max(50, vim.o.columns - 8))
  local height = math.min(30, math.max(10, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    title = string.format(" Rexplain · %s · %s ", active_badge, detail_name),
    title_pos = "center",
  })

  vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].conceallevel = true, true, 2
  state.active_win, state.active_buf = win, buf

  local function render(body_text)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    -- Keep line 1 empty to separate body text from the floating border title.
    local lines = { "" }
    if body_text and body_text ~= "" then
      vim.list_extend(lines, vim.split(body_text, "\n", { plain = true }))
    else
      lines[#lines + 1] = "*Preparing (" .. active_badge .. " · " .. detail_name .. ")…*"
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  local function update_title(new_badge)
    if type(new_badge) ~= "string" or trim(new_badge) == "" then return end
    active_badge = trim(new_badge)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_config, win, {
        title = string.format(" Rexplain · %s · %s ", active_badge, detail_name),
        title_pos = "center",
      })
    end
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local job = state.active_job
      state.active_job, state.active_win, state.active_buf = nil, nil, nil
      stop_job(job)
    end,
  })

  vim.keymap.set("n", "q", close_active_window_and_worker, { buffer = buf, silent = true, desc = "Close Rexplain" })
  vim.keymap.set("n", "<Esc>", close_active_window_and_worker, { buffer = buf, silent = true, desc = "Close Rexplain" })

  render("")
  return { win = win, buf = buf, render = render, update_title = update_title }
end

function M.run_picker_flow(item)
  local badge = normalize_badge(M.query_config_show().display_badge)
  local accum, stdout_buf, stderr_buf = "", "", ""
  local worker_cmd = vim.list_extend(vim.deepcopy(defaults.command), { "worker" })
  vim.list_extend(worker_cmd, M.backend_cli_args())

  local active_view_ref = { view = nil }
  local job = M._deps.jobstart(worker_cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data or not active_view_ref.view then return end
      stdout_buf = stdout_buf .. table.concat(data, "\n")
      while true do
        local nl = stdout_buf:find("\n", 1, true)
        if not nl then break end
        local line = stdout_buf:sub(1, nl - 1)
        stdout_buf = stdout_buf:sub(nl + 1)
        if trim(line) ~= "" then
          local ok, event = pcall(vim.json.decode, line)
          if ok and type(event) == "table" then
            vim.schedule(function()
              local v = active_view_ref.view
              if not v then return end
              if event.type == "started" then
                if type(event.model_label) == "string" and event.model_label ~= "" then v.update_title(event.model_label) end
                if type(event.hint) == "string" and event.hint ~= "" then M._deps.notify(event.hint, vim.log.levels.INFO) end
              elseif event.type == "delta" and event.text then
                accum = accum .. event.text
                v.render(accum)
              elseif event.type == "replace" then
                accum = event.text or ""
                v.render(accum)
              elseif event.type == "completed" then
                v.render(accum)
              elseif event.type == "cancelled" then
                v.render(accum ~= "" and (accum .. "\n\n*[Cancelled]*") or "*[Cancelled]*")
              elseif event.type == "error" then
                v.render("**Rexplain error (" .. tostring(event.error_code or "error") .. ")**\n\n" .. tostring(event.error or "Unknown model error"))
              end
            end)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then return end
      local chunk = table.concat(data, "\n")
      if trim(chunk) ~= "" then stderr_buf = stderr_buf .. chunk end
    end,
    on_exit = function(j, code)
      if state.active_job == j then state.active_job = nil end
      if code ~= 0 and accum == "" and trim(stderr_buf) ~= "" and active_view_ref.view then
        vim.schedule(function() active_view_ref.view.render("**Rexplain error**\n\n" .. stderr_buf) end)
      end
    end,
  })

  if job and job > 0 then
    M._deps.chansend(job, vim.json.encode({ cmd = "prepare" }) .. "\n")
  end

  local detail_items = {
    { id = "compact", label = "Compact — 3–5 lines · Core definition, mechanism, and takeaway" },
    { id = "standard", label = "Standard — 6–10 steps · Key terms, mechanism, and consequences" },
    { id = "first-principles", label = "First-principles — Up to 14–22 steps · Axioms, definitions, full derivation, edge cases, and example" },
  }

  M._deps.ui_select(detail_items, {
    prompt = "Rexplain · " .. badge .. " · Choose effort:",
    format_item = function(d) return d.label end,
  }, function(picked)
    if not picked then
      stop_job(job)
      return
    end

    local v = open_explanation_window(picked.id, badge)
    if not job or job <= 0 then
      v.render("**Could not start `rexplain worker`.**")
      return
    end

    active_view_ref.view = v
    state.active_job = job
    M._deps.chansend(job, vim.json.encode({
      cmd = "explain",
      detail = picked.id,
      text = item.text,
    }) .. "\n")
    pcall(M._deps.chanclose, job, "stdin")
  end)
end

function M.select_model()
  local info, err = M.query_config_models()
  if not info then
    M._deps.notify("Could not inspect Rexplain models: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local fmf_active = info.active_backend == "fmf" and "[Active] " or ""
  local fmf_state = info.fmf_available and "On-device" or ("Unavailable: " .. tostring(info.fmf_detail or "unknown"))
  local items = {
    { id = "__fmf__", label = string.format("%sApple On-device (FMF) — %s", fmf_active, fmf_state) },
  }

  for _, cached in ipairs(info.cached_models or {}) do
    if type(cached) == "table" and type(cached.id) == "string" and cached.id ~= "" then
      local is_active = (info.active_backend == "mlx" and info.active_model == cached.id) and "[Active] " or ""
      items[#items + 1] = {
        id = "mlx:" .. cached.id,
        label = string.format("%sLocal MLX · %s (%s)", is_active, cached.id, tostring(cached.suggested_runner or "auto")),
        model_id = cached.id,
      }
    end
  end

  items[#items + 1] = { id = "__custom_mlx__", label = "Custom local MLX model (Hugging Face repo or local path)…" }

  M._deps.ui_select(items, {
    prompt = "Rexplain · Select Model (current: " .. tostring(info.display_badge or "On-device") .. "):",
    format_item = function(entry) return entry.label end,
  }, function(choice)
    if not choice then return end

    if choice.id == "__fmf__" then
      local res = M._deps.system(vim.list_extend(vim.deepcopy(defaults.command), { "config", "set-fmf" }))
      if type(res) == "table" and res.code == 0 then
        clear_model_overrides()
        M._deps.notify("Rexplain default set to Apple On-device (FMF).", vim.log.levels.INFO)
      else
        M._deps.notify("Failed to switch Rexplain model: " .. tostring(res and res.stderr or "error"), vim.log.levels.ERROR)
      end
      return
    end

    local function persist_mlx(model_id)
      model_id = trim(model_id)
      if model_id == "" then return end
      local res = M._deps.system(vim.list_extend(vim.deepcopy(defaults.command), { "config", "set-mlx", model_id }))
      if type(res) == "table" and res.code == 0 then
        clear_model_overrides()
        M._deps.notify("Rexplain default set to Local MLX: " .. model_id, vim.log.levels.INFO)
      else
        M._deps.notify("Failed to set MLX model: " .. tostring(res and res.stderr or "error"), vim.log.levels.ERROR)
      end
    end

    if choice.id == "__custom_mlx__" then
      M._deps.ui_input({ prompt = "Local MLX model (HF repo or path): " }, function(typed)
        if typed and trim(typed) ~= "" then persist_mlx(typed) end
      end)
    elseif choice.model_id then
      persist_mlx(choice.model_id)
    end
  end)

  return true
end

function M.explain_visual()
  local item, err = M.get_selection()
  if not item then
    M._deps.notify(err, vim.log.levels.WARN)
    return
  end
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  pcall(vim.api.nvim_feedkeys, esc, "nx", false)
  M.run_picker_flow(item)
end

function M.get_state() return state end
function M.get_defaults() return defaults end

function M.setup(opts)
  defaults = vim.tbl_deep_extend("force", defaults, opts or {})
  vim.keymap.set("x", defaults.keymap, M.explain_visual, { desc = "Rexplain: explain Visual selection", silent = true })
  vim.api.nvim_create_user_command("RexplainModel", function() M.select_model() end, {
    desc = "Rexplain: Switch default model (Apple On-device FMF or local MLX)",
  })
end

return M
