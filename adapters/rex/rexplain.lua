local M = {}

local TERMINAL = "com.superlogical.terminal"
local DEFAULT_KEY = "shift+cmd+e"

local EDITORS = { nvim = true, vim = true, vi = true, view = true, vimdiff = true, nvimdiff = true }
local MULTIPLEXERS = { tmux = true, screen = true }
local DETAIL_NAMES = { compact = "Compact", standard = "Standard", ["first-principles"] = "First-principles" }
local BACKEND_FLAG_PAIRS = {
  { "backend", "--backend" },
  { "model", "--model" },
  { "mlx_runner", "--mlx-runner" },
  { "mlx_command", "--mlx-command" },
}

local state = {
  last_layer_id = nil,
  config_overrides = {},
}

local function log(level, message)
  rex.log(level or "info", "Rexplain: " .. tostring(message))
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_badge(value)
  local cleaned = type(value) == "string" and trim(value) or ""
  return cleaned ~= "" and cleaned or "On-device"
end

local function clear_model_overrides()
  local ov = state.config_overrides
  if type(ov) ~= "table" then return end
  ov.backend, ov.model, ov.mlx_runner, ov.mlx_command = nil, nil, nil, nil
end

local function preview_text(text, max_len)
  local single = trim(text):gsub("%s+", " ")
  local limit = max_len or 46
  return #single <= limit and single or (single:sub(1, limit - 1) .. "…")
end

