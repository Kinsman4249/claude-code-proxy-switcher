# claude-code-proxy-switcher

An on/off switch for routing Claude Code through a local model instead of your Anthropic Pro/Max subscription, with no API key anywhere and no cloud fallback. When it's off, Claude Code behaves exactly as if this project didn't exist, normal subscription auth, Sonnet and Opus available. When it's on, every model Claude Code might call, main session or sub-agent, routes to a local Qwen3.5-9B model running under llama-server (llama.cpp's own server), meant for small, cheap tasks where you don't want to spend Pro usage at all.

## Why this exists

Claude Code is agentic: a lot of what it does per session is mechanical (file search, `grep`, listing directories, small reads) rather than reasoning-heavy. Running that mechanical work through a frontier model is more capability than the task needs. This project gives you a deliberate, visible switch to route that kind of work to a local model instead, without touching your subscription usage or ever requiring a billed API key.

It does not try to be a hybrid router that transparently falls back to cloud when llama-server isn't running. Anthropic's April 2026 policy change blocking subscription OAuth tokens in third-party proxies ruled out a fallback that draws from Pro/Max usage instead of billed API usage. Rather than accept surprise direct billing on the fallback path, this project has no cloud path in its proxy config at all: local mode either uses your local model, or it fails cleanly with a connection error. No middle ground, no accidental charges.

## Requirements

