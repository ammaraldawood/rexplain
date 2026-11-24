local function assert_eq(a, b, msg)
  if a ~= b then error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(b), tostring(a)), 2) end
end

local function assert_true(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

local VALID_ICONS = {
  document = true, folder = true, branch = true, terminal = true,
  code = true, server = true, database = true, package = true,
  globe = true, link = true, person = true, tag = true,
  clock = true, star = true, gear = true, plus = true,
}

local function json_escape(s)
  return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
end

local function json_encode(val)
  local t = type(val)
  if t == "string" then return '"' .. json_escape(val) .. '"' end
  if t == "number" or t == "boolean" then return tostring(val) end
  if t == "table" then
    local items = {}
    if #val > 0 then
      for i = 1, #val do items[i] = json_encode(val[i]) end
      return "[" .. table.concat(items, ",") .. "]"
    end
    for k, v in pairs(val) do items[#items + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(v) end
    return "{" .. table.concat(items, ",") .. "}"
  end
  return "null"
end

local function json_decode(str)
  local pos = 1
  local function skip_ws() pos = str:match("^%s*()", pos) or pos end
  local parse_val
  local function parse_str()
    pos = pos + 1
    local out = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == '\\' then
        local nxt = str:sub(pos + 1, pos + 1)
        pos = pos + 2
        out[#out + 1] = (nxt == 'n' and '\n') or (nxt == 't' and '\t') or (nxt == 'r' and '\r') or nxt
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    error("Unterminated JSON string")
  end
  local function parse_seq(close_ch, read_entry)
    pos = pos + 1
    skip_ws()
    local res = {}
    if str:sub(pos, pos) == close_ch then pos = pos + 1; return res end
    while true do
      read_entry(res)
      skip_ws()
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == close_ch then return res end
      assert(c == ",", "Expected ',' in JSON")
    end
  end
  parse_val = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '"' then return parse_str() end
    if c == '[' then return parse_seq("]", function(arr) arr[#arr + 1] = parse_val() end) end
    if c == '{' then
      return parse_seq("}", function(obj)
        skip_ws()
        local k = parse_str()
        skip_ws()
        assert(str:sub(pos, pos) == ":", "Expected ':'")
        pos = pos + 1
        obj[k] = parse_val()
      end)
    end
    if str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
    if str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
    if str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
    local num = assert(str:match("^-?%d+%.?%d*", pos), "Invalid JSON token")
    pos = pos + #num
    return tonumber(num)
  end
  return parse_val()
end

local mock = {
  actions = {}, bindings = {}, queued = {}, layers = {}, closed_layers = {},
  block_labels = {}, started_cmds = {}, exec_cmds = {}, logs = {},
  clipboard = "A deterministic hash function maps arbitrary inputs to fixed-size digests.",
  process_snapshot = { foreground = { name = "zsh" }, child = { name = "zsh" } },
  pick_queue = {}, input_queue = {}, pick_calls = {}, worker_writes = {},
  worker_killed = false, worker_closed_stdin = false,
  config_show_response = { backend = "fmf", display_badge = "On-device", active_model = "Apple Foundation Model" },
  config_models_response = {
    active_backend = "fmf", active_model = "Apple Foundation Model", display_badge = "On-device",
    fmf_available = true, fmf_detail = "On-device model ready", mlx_lm_available = true, mlx_vlm_available = false,
    cached_models = { { id = "mlx-community/Qwen2.5-0.5B-Instruct-4bit", short_name = "Qwen2.5-0.5B-Instruct-4bit", suggested_runner = "mlx_lm" } },
  },
}

local function reset_mock()
  mock.queued, mock.layers, mock.closed_layers, mock.block_labels = {}, {}, {}, {}
  mock.started_cmds, mock.exec_cmds, mock.logs = {}, {}, {}
  mock.pick_queue, mock.input_queue, mock.pick_calls, mock.worker_writes = {}, {}, {}, {}
  mock.worker_killed, mock.worker_closed_stdin = false, false
end

local tmp_root = "/tmp/rexplain-rex-test-" .. tostring(os.time())
os.execute("mkdir -p " .. tmp_root)

_G.rex = {
  log = function(level, msg) mock.logs[#mock.logs + 1] = { level = level, msg = msg } end,
  action = function(spec)
    assert_true(type(spec.name) == "string" and spec.name ~= "" and type(spec.run) == "function")
    mock.actions[spec.name] = spec
  end,
  bind = function(key, target) mock.bindings[key] = target end,
  block = {
    call = function(creator, method)
      if creator == "com.superlogical.terminal" and method == "process" then return mock.process_snapshot end
      return nil, "unknown block method"
    end,
  },
  client = { queue = function(action, args) mock.queued[#mock.queued + 1] = { action = action, args = args } end },
  json = { encode = function(tbl) return json_encode(tbl), nil end, decode = json_decode },
  exec = setmetatable({
    start = function(argv, opts)
      mock.started_cmds[#mock.started_cmds + 1] = { argv = argv, opts = opts }
      return {
        pid = 98765,
        write = function(_, data) mock.worker_writes[#mock.worker_writes + 1] = data; return true end,
        close_stdin = function() mock.worker_closed_stdin = true end,
        kill = function(_, sig) mock.worker_killed = sig or "SIGTERM" end,
        running = function() return true end,
      }, nil
    end,
  }, {
    __call = function(_, argv)
      mock.exec_cmds[#mock.exec_cmds + 1] = argv
      local cmd = argv[1]
      if cmd == "/usr/bin/pbpaste" then return { ok = true, stdout = mock.clipboard }, nil
      elseif cmd == "/usr/bin/mktemp" then
        local dir = tmp_root .. "/req-" .. tostring(math.random(10000, 99999))
        os.execute("mkdir -p " .. dir)
        return { ok = true, stdout = dir .. "\n" }, nil
      elseif cmd == "/bin/chmod" or cmd == "/bin/mkdir" or cmd == "/bin/rm" then
        os.execute(table.concat(argv, " "))
        return { ok = true, stdout = "" }, nil
      elseif argv[2] == "config" and argv[3] == "show" then
        return { ok = true, stdout = json_encode(mock.config_show_response) }, nil
      elseif argv[2] == "config" and argv[3] == "models" then
        return { ok = true, stdout = json_encode(mock.config_models_response) }, nil
      elseif argv[2] == "config" and (argv[3] == "set-fmf" or argv[3] == "set-mlx") then
        return { ok = true, stdout = "OK\n" }, nil
      end
      return { ok = false, stderr = "unexpected exec: " .. tostring(cmd) }, nil
    end,
  }),
  ui = {
    pick = function(opts)
      for _, item in ipairs(opts.items or {}) do
        if item.icon then assert_true(VALID_ICONS[item.icon], "Invalid Rex icon: " .. tostring(item.icon)) end
      end
      mock.pick_calls[#mock.pick_calls + 1] = opts
      local next_item = table.remove(mock.pick_queue, 1)
      if type(next_item) == "table" then return next_item[1], next_item[2] end
      return next_item, next_item == nil and "cancelled" or nil
    end,
    input = function()
      local next_item = table.remove(mock.input_queue, 1)
      if type(next_item) == "table" then return next_item[1], next_item[2] end
      return next_item, next_item == nil and "cancelled" or nil
    end,
  },
  layout = { block = function(spec) return { block = spec } end },
  session = {
    view = function() return { session_id = "session:view-fallback" } end,
    new_layer = function(spec)
      local idx = #mock.layers + 1
      mock.layers[idx] = spec
      return { layer_id = "layer:" .. idx, block_ids = { "block:" .. idx } }, nil
    end,
    close_layer = function(args) mock.closed_layers[#mock.closed_layers + 1] = args.layer_id end,
    set_block_label = function(args) mock.block_labels[#mock.block_labels + 1] = args end,
  },
}

package.path = "adapters/rex/?.lua;" .. package.path
local M = require("rexplain")
M.executable_path = function() return "/Users/test/.local/bin/rexplain" end
M.find_rex_bin = function() return "/mock/bin/rex" end

assert_true(mock.actions["rexplain_explain"] ~= nil)
assert_true(mock.actions["rexplain_select_model"] ~= nil)
assert_eq(mock.actions["rexplain_debug_focus"], nil)
assert_eq(mock.actions["rexplain_followup"], nil)
assert_eq(mock.bindings["shift+cmd+e"], "rexplain_explain")
assert_eq(type(mock.bindings["shift+cmd+e"]), "string")

reset_mock()
mock.process_snapshot = { foreground = { name = "nvim" }, ancestors = { { name = "zsh" } } }
mock.actions["rexplain_explain"].run({ session_id = "session:ctx-1" })
assert_eq(#mock.queued, 1)
assert_eq(mock.queued[1].action, "pane.send_key")
assert_eq(mock.queued[1].args.key, "f13")
assert_eq(#mock.layers, 0)

reset_mock()
mock.process_snapshot = { foreground = { name = "zsh" } }
mock.pick_queue = { "first-principles" }
mock.actions["rexplain_explain"].run({ session_id = "session:ctx-1" })
assert_eq(#mock.pick_calls, 1)
assert_eq(mock.pick_calls[1].title, "Rexplain · On-device")
assert_true(mock.pick_calls[1].placeholder:find("Clipboard:") ~= nil)
assert_eq(#mock.pick_calls[1].items, 3)
assert_true(mock.worker_writes[1]:find('"prepare"') ~= nil)
assert_true(mock.worker_writes[2]:find('"explain"') ~= nil)
assert_true(mock.worker_writes[2]:find('"first%-principles"') ~= nil)
assert_eq(mock.worker_writes[2]:find('"context"'), nil)
assert_eq(mock.worker_writes[2]:find('"filetype"'), nil)
assert_eq(mock.worker_writes[2]:find('"source"'), nil)
assert_true(mock.worker_closed_stdin)
assert_eq(#mock.layers, 1)
assert_eq(mock.layers[1].focus, false)
assert_eq(mock.layers[1].layout.block.label, "Rexplain · On-device · First-principles")
assert_eq(#mock.block_labels, 1)
assert_eq(mock.started_cmds[2].opts.detach, true)
assert_eq(mock.started_cmds[2].argv[5], "/mock/bin/rex")
assert_true(mock.started_cmds[2].argv[6]:find('"focus":true') ~= nil)

reset_mock()
mock.config_show_response = {
  backend = "mlx",
  display_badge = "Local · Qwen2.5-0.5B-Instruct-4bit",
  active_model = "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
}
mock.pick_queue = { "compact" }
mock.actions["rexplain_explain"].run({ session_id = "session:ctx-1" })
assert_eq(mock.pick_calls[1].title, "Rexplain · Local · Qwen2.5-0.5B-Instruct-4bit")
assert_eq(mock.layers[1].layout.block.label, "Rexplain · Local · Qwen2.5-0.5B-Instruct-4bit · Compact")
assert_true(table.concat(mock.layers[1].layout.block.options.command, " "):find("Local · Qwen2.5%-0.5B%-Instruct%-4bit") ~= nil)

reset_mock()
mock.pick_queue = { "mlx:mlx-community/Qwen2.5-0.5B-Instruct-4bit" }
assert_true(mock.actions["rexplain_select_model"].run())
assert_eq(mock.pick_calls[1].title, "Rexplain · Select Model")
assert_eq(#mock.pick_calls[1].items, 3)
assert_eq(mock.exec_cmds[#mock.exec_cmds][3], "set-mlx")
assert_eq(mock.exec_cmds[#mock.exec_cmds][4], "mlx-community/Qwen2.5-0.5B-Instruct-4bit")

reset_mock()
mock.pick_queue = { "__custom_mlx__" }
mock.input_queue = { "mlx-community/Phi-4-mini-instruct-4bit" }
assert_true(mock.actions["rexplain_select_model"].run())
assert_eq(mock.exec_cmds[#mock.exec_cmds][3], "set-mlx")
assert_eq(mock.exec_cmds[#mock.exec_cmds][4], "mlx-community/Phi-4-mini-instruct-4bit")

reset_mock()
mock.pick_queue = { "__fmf__" }
assert_true(mock.actions["rexplain_select_model"].run())
assert_eq(mock.exec_cmds[#mock.exec_cmds][3], "set-fmf")

reset_mock()
mock.pick_queue = { { nil, "cancelled" } }
mock.actions["rexplain_explain"].run({ session_id = "session:ctx-1" })
assert_eq(mock.worker_killed, "SIGTERM")
assert_eq(#mock.layers, 0)

reset_mock()
mock.clipboard = "   "
mock.input_queue = { "Manual technical phrase" }
mock.pick_queue = { "standard" }
mock.actions["rexplain_explain"].run({})
assert_eq(#mock.layers, 1)
assert_eq(mock.layers[1].session_id, "session:view-fallback")

os.execute("rm -rf " .. tmp_root)
print("ALL_REX_LUA_TESTS_PASSED")
