# Rexplain · Neovim adapter

Rex owns the physical **Shift + Command + E** shortcut. When Neovim/Vim is active in the focused Rex terminal, Rex dispatches `<F13>` via `pane.send_key`.

This adapter maps **`<F13>` in Visual mode** (`x`). It never maps `<D-S-e>`.

## Features

- Captures characterwise (`v`), linewise (`V`), and blockwise (`<C-v>`) Visual selections via `vim.fn.getregion`—sending strictly the selected text with no surrounding buffer lines, filetype metadata, or register mutations.
- Spawns `rexplain worker` (prewarming `SystemLanguageModel.default` when using Apple FMF) while you choose an effort level (`Compact`, `Standard`, or `First-principles`).
- Streams the numbered response into a rounded floating Markdown window titled `Rexplain · On-device · <Effort>` or `Rexplain · Local · <Model> · <Effort>`, spaced cleanly with a blank top line.
- Press `q` or `<Esc>` to cancel active generation and close the popup; run `:RexplainModel` to switch between Apple On-device (FMF) and any cached or custom local MLX model.

## Load with Lazy.nvim

Load the adapter **after** `lazy.setup(...)`, because Lazy resets `runtimepath` during initialization:

```lua
local rexplain_nvim = vim.fn.expand("~/github/rexplain/adapters/nvim")
if vim.fn.isdirectory(rexplain_nvim) == 1 then
  vim.opt.runtimepath:append(rexplain_nvim)
  require("rexplain").setup({
    command = { vim.fn.expand("~/.local/bin/rexplain") },
    keymap = "<F13>",
  })
end
```
