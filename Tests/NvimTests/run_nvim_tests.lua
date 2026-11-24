local function assert_eq(a, b, msg)
  if a ~= b then error(string.format("%s: expected %s, got %s", msg or "assert_eq", vim.inspect(b), vim.inspect(a)), 2) end
end

local function assert_true(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

local adapter_dir = vim.fn.getcwd() .. "/adapters/nvim"
vim.opt.runtimepath:remove(adapter_dir)
vim.opt.runtimepath:append(adapter_dir)

local rexplain = require("rexplain")
rexplain.setup({ command = { "rexplain" }, keymap = "<F13>" })

local f13_map = vim.fn.maparg("<F13>", "x", false, true)
assert_true(f13_map and type(f13_map.callback) == "function")
local cmd_map = vim.fn.maparg("<D-S-e>", "x", false, true)
assert_true(not cmd_map or vim.tbl_isempty(cmd_map))
assert_true(vim.api.nvim_get_commands({})["RexplainModel"] ~= nil)

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "rust"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "fn alpha() {",
  "    let x = 42;",
  "    let y = x + 1;",
  "    println!(\"{}\", y);",
  "}",
})
vim.fn.setreg('"', "ORIG_UNNAMED")
vim.fn.setreg("+", "ORIG_CLIPBOARD")

vim.api.nvim_win_set_cursor(0, { 2, 4 })
vim.cmd("normal! v9l")
local char_sel = rexplain.get_selection()
vim.cmd("normal! \\<Esc>")
assert_eq(char_sel.text, "let x = 42")
assert_eq(char_sel.context, nil)
assert_eq(char_sel.filetype, nil)
assert_eq(char_sel.source, nil)
assert_eq(vim.fn.getreg('"'), "ORIG_UNNAMED")
assert_eq(vim.fn.getreg("+"), "ORIG_CLIPBOARD")

vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! Vj")
local line_sel = rexplain.get_selection()
vim.cmd("normal! \\<Esc>")
assert_true(line_sel.text:find("let x = 42;") ~= nil and line_sel.text:find("let y = x %+ 1;") ~= nil)

