# Rexplain · Rex adapter

The Rex adapter owns the physical shortcut:

**Shift + Command + E**

It binds directly to the named custom action `rexplain_explain` (`rex.bind("shift+cmd+e", "rexplain_explain")`) so native `rex.ui.pick` and `rex.ui.input` prompts run safely inside the action's `run` function.

## Routing

- **Neovim/Vim (or multiplexer):** forwards `f13` to the PTY via `rex.client.queue("pane.send_key", { key = "f13" })`. The macOS Command chord is never forwarded.
- **Ordinary terminal:**
  1. Reads only the copied selection from the macOS clipboard (or falls back to `rex.ui.input` when empty) and shows a clipboard preview in the picker prompt.
  2. Spawns a short-lived `rexplain worker` (prewarming `SystemLanguageModel.default` when using Apple FMF) while you pick an effort level (`Compact`, `Standard`, or `First-principles`).
  3. Sends strictly the selected text with no extra context or metadata, then opens a Rex floating layer (`focus = false`, followed by a detached post-palette `rex api call session.set_layer_state {"focus":true}` call after the command palette dismisses so keyboard focus shifts directly into the popup pane) with a `Rexplain · On-device · <Effort>` or `Rexplain · Local · <Model> · <Effort>` heading.

## Load

```lua
local root = (os.getenv("HOME") or "") .. "/github/rexplain"
package.path = package.path .. ";" .. root .. "/adapters/rex/?.lua"
require("rexplain")
```

Enable **Rex Settings → Terminal → Selection → Copy on Selection** for mouse selections, or yank from Rex Copy Mode.

Command palette actions:
- `Rexplain: Explain Selection` (`Shift+Cmd+E`)
- `Rexplain: Select Model` (switch between Apple On-device FMF and any cached or custom local MLX model)
