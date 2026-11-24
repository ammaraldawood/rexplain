![Rexplain banner](assets/rexplain.png)

# Rexplain

**A minimal, local technical comprehension tool for Rex and Neovim powered by Apple's on-device Foundation Model or any local Apple MLX model.**

Select a term, sentence, paragraph, equation, code snippet, command, or error in Rex or Neovim, press **Shift + Command + E**, pick an effort depth (`Compact`, `Standard`, or `First-principles`), and read a clear, concise numbered explanation streamed on demand from strictly the selected text (nothing above or below the selection, and no buffer/filetype metadata).

---

## 1. Overview

Rexplain is an on-demand macOS CLI (`rexplain`) paired with lightweight adapters for [Rex](https://www.superlogical.com/rex) and [Neovim](https://neovim.io). Every request spawns an ephemeral process, sends only the exact selected text, streams the response into a focused floating popup, and exits cleanly. There is no background daemon, no LaunchAgent, no local HTTP server or listening TCP port, and no disk transcript store.

Two local runtime backends are supported:

1. **Apple Foundation Model (`fmf`, default)** — strictly **On-device** inference via `SystemLanguageModel.default` with zero network access and KV-prefix prewarming while you choose an effort level.
2. **Direct Local MLX CLI (`mlx`, optional)** — spawns `mlx_lm` or `mlx_vlm` directly on demand (`auto` routes text models to `mlx_lm` and vision/multimodal architectures to `mlx_vlm`, falling back automatically if needed). You can point it to *any* Hugging Face MLX repository or local model directory installed via `mlx-lm` / `mlx-vlm`.

> [!NOTE]
> Window titles intentionally distinguish **`Rexplain · On-device · <Effort>`** (Apple Foundation Model, confirmed strictly on-device) from **`Rexplain · Local · <Model> · <Effort>`** (arbitrary third-party MLX models invoked directly on your Mac).

---

## 2. Genuine Demonstration

Live CLI output on Apple M1 (macOS 27.2.1):

```text
$ rexplain explain --backend fmf --detail compact --styled \
    --text "Copy-on-write shares memory pages until a write occurs."

╭────────────────────────────────────────────────────────────────────────────╮
│ Rexplain · On-device · Compact                                             │
╰────────────────────────────────────────────────────────────────────────────╯

1. **Definition**: Copy-on-write shares memory pages by initializing both pages with the same data before the first write.
2. **Mechanism**: When a write happens, the shared page is overwritten, and the copy is created for the modified data.
3. **Purpose**: This reduces memory overhead by avoiding duplicate data storage until necessary.
4. **Caveat**: If the shared page is modified after the first write, the copy may not be updated, preserving the original data.
```

---

## 3. Effort Levels

| Effort | Target Length | Focus |
|---|---|---|
| **Compact** *(default)* | 3–5 lines | Core definition, central mechanism, and takeaway |
| **Standard** | 6–10 steps | Key terms, mechanism, and consequences |
| **First-principles** | Up to 14–22 steps | Foundational definitions and assumptions, step-by-step derivation, edge cases/trade-offs, and a concrete example |

Prompts use plain numbered-list instructions with explicit nucleus sampling (`temperature: 0.45`, `top_p: 0.9` — plus `min_p: 0.05`, `repetition_penalty: 1.12`, and `repetition_context_size: 512` on MLX).

---

## 4. Architecture

```text
Shift + Command + E (Rex)  ──►  Is Neovim/Vim/tmux focused?
                                  ├── Yes ─► `pane.send_key("f13")` ─► Neovim Visual `<F13>`
                                  └── No  ─► Read clipboard (or `rex.ui.input` if empty)
                                                │
                                                ▼
                                     Spawn ephemeral `rexplain worker`
                                     (prewarms FMF while menu is open)
                                                │
                                                ▼
                                     Pick effort (`Compact` / `Standard` / `First-principles`)
                                                │
                                                ▼
                                     Stream JSONL (FMF or MLX CLI, selection-only)
                                     ─► Focused Rex floating layer / Neovim float
                                                │
                                                ▼
                                     Process exits cleanly
```

### Repository layout

```text
rexplain/
├── Package.swift
├── LICENSE
├── README.md
├── assets/
│   └── rexplain.png
├── Sources/
│   ├── Rexplain/
│   │   └── main.swift               # Async CLI entrypoint
│   └── RexplainCore/
│       ├── CLI.swift                # Subcommands (`explain`, `config`, `status`, `health`, `worker`, `view`)
│       ├── Config.swift             # XDG config (`~/.config/rexplain/config.json`) & HF cache discovery
│       ├── DetailLevel.swift        # Compact / Standard / First-principles configuration
│       ├── InferenceEngine.swift    # Backend abstraction, FMF engine & ExplainEngine
│       ├── MLXBackend.swift         # Universal direct `mlx_lm` / `mlx_vlm` subprocess backend
│       ├── OnDeviceStatus.swift     # Backend availability & diagnostic report
│       ├── PromptTemplates.swift    # Plain selection-only numbered-list prompt & prewarm prefix
│       ├── Protocol.swift           # JSONL worker commands & events
│       ├── TerminalRenderer.swift   # Concise box header & interactive StreamViewer
│       └── WorkerLoop.swift         # Ephemeral stdin/stdout JSONL worker loop
├── Tests/
│   ├── RexplainTests/               # Swift Testing unit, config & MLX lifecycle suites
│   ├── RexTests/                    # LuaJIT test suite for Rex adapter
│   └── NvimTests/                   # Headless Neovim test suite for Neovim adapter
├── adapters/
│   ├── rex/
│   │   ├── README.md
│   │   └── rexplain.lua
│   ├── nvim/
│   │   ├── README.md
│   │   └── lua/rexplain/init.lua
│   └── zsh/
│       └── rexplain.zsh
├── config/
│   ├── rex-init.lua.example
│   └── nvim-setup.lua.example
└── scripts/
    ├── install-macos.sh
    ├── uninstall-macos.sh
    └── test.sh
```

---

## 5. Requirements

- **macOS 26.0+** on Apple Silicon with Apple Intelligence enabled for the default FMF backend (verified on macOS 27.2.1, Apple M1, Swift 6.4.2).
- **Swift 6.2+ toolchain**.
- **Rex** (`rex 0.1.0-snapshot.2514` or compatible API rev 19) for the Rex adapter.
- **Neovim 0.10+** (verified on Neovim 0.12.4 / LuaJIT 2.1) for the Neovim adapter.
- **Optional for MLX models:** [`mlx-lm`](https://github.com/ml-explore/mlx-lm) and/or [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) installed on your Mac (e.g. `uv tool install mlx-lm`, `uv tool install mlx-vlm`).

---

## 6. Installation

```bash
git clone https://github.com/ammaraldawood/rexplain.git
cd rexplain
./scripts/install-macos.sh
```

Verify installation:

```bash
rexplain status
rexplain health
printf 'Copy-on-write shares memory pages until a write occurs.\n' | rexplain explain --stdin --detail compact --styled
```

---

## 7. Switching Local Models (FMF / MLX)

By default, Rexplain uses Apple's **On-device Foundation Model** (`fmf`). Configuration lives outside this repository at `~/.config/rexplain/config.json` (respecting `REXPLAIN_CONFIG_PATH` and `XDG_CONFIG_HOME`):

```bash
# Inspect active backend, discovered cached HF models, and installed MLX CLIs
rexplain config show
rexplain config models

# Switch default to any Hugging Face MLX model or local directory path
rexplain config set-mlx mlx-community/Qwen2.5-0.5B-Instruct-4bit
rexplain config set-mlx mlx-community/gemma-4-e4b-it-4bit --mlx-runner mlx_vlm

# Switch back to Apple On-device (FMF)
rexplain config set-fmf

# One-off per-command override without changing saved config
rexplain explain --backend mlx --model mlx-community/Qwen2.5-0.5B-Instruct-4bit --text "What is virtual memory?" --styled
```

Precedence: **CLI flags (`--backend`, `--model`, `--mlx-runner`, `--mlx-command`) > Environment variables (`REXPLAIN_BACKEND`, `REXPLAIN_MODEL`, `REXPLAIN_MLX_RUNNER`, `REXPLAIN_MLX_COMMAND`) > `~/.config/rexplain/config.json` > default (`fmf`)**.

---

## 8. Rex Integration

Add to `~/.config/rex/init.lua` (see [config/rex-init.lua.example](config/rex-init.lua.example)):

```lua
local rexplain_root = (os.getenv("HOME") or "") .. "/github/rexplain"
package.path = package.path .. ";" .. rexplain_root .. "/adapters/rex/?.lua"
require("rexplain")
```

Enable **Rex Settings → Terminal → Selection → Copy on Selection** (or yank from Rex Copy Mode). Reload and verify:

```bash
rex config reload
rex actions | grep rexplain
rex keymap | grep rexplain
```

Registered actions:
- `Rexplain: Explain Selection` (`rexplain_explain`, bound to `shift+cmd+e`)
- `Rexplain: Select Model` (`rexplain_select_model`, lists Apple On-device + cached Hugging Face MLX models + custom repo/path prompt)

The adapter spawns the floating explanation layer with `focus = false` and runs a detached `session.set_layer_state({"focus": true})` call after `rex.ui.pick` finishes dismissing its command palette, ensuring keyboard focus shifts directly into the new popup pane.

---

## 9. Neovim Integration

Load **after** `lazy.setup(...)` in `~/.config/nvim/init.lua` so Lazy's `runtimepath` reset does not drop the module (see [config/nvim-setup.lua.example](config/nvim-setup.lua.example)):

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

- Press **Shift + Cmd + E** (routed as `<F13>`) in Visual mode to pick an effort depth (`Compact`, `Standard`, `First-principles`) and stream an explanation of strictly the Visual selection (no surrounding buffer lines, filetype metadata, or register mutations) into a floating Markdown popup.
- Run `:RexplainModel` in Neovim to switch the default between Apple On-device (FMF) and any cached or custom local MLX model.
- Inside the floating Markdown popup, press `q` or `<Esc>` to cancel any in-flight generation and close the window.

---

## 10. Tests

Run all three suites:

```bash
./scripts/test.sh
```

Or individually:

```bash
swift test --disable-xctest --enable-swift-testing
luajit Tests/RexTests/run_rex_tests.lua
nvim --headless -u NONE -l Tests/NvimTests/run_nvim_tests.lua
```

---

## 11. Uninstallation

```bash
./scripts/uninstall-macos.sh
```

Removes `~/.local/bin/rexplain` without modifying your Rex, Neovim, or `~/.config/rexplain/config.json` configuration files.

---

## 12. Known Limitations

1. **FMF 4K context window:** `SystemLanguageModel.default` has a 4,096-token combined input + output context limit; overly long selections will require selecting a shorter passage.
2. **MLX cold load latency:** Because Rexplain executes `mlx_lm`/`mlx_vlm` directly on demand with no background daemon, each MLX invocation loads weights from disk/OS page cache for the chosen model.
3. **Rex selection API:** Rex does not expose a direct mouse-selection getter in its Lua API; terminal mouse selections rely on Copy on Selection (or Copy Mode yank) into the macOS clipboard, with an explicit `rex.ui.input` prompt when empty.

---

## 13. License

[MIT License](LICENSE).