local function extend_list(dst, src)
  for _, v in ipairs(src or {}) do
    dst[#dst + 1] = v
  end
  return dst
end

function M.setup(opts)
  opts = type(opts) == "table" and opts or {}
  state.config_overrides = {
    backend = opts.backend,
    model = opts.model,
    mlx_runner = opts.mlx_runner,
    mlx_command = opts.mlx_command,
    executable = opts.executable,
  }
end

function M.executable_path()
  local ov_exe = state.config_overrides and state.config_overrides.executable
  if type(ov_exe) == "string" and ov_exe ~= "" then return ov_exe end
  local configured = os.getenv("REXPLAIN_BIN")
  if configured and configured ~= "" then return configured end
  return (os.getenv("HOME") or "") .. "/.local/bin/rexplain"
end

function M.backend_cli_args()
  local args = {}
  local ov = state.config_overrides or {}
  for _, pair in ipairs(BACKEND_FLAG_PAIRS) do
    local val = ov[pair[1]]
    if type(val) == "string" and trim(val) ~= "" then
      args[#args + 1] = pair[2]
      args[#args + 1] = trim(val)
    end
  end
  return args
end

local function run_cli_json(sub_argv, timeout_secs)
  local argv = extend_list({ M.executable_path() }, sub_argv)
  local result, err = rex.exec(argv, { timeout = timeout_secs or 3 })
  if not result then return nil, err or "Failed to execute rexplain." end
  if not result.ok then return nil, trim(result.stderr or result.stdout or "rexplain exited with error") end
  if type(rex.json) ~= "table" or type(rex.json.decode) ~= "function" then
    return nil, "rex.json.decode is unavailable"
  end
  local ok, decoded = pcall(rex.json.decode, result.stdout or "")
  if not ok or type(decoded) ~= "table" then return nil, "Failed to parse JSON from rexplain" end
  return decoded, nil
end

function M.query_config_show()
  local decoded = run_cli_json(extend_list({ "config", "show", "--json" }, M.backend_cli_args()), 3)
  if type(decoded) == "table" and type(decoded.display_badge) == "string" and decoded.display_badge ~= "" then
    return decoded
  end
  return { backend = "fmf", display_badge = "On-device", active_model = "Apple Foundation Model" }
end

function M.query_config_models()
  return run_cli_json(extend_list({ "config", "models", "--json" }, M.backend_cli_args()), 4)
end

function M.find_rex_bin()
  local configured = os.getenv("REX_BIN")
  if configured and configured ~= "" then return configured end
  local home = os.getenv("HOME") or ""
  for _, path in ipairs({
    home .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
    "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
  }) do
    local f = io.open(path, "rb")
    if f then
      f:close()
      return path
    end
  end
  return "rex"
end

local function resolve_session_id(ctx)
  if type(ctx) == "table" and type(ctx.session_id) == "string" and ctx.session_id ~= "" then return ctx.session_id end
  if type(rex.session_id) == "string" and rex.session_id ~= "" then return rex.session_id end
  if type(rex.session) == "table" and type(rex.session.view) == "function" then
    local ok, view = pcall(rex.session.view)
    if ok and type(view) == "table" and type(view.session_id) == "string" and view.session_id ~= "" then
      return view.session_id
    end
  end
  return nil
end

local function process_name(proc)
  if type(proc) ~= "table" then return nil end
  local value = proc.name or proc.executable or proc.command or proc.path or proc.argv0
  if type(value) ~= "string" then return nil end
  value = trim(value):match("^([^%s]+)") or value
  return (value:match("([^/]+)$") or value):lower()
end

function M.classify_snapshot(snapshot)
  if type(snapshot) ~= "table" then return nil, "Missing process snapshot" end
  local candidates = { snapshot.foreground, snapshot.child }
  if type(snapshot.ancestors) == "table" then
    extend_list(candidates, snapshot.ancestors)
  end

  local has_mux = false
  for _, proc in ipairs(candidates) do
    local name = process_name(proc)
    if name then
      if EDITORS[name] then return "editor", nil end
      if MULTIPLEXERS[name] then has_mux = true end
    end
  end
  return has_mux and "multiplexer" or "terminal", nil
end

local function classify_focused_process()
  local snapshot, err = rex.block.call(TERMINAL, "process", {})
  if not snapshot then return nil, nil, err end
  local route = M.classify_snapshot(snapshot)
  return route, snapshot, nil
end

function M.read_clipboard()
  local result, err = rex.exec({ "/usr/bin/pbpaste" }, { timeout = 2 })
  if not result then return nil, err end
  if not result.ok then return nil, result.stderr end
  local value = result.stdout or ""
  if trim(value) == "" then return nil, "Clipboard is empty." end
  return value, nil
end

local function make_request_dir()
  local res, err = rex.exec({ "/usr/bin/mktemp", "-d", "/tmp/rexplain-XXXXXX" }, { timeout = 2 })
  if not res or not res.ok then return nil, err or (res and res.stderr) or "Could not create temporary request directory." end
  local dir = trim(res.stdout)
  if dir == "" then return nil, "Empty temporary directory path." end
  rex.exec({ "/bin/chmod", "700", dir }, { timeout = 2 })
  return dir, nil
end

local function write_private_file(path, content)
  local file, err = io.open(path, "wb")
  if not file then return false, err end
  local ok, write_err = file:write(content)
  file:close()
  if not ok then
    os.remove(path)
    return false, write_err
  end
  rex.exec({ "/bin/chmod", "600", path }, { timeout = 2 })
  return true, nil
end

local function cleanup_request_dir(dir)
  if dir and dir ~= "" then rex.exec({ "/bin/rm", "-rf", dir }, { timeout = 2 }) end
end

local function abort_worker(worker, temp_dir)
  if worker then pcall(function() worker:kill("SIGTERM") end) end
  cleanup_request_dir(temp_dir)
end

function M.pick_effort(source_label, model_badge)
  local choice, why = rex.ui.pick{
    title = "Rexplain · " .. normalize_badge(model_badge),
    placeholder = source_label .. " · Choose effort",
    items = {
      { id = "compact", title = "Compact", subtitle = "3–5 lines · Core definition, mechanism, and takeaway", icon = "tag" },
      { id = "standard", title = "Standard", subtitle = "6–10 steps · Key terms, mechanism, and consequences", icon = "document" },
      { id = "first-principles", title = "First-principles", subtitle = "Up to 14–22 steps · Axioms, definitions, full derivation, edge cases, and example", icon = "code" },
    },
  }
  if choice == nil then return nil, why or "cancelled" end
  return choice, nil
end

local function schedule_layer_focus(sid, layer_id, block_id)
  -- `rex.after` is unavailable in init.lua; focus after palette dismissal via detached helper.
  if not layer_id and not block_id then return end
  local focus_payload = rex.json.encode({ session_id = sid, layer_id = layer_id, state = "normal", focus = true })
  rex.exec.start({
    "/bin/sh", "-c",
    'sleep 0.25 && ("$1" api call session.set_layer_state "$2" >/dev/null 2>&1 || "$1" focus -s "$3" "$4" >/dev/null 2>&1)',
    "_", M.find_rex_bin(), focus_payload or "{}", sid or "", block_id or "",
  }, { detach = true })
end

local function launch_worker_and_layer(opts)
  local exe = M.executable_path()
  local detail, worker, temp_dir = opts.detail, opts.worker, opts.temp_dir
  local badge = normalize_badge(opts.model_badge)
  local sid = resolve_session_id(opts.ctx)

  local encoded, enc_err = rex.json.encode({
    cmd = "explain",
    detail = detail,
    text = opts.text,
  })
  if not encoded then
    abort_worker(worker, temp_dir)
    return nil, enc_err or "Failed to encode worker command."
  end

  local wrote, write_err = worker:write(encoded .. "\n")
  if not wrote then
    abort_worker(worker, temp_dir)
    return nil, write_err or "Failed to send command to Rexplain worker."
  end
  worker:close_stdin()

  if state.last_layer_id then
    pcall(rex.session.close_layer, { session_id = sid, layer_id = state.last_layer_id })
    state.last_layer_id = nil
  end

  local block_label = "Rexplain · " .. badge .. " · " .. (DETAIL_NAMES[detail] or "Compact")
  local layer_spec = {
    bounds = { 0.12, 0.10, 0.76, 0.80 },
    focus = false,
    layout = rex.layout.block{
      flavor = TERMINAL .. ".shell",
      label = block_label,
      options = {
        command = {
          exe, "view",
          "--stream-file", opts.stream_path,
          "--worker-pid", tostring(worker.pid),
          "--detail", detail,
          "--label", badge,
          "--cleanup-dir", temp_dir,
        },
        shell = "none",
        exit = { on_completion = true },
      },
    },
  }
  if sid then layer_spec.session_id = sid end

  local layer_res, layer_err = rex.session.new_layer(layer_spec)
  if not layer_res then
    abort_worker(worker, temp_dir)
    return nil, layer_err or "Could not open Rexplain floating layer."
  end

  local block_id = type(layer_res.block_ids) == "table" and layer_res.block_ids[1] or nil
  state.last_layer_id = layer_res.layer_id
  if block_id then
    pcall(rex.session.set_block_label, { session_id = sid, block_id = block_id, label = block_label })
  end
  schedule_layer_focus(sid, layer_res.layer_id, block_id)
  return layer_res, nil
end

function M.run_explain_flow(text, source_label, ctx)
  text = trim(text)
  if text == "" then
    log("warn", "No text provided to explain.")
    return false
  end

  local badge = normalize_badge(M.query_config_show().display_badge)
  local temp_dir, dir_err = make_request_dir()
  if not temp_dir then
    log("error", dir_err)
    return false
  end

  local stream_path = temp_dir .. "/stream.jsonl"
  write_private_file(stream_path, "")

  local worker_argv = extend_list({ M.executable_path(), "worker", "--output", stream_path }, M.backend_cli_args())
  local worker, start_err = rex.exec.start(worker_argv, { stdin = true, detach = true })
  if not worker then
    cleanup_request_dir(temp_dir)
    log("error", "Could not start Rexplain worker: " .. tostring(start_err))
    return false
  end

  local prep_json = rex.json.encode({ cmd = "prepare" })
  if prep_json then pcall(function() worker:write(prep_json .. "\n") end) end

  local detail, detail_why = M.pick_effort(source_label, badge)
  if not detail then
    abort_worker(worker, temp_dir)
    if detail_why ~= "cancelled" then log("warn", "Effort selection aborted: " .. tostring(detail_why)) end
    return false
  end

  local layer_res, launch_err = launch_worker_and_layer{
    detail = detail,
    text = text,
    model_badge = badge,
    ctx = ctx,
    worker = worker,
    temp_dir = temp_dir,
    stream_path = stream_path,
  }
  if not layer_res then
    log("error", launch_err)
    return false
  end
  return true
end

function M.select_model_action()
  local info, err = M.query_config_models()
  if not info then
    log("error", "Could not inspect Rexplain models: " .. tostring(err))
    return false
  end

  local fmf_prefix = info.active_backend == "fmf" and "[Active] " or ""
  local fmf_detail = info.fmf_available and "Strictly on-device Apple Intelligence model" or tostring(info.fmf_detail or "Unavailable")
  local items = {
    { id = "__fmf__", title = "Apple On-device (FMF)", subtitle = fmf_prefix .. fmf_detail, icon = "star" },
  }

  for _, cached in ipairs(info.cached_models or {}) do
    if type(cached) == "table" and type(cached.id) == "string" and cached.id ~= "" then
      local is_active = info.active_backend == "mlx" and info.active_model == cached.id
      items[#items + 1] = {
        id = "mlx:" .. cached.id,
        title = cached.id,
        subtitle = (is_active and "[Active] " or "") .. "Cached local MLX model · runner: " .. tostring(cached.suggested_runner or "auto"),
        icon = "package",
      }
    end
  end

  items[#items + 1] = {
    id = "__custom_mlx__",
    title = "Custom local MLX model…",
    subtitle = "Enter any Hugging Face MLX repo ID or local path (mlx-lm / mlx-vlm)",
    icon = "plus",
  }

  local choice, why = rex.ui.pick{
    title = "Rexplain · Select Model",
    placeholder = "Current: " .. tostring(info.display_badge or "On-device"),
    items = items,
  }
  if choice == nil then
    if why and why ~= "cancelled" then log("warn", "Model selection aborted: " .. tostring(why)) end
    return false
  end

  local exe = M.executable_path()
  if choice == "__fmf__" then
    local res, exec_err = rex.exec({ exe, "config", "set-fmf" }, { timeout = 3 })
    if not res or not res.ok then
      log("error", "Failed to switch to Apple On-device: " .. tostring(exec_err or (res and res.stderr)))
      return false
    end
    clear_model_overrides()
    log("info", "Default backend set to Apple On-device (FMF).")
    return true
  end

  local target_model = choice
  if choice == "__custom_mlx__" then
    local typed, input_why = rex.ui.input{
      title = "Rexplain · Custom Local MLX Model",
      placeholder = "e.g. mlx-community/Qwen2.5-0.5B-Instruct-4bit or /path/to/model",
      confirm = "Save",
      timeout = 300,
    }
    target_model = trim(typed)
    if target_model == "" then
      if input_why and input_why ~= "cancelled" then log("warn", "Custom model entry cancelled: " .. tostring(input_why)) end
      return false
    end
  elseif choice:sub(1, 4) == "mlx:" then
    target_model = choice:sub(5)
  end

  local res, exec_err = rex.exec({ exe, "config", "set-mlx", target_model }, { timeout = 3 })
  if not res or not res.ok then
    log("error", "Failed to set local MLX model: " .. tostring(exec_err or (res and res.stderr)))
    return false
  end
  clear_model_overrides()
  log("info", "Default model set to Local MLX: " .. target_model)
  return true
end

function M.acquire_terminal_text()
  local clip, clip_err = M.read_clipboard()
  if clip then return clip, "Clipboard: \"" .. preview_text(clip) .. "\"" end
  log("info", (clip_err or "Clipboard is empty.") .. " Prompting for manual input.")

  local input, why = rex.ui.input{
    title = "Rexplain · Paste or type text (clipboard empty)",
    placeholder = "Tip: enable Copy on Selection in Rex Settings, or paste text here…",
    confirm = "Continue",
    timeout = 300,
  }
  if input == nil or trim(input) == "" then
    if why and why ~= "cancelled" then log("warn", "Text input cancelled: " .. tostring(why)) end
    return nil, nil
  end
  return input, "Manual input: \"" .. preview_text(input) .. "\""
end

function M.explain_action(ctx)
  local route, _, err = classify_focused_process()
  if route == nil then
    log("error", "Could not determine focused terminal process: " .. tostring(err))
    return false
  end
  if route == "editor" or route == "multiplexer" then
    local ok, queue_err = pcall(rex.client.queue, "pane.send_key", { key = "f13" })
    if not ok then
      log("error", "Could not dispatch F13 to editor: " .. tostring(queue_err))
      return false
    end
    return true
  end

  local text, source_label = M.acquire_terminal_text()
  if not text then return false end
  return M.run_explain_flow(text, source_label, ctx)
end

rex.action{
  name = "rexplain_explain",
  title = "Rexplain: Explain Selection",
  description = "Explain selected text with local Rexplain models (FMF or MLX), or dispatch F13 to Neovim.",
  category = "Learning",
  keywords = "rexplain explain selection neovim local AI mlx",
  run = M.explain_action,
}

rex.action{
  name = "rexplain_select_model",
  title = "Rexplain: Select Model",
  description = "Switch Rexplain default between Apple On-device (FMF) and any cached or custom local MLX model.",
  category = "Learning",
  keywords = "rexplain model switch fmf mlx local huggingface",
  run = M.select_model_action,
}

-- Bind to named action string (not an inline function) so rex.ui.pick/input work inside run().
rex.bind(DEFAULT_KEY, "rexplain_explain")

return M