- A Linux host with [Distrobox](https://github.com/89luca89/distrobox) and an NVIDIA-capable container (GPU passthrough already working). Built and tested on Bazzite (KDE Plasma), but the mechanism (systemd `--user` units calling into `distrobox enter`) has no Bazzite-specific dependency and should work on any distro with Distrobox and systemd.
- `llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp) built inside that container. `install.sh` builds it automatically (clones the repo, builds with CUDA) if it isn't already on `$PATH` there.
- [LiteLLM](https://docs.litellm.ai) (`pip install 'litellm[proxy]'`) installed inside that container.
- Claude Code, used either via the CLI or the VS Code/VSCodium extension.
- Roughly 8 GB of VRAM headroom to run Qwen3.5-9B at a reasonable quant and context length.

## Quickstart

```bash
mkdir -p ~/claude-code-proxy-switcher && cd ~/claude-code-proxy-switcher
curl -fsSL https://github.com/Kinsman4249/claude-code-proxy-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
chmod +x install.sh uninstall.sh
./install.sh
```

This pulls a fresh tarball of the repo and overwrites everything in the directory unconditionally - no git working tree, so there's nothing to conflict with local edits. If you'd rather track history and use `git pull`, cloning with git works the same way, but then it's on you to keep that checkout clean (commit or stash any local edits before pulling) since a normal `git pull` refuses to overwrite files you've changed.

The installer is interactive: it asks about your container name, proxy port and token, whether to enable systemd lingering, which quantization to use, your card's usable VRAM and batch size (used to compute a recommended context length, see below), and whether to install desktop icons (one to toggle Claude Code routing, one to start the model itself). Every answer is saved to `~/.config/claude-local-setup.conf` and shown as the default on the next run, so re-running the installer is mostly pressing Enter.

If the container name you type doesn't match exactly one container, `install.sh` lists everything `distrobox list` actually sees and asks you to pick a number instead of guessing or failing outright - this also covers typing something ambiguous that matches more than one container. Whatever you pick is saved as the new default.

Changing quant, context length, or any of the tuning flags later doesn't require editing any file: re-run `install.sh`, pick different answers at the model-related prompts, and it regenerates `start-local-llama.sh` with your new choices, skipping the download if that quant is already on disk. You then start the server yourself and confirm it's up; the script prints real VRAM usage from `nvidia-smi` afterward, so you know immediately whether a given quant/context combination actually fits, rather than finding out from a truncated prompt mid-session.

## Updating

```bash
cd ~/claude-code-proxy-switcher
curl -fsSL https://github.com/Kinsman4249/claude-code-proxy-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
```

Same command as the Quickstart - it just re-downloads and overwrites every file in the directory with whatever is on `main` now. Re-run `install.sh` afterward if the update touched anything you'd want re-applied (new prompts, changed defaults) - it's always safe to re-run, see above. Any local hand-edits to files in this directory get silently overwritten by this command, since it isn't a merge - if you've customized anything here, save a copy first.

## What's in this repo

```
.
|-- litellm_config.yaml            - LiteLLM proxy config, local-only, no API key, no cloud entries
|-- litellm-ollama-box.service      - systemd --user unit, starts only the proxy at login, no model auto-load
|-- distrobox-reminder.service      - systemd --user unit, login notification reminding you to stop the container before gaming
|-- claude-local-toggle.sh          - the actual switch: on/off/status, edits ~/.claude/settings.json
|-- claude-local-desktop-toggle.sh  - wrapper for the desktop icon: flips state, confirms via notification
|-- claude-local-toggle.desktop     - desktop launcher entry
|-- install.sh                      - interactive installer running every step below, with saved defaults
`-- uninstall.sh                    - reverses install.sh: stops/removes services, restores backed-up configs, deletes generated files
```

`start-local-llama.sh` and, if you installed the desktop icons, `start-local-llama-desktop.sh` plus a `claude-local-start-model.desktop` launcher entry, are all generated by `install.sh` into your `$BIN_DIR`/`$DESKTOP_DIR` - none of them are checked into this repo, don't hand-edit them, re-run `install.sh` to change any of their flags. `local-model.Modelfile` (the old Ollama build recipe) has been removed: it's no longer read by anything now that the local runtime is `llama-server` instead of Ollama, and its quant/context reasoning lives on in `CHANGELOG.md`'s history if you want it.

## How the switch works

`~/.claude/settings.json` supports an `env` block that both the Claude Code CLI and the VS Code/VSCodium extension read at startup. `claude-local-toggle.sh` adds or removes `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and an empty `ANTHROPIC_API_KEY` from that block:

```bash
claude-local-toggle.sh on       # route everything through the local proxy
claude-local-toggle.sh off      # back to normal Pro/Max subscription auth
claude-local-toggle.sh status   # check which state you're in
```

`on` refuses to flip the switch unless `llama-server` itself is actually answering at its `/health` endpoint, not just the LiteLLM proxy (the proxy runs via systemd all the time regardless of whether the model is loaded, so a proxy-only check would happily report success while pointed at a backend nobody started). If it's not reachable, `on` prints a reminder to run `start-local-llama.sh` and exits without touching `settings.json`. To deliberately test the clean-failure path described below, override with `claude-local-toggle.sh on --force`.

After toggling, reload the VS Code/VSCodium window (`Ctrl+Shift+P` > "Reload Window"), the extension only reads `settings.json` at startup, not live.

If you installed the desktop icon, double-clicking it does the same thing without a terminal: it checks the current state, flips it, and confirms the new state with a desktop notification - including a critical notification instead of silent failure if it tried to turn on but `llama-server` wasn't reachable.

## Starting and stopping the model itself

The proxy running is not the same as the model being loaded. Nothing loads automatically at boot:

```bash
~/.local/bin/start-local-llama.sh
```

This launches `llama-server` inside the container with the flags `install.sh` generated it with (`-ngl 99`, flash attention, Q8 KV cache, speculative decoding via the MTP head, your chosen context/batch size). It runs in the foreground in whatever terminal you started it in, so you can watch its own log output directly.

`install.sh` itself pauses right before this step and prints the exact command (not just the script path) so you don't have to go find it, then waits for you to press Enter once the server's actually up before it checks `/health` and prints VRAM usage.

If you installed the desktop icons, "Start Local Model" does the same thing for you: double-click it and it opens `start-local-llama.sh` in its own terminal window (`konsole`, falling back to `gnome-terminal` or `xterm`), so starting the model day to day is one click instead of typing a command. If it's already running, it just tells you so instead of opening a second instance. If no terminal emulator can be found on your desktop session, it falls back to a notification containing the exact command to paste into a terminal yourself - this fallback path hasn't been exercised in practice since it depends on your specific desktop setup, so treat it as best-effort until you've confirmed the double-click actually opens a window.

### Sizing your context window

`llama-server`'s VRAM use breaks down into three pieces: the model weights (fixed by your quant choice), a compute buffer (scales with batch size), and the KV cache (scales with context length). Running out of either of the first two before the third gets its share is the "out of context" symptom.

Qwen3.5-9B is a **hybrid** model, not a plain dense transformer and not MoE: of its 32 layers, only every 4th one (8 of 32) is full quadratic attention; the other 24 are linear/DeltaNet attention with a small fixed-size recurrent state that does not grow with context length (confirmed from [`Qwen/Qwen3.5-9B`'s `config.json`](https://huggingface.co/Qwen/Qwen3.5-9B/raw/main/config.json): `full_attention_interval: 4`, `num_key_value_heads: 4`, `head_dim: 256`). It also has **no MoE layers at all** - no `num_experts` field, `mlp_only_layers` is empty, dense `intermediate_size` throughout - so `--n-cpu-moe` would be a no-op on this model and isn't used. (An earlier draft of this project's docs incorrectly called it a hybrid dense+MoE model; that was wrong, corrected here.)

Because only 8 of 32 layers carry a real KV cache, the per-token cost is:

```
bytes/token = 2 (K+V) x num_kv_heads(4) x head_dim(256) x full_attention_layers(8) x bytes_per_element
            = 16384 x bytes_per_element
            = 16 KiB/token at q8_0 (1 byte/element, what this project always enables)
```

`install.sh` uses this formula to recommend a context length right after you pick a quant and batch size: `usable VRAM - quant weight size - estimated compute buffer - a fixed overhead reserve`, converted to tokens via the formula above, with a 15% safety margin. The compute-buffer estimate scales from a community-reported ~1508 MiB at batch 2048, which is also why **batch size matters more than it looks**: at batch 2048, that compute buffer alone can eat nearly all the room a ~7-8 GB card has left after a Q5-class quant, leaving next to nothing for KV cache - which reproduces exactly the "keep running out of KV cache" symptom. `install.sh` now defaults to batch 512 (llama.cpp's own default) for this reason; raise it only if the printed numbers show you have real headroom.

This is an estimate, not a guarantee - the compute-buffer figure is a rough scale-up from one reported measurement, not measured on your exact card/driver, and file sizes reported in "GB" are treated as already being GiB (`* 1024` to convert to MiB), the usual llama.cpp/HF convention. Treat the number `install.sh` proposes as a good starting point, then use the real VRAM reading it prints after you actually start the server (see above) to correct it if needed.

### Getting more headroom than that

Nothing overflows to RAM automatically: if a quant/context/batch combination doesn't fit VRAM, `llama-server` just fails to allocate it rather than spilling over on its own. Two real, opt-in ways to deliberately trade some speed for more room, both asked about right after the context-length prompt:

- **`--override-tensor` to force the last N layers' FFN weights onto CPU RAM (on by default, N=2).** This is the same underlying mechanism as `--n-cpu-moe` on MoE models, but with an important difference that changes how aggressive the default should be: on a MoE model, only one or two experts activate per token, so the CPU only does a little work per offloaded layer. Qwen3.5-9B has **no experts at all** (see above) - every offloaded layer's *entire* dense FFN matrix (three `4096x12288` matrices) gets read from RAM on every single token, every time. A [community guide to this exact technique](https://gist.github.com/DocShotgun/a02a4c0c0a57e43ff4f038b46ca66ae0) explicitly recommends *against* offloading dense FFN tensors for this reason, reserving the trick for MoE expert tensors only. Rough math at ~40 GB/s of typical dual-channel RAM bandwidth: each offloaded layer adds on the order of 2-3 ms per generated token, which is noticeable rather than free, unlike the MoE case (this is an estimate, not a measurement of your specific CPU/RAM). Because of that, `install.sh` defaults to a light touch - just 2 layers, enough to claw back a little VRAM without a real speed hit - rather than the more aggressive value you'd reach for on a MoE model. `install.sh` builds the `-ot` regex for you, e.g. for N=8: `--override-tensor "blk\.(24|25|26|27|28|29|30|31)\.ffn_(gate|up|down)\.weight=CPU"`. Raise it only if you genuinely need the room and can accept slower generation; 0 disables it entirely. **For a fast, Haiku-replacement-style workload, a smaller quant is usually the better way to free VRAM** - it keeps 100% of computation on GPU rather than trading per-token latency for headroom.
- **`--no-kv-offload` to keep the whole KV cache in system RAM instead of VRAM (off by default).** This decouples context length from VRAM almost entirely (bound by system RAM instead), but it's a real, ongoing cost for the *entire session*, not a one-time hit: every attention step now moves cache data over PCIe to system RAM and back, on every token. It's also not yet confirmed clean on every backend/model combination - there are [reported issues](https://github.com/ggml-org/llama.cpp/issues/24519) with some Vulkan/model pairings producing broken output. `install.sh` prompts for this with an explicit performance warning; only turn it on if you specifically need more context than VRAM can hold and can live with slower responses.

Neither option feeds back into the context-length recommendation above (that math assumes everything stays on GPU) - if you turn either on, check the real VRAM/behavior after starting the server, then re-run `install.sh` and raise the context or quant if there's more room than the recommendation assumed.

Before a GPU-heavy task like gaming:

```bash
distrobox stop ollama-box
```

This stops the whole container, proxy included. If local mode is toggled on when you do this, Claude Code will fail until you either restart the container or toggle back off.

## Debug logging

`litellm_config.yaml` in this repo is a *template*; `install.sh` copies it to `$CONFIG_HOME/litellm_config.yaml` (default `~/litellm_config.yaml`) with your master key patched in - edit the deployed copy, not the one in the repo, or your changes will be overwritten next time you re-run `install.sh`.

The template ships with two lines commented out at the bottom, under `general_settings`:

```yaml
general_settings:
  master_key: sk-local-dev-key
  # log_level: DEBUG
  # log_file: /var/log/litellm-proxy.log
```

Easiest path: answer "yes" to `install.sh`'s "Enable verbose LiteLLM proxy logging?" prompt, it uncomments `log_level: DEBUG` (and `log_file` too, if you also ask for disk logging) in the deployed config for you.

To do it by hand instead: uncomment `log_level: DEBUG` in the deployed file, restart the proxy (`systemctl --user restart litellm-ollama-box.service`), then watch `journalctl --user -u litellm-ollama-box.service -f` (console logging, the default) or your chosen `log_file` path (disk logging). This is what shows you the exact model-name string Claude Code sent, useful when a request fails to match any `model_name` entry.

## Manual verification

There's no automated test suite (this is glue between existing tools, not a library), so changes are verified manually:

1. `claude-local-toggle.sh status` reports the expected state after `on` and `off`.
2. With the proxy up and llama-server serving, a Claude Code session in local mode successfully completes a simple tool-calling task (file search, small edit) using the local model, confirmed via `log_level: DEBUG` in `litellm_config.yaml` showing the request routed to the local backend.
3. With llama-server stopped and local mode on, a request fails with a clean connection error rather than silently reaching a billed cloud endpoint.
4. With local mode off, Claude Code behaves identically to a machine that never installed this project.
5. `install.sh` re-run a second time with saved answers completes without prompting for anything already answered, and does not duplicate or corrupt existing systemd units or `settings.json` content.

## Known limitations

- Whether `notify-send` on your specific desktop session honors `urgency=critical` and stays up until clicked, rather than timing out, isn't confirmed against every notification daemon.
- The proxy's model-name matching assumes Claude Code sends the literal strings `claude-haiku-4-5`, `claude-sonnet-5`, or `claude-opus-4-8`. If a future Claude Code release sends a different string (a full versioned ID, for example), that request won't match anything in `litellm_config.yaml` and will fail even with the proxy up and llama-server serving. Enable `log_level: DEBUG` in the config to check what's actually arriving if this happens.
- This project assumes an existing Distrobox container with working GPU passthrough. `install.sh` checks that the container exists and exits with an error if it doesn't, it does not attempt to create or configure one, since getting GPU passthrough right on container creation isn't something worth guessing at silently. It does build `llama-server` itself inside the container if missing, but assumes CUDA/driver access already works there (e.g. Ollama or another GPU workload has run in it before).
- Starting the model server is still a manual step (open a terminal, run `start-local-llama.sh`) rather than systemd-managed; backgrounding a long-running process inside a `distrobox enter -- bash -lc` exec session is unreliable (the container runtime can tear it down when that session exits), see `todo.md`.

## License

Not yet decided. Treat this as all-rights-reserved until a LICENSE file is added.