vim.api.nvim_win_set_cursor(0, { 2, 4 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-v>j2l", true, false, true), "nx", false)
local block_sel = rexplain.get_selection()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
assert_eq(block_sel.text, "let\nlet")

local sent_cmds, stopped_jobs, system_calls, notify_msgs = {}, {}, {}, {}
local active_callbacks, select_answers, select_prompts, input_answers = nil, {}, {}, {}

local mock_cfg_show = { backend = "fmf", display_badge = "On-device", active_model = "Apple Foundation Model" }
local mock_cfg_models = {
  active_backend = "fmf", active_model = "Apple Foundation Model", display_badge = "On-device",
  fmf_available = true, fmf_detail = "Ready",
  cached_models = { { id = "mlx-community/Qwen2.5-0.5B-Instruct-4bit", suggested_runner = "mlx_lm" } },
}

rexplain._deps.jobstart = function(_, opts) active_callbacks = opts; return 101 end
rexplain._deps.chansend = function(_, data) sent_cmds[#sent_cmds + 1] = data; return 1 end
rexplain._deps.chanclose = function() return 1 end
rexplain._deps.jobstop = function(job) stopped_jobs[#stopped_jobs + 1] = job; return 1 end
rexplain._deps.notify = function(msg, level) notify_msgs[#notify_msgs + 1] = { msg = msg, level = level } end
rexplain._deps.ui_input = function(_, on_confirm) on_confirm(table.remove(input_answers, 1)) end
rexplain._deps.system = function(argv)
  system_calls[#system_calls + 1] = argv
  if argv[2] == "config" and argv[3] == "show" then return { code = 0, stdout = vim.json.encode(mock_cfg_show), stderr = "" } end
  if argv[2] == "config" and argv[3] == "models" then return { code = 0, stdout = vim.json.encode(mock_cfg_models), stderr = "" } end
  if argv[2] == "config" and (argv[3] == "set-fmf" or argv[3] == "set-mlx") then return { code = 0, stdout = "OK\n", stderr = "" } end
  return { code = 1, stdout = "", stderr = "unexpected" }
end
rexplain._deps.ui_select = function(items, opts, on_choice)
  select_prompts[#select_prompts + 1] = opts.prompt
  local choice_id = table.remove(select_answers, 1)
  if choice_id == nil then on_choice(nil); return end
  for _, item in ipairs(items) do
    if item.id == choice_id then on_choice(item); return end
  end
  error("Choice id not found: " .. tostring(choice_id))
end

local function read_win_title(win)
  local title = vim.api.nvim_win_get_config(win).title
  return type(title) == "table" and table.concat(vim.tbl_map(function(t) return t[1] end, title)) or tostring(title)
end

select_answers = { "first-principles" }
rexplain.run_picker_flow(char_sel)
assert_eq(#select_prompts, 1)
assert_true(select_prompts[1]:find("Rexplain · On%-device") ~= nil)
assert_true(sent_cmds[1]:find('"prepare"') ~= nil)
assert_true(sent_cmds[2]:find('"explain"') ~= nil)
assert_true(sent_cmds[2]:find('"first%-principles"') ~= nil)
assert_eq(sent_cmds[2]:find('"context"'), nil)
assert_eq(sent_cmds[2]:find('"filetype"'), nil)
assert_eq(sent_cmds[2]:find('"source"'), nil)

active_callbacks.on_stdout(101, { '{"type":"started","model_label":"On-device","hint":"Tip: switch via :RexplainModel"}\n{"type":"delta","text":"1. Step' })
active_callbacks.on_stdout(101, { ' one."}\n{"type":"completed"}\n' })
vim.wait(100, function() return false end)

assert_true(#notify_msgs >= 1 and notify_msgs[1].msg:find("Tip:") ~= nil)
local st = rexplain.get_state()
assert_true(st.active_win ~= nil and vim.api.nvim_win_is_valid(st.active_win))
assert_eq(read_win_title(st.active_win), " Rexplain · On-device · First-principles ")

local lines = vim.api.nvim_buf_get_lines(st.active_buf, 0, -1, false)
assert_eq(lines[1], "")
assert_eq(lines[2], "1. Step one.")
assert_eq(#lines, 2)

local lhs_set = {}
for _, km in ipairs(vim.api.nvim_buf_get_keymap(st.active_buf, "n")) do lhs_set[km.lhs] = true end
assert_true(lhs_set["q"] and lhs_set["<Esc>"])
for _, removed_key in ipairs({ "f", "s", "d", "e", "c", "r" }) do
  assert_eq(lhs_set[removed_key], nil)
end

vim.api.nvim_win_close(st.active_win, true)
vim.wait(50, function() return false end)
assert_true(#stopped_jobs >= 1)

mock_cfg_show = { backend = "mlx", display_badge = "Local · Qwen2.5-0.5B-Instruct-4bit", active_model = "mlx-community/Qwen2.5-0.5B-Instruct-4bit" }
select_answers = { "compact" }
rexplain.run_picker_flow(char_sel)
active_callbacks.on_stdout(101, { '{"type":"started","model_label":"Local · Qwen2.5-0.5B-Instruct-4bit"}\n{"type":"delta","text":"1. MLX step."}\n{"type":"completed"}\n' })
vim.wait(100, function() return false end)
st = rexplain.get_state()
assert_eq(read_win_title(st.active_win), " Rexplain · Local · Qwen2.5-0.5B-Instruct-4bit · Compact ")
vim.api.nvim_win_close(st.active_win, true)
vim.wait(50, function() return false end)

system_calls, select_answers = {}, { "mlx:mlx-community/Qwen2.5-0.5B-Instruct-4bit" }
vim.cmd("RexplainModel")
assert_eq(system_calls[#system_calls][3], "set-mlx")
assert_eq(system_calls[#system_calls][4], "mlx-community/Qwen2.5-0.5B-Instruct-4bit")

system_calls, select_answers, input_answers = {}, { "__custom_mlx__" }, { "mlx-community/Phi-4-mini-instruct-4bit" }
vim.cmd("RexplainModel")
assert_eq(system_calls[#system_calls][3], "set-mlx")
assert_eq(system_calls[#system_calls][4], "mlx-community/Phi-4-mini-instruct-4bit")

system_calls, select_answers = {}, { "__fmf__" }
vim.cmd("RexplainModel")
assert_eq(system_calls[#system_calls][3], "set-fmf")

select_answers, stopped_jobs = { nil }, {}
rexplain.run_picker_flow(char_sel)
assert_true(#stopped_jobs >= 1)

print("ALL_NVIM_TESTS_PASSED")
