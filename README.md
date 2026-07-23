# claude-code-proxy-switcher

An on/off switch for routing Claude Code through a local model instead of your Anthropic Pro/Max subscription, with no API key anywhere and no cloud fallback. When it's off, Claude Code behaves exactly as if this project didn't exist, normal subscription auth, Sonnet and Opus available. When it's on, every model Claude Code might call, main session or sub-agent, routes to a local Qwen3.5-9B model running under Ollama, meant for small, cheap tasks where you don't want to spend Pro usage at all.

## Why this exists

Claude Code is agentic: a lot of what it does per session is mechanical (file search, `grep`, listing directories, small reads) rather than reasoning-heavy. Running that mechanical work through a frontier model is more capability than the task needs. This project gives you a deliberate, visible switch to route that kind of work to a local model instead, without touching your subscription usage or ever requiring a billed API key.

It does not try to be a hybrid router that transparently falls back to cloud when Ollama isn't running. Anthropic's April 2026 policy change blocking subscription OAuth tokens in third-party proxies ruled out a fallback that draws from Pro/Max usage instead of billed API usage. Rather than accept surprise direct billing on the fallback path, this project has no cloud path in its proxy config at all: local mode either uses your local model, or it fails cleanly with a connection error. No middle ground, no accidental charges.

## Requirements

- A Linux host with [Distrobox](https://github.com/89luca89/distrobox) and a container with [Ollama](https://ollama.com) installed inside it. Built and tested on Bazzite (KDE Plasma), but the mechanism (systemd `--user` units calling into `distrobox enter`) has no Bazzite-specific dependency and should work on any distro with Distrobox and systemd.
- [LiteLLM](https://docs.litellm.ai) (`pip install 'litellm[proxy]'`) installed inside that container.
- Claude Code, used either via the CLI or the VS Code/VSCodium extension.
- Roughly 8 GB of VRAM headroom to run Qwen3.5-9B at a reasonable quant and context length. See `local-model.Modelfile` for the exact quant and the reasoning behind it.

## Quickstart

```bash
git clone https://github.com/Kinsman4249/claude-code-proxy-switcher.git
cd claude-code-proxy-switcher
chmod +x install.sh
./install.sh
```

The installer is interactive: it asks about your container name, proxy port and token, whether to download the model now, whether to enable systemd lingering, and whether to install a desktop toggle icon. Every answer is saved to `~/.config/claude-local-setup.conf` and shown as the default on the next run, so re-running the installer is mostly pressing Enter.

## What's in this repo

```
.
|-- litellm_config.yaml            - LiteLLM proxy config, local-only, no API key, no cloud entries
|-- local-model.Modelfile           - builds the Ollama tag from Qwen3.5-9B (UD-Q5_K_XL, text-only, 20K context)
|-- litellm-ollama-box.service      - systemd --user unit, starts only the proxy at login, no model auto-load
|-- distrobox-reminder.service      - systemd --user unit, login notification reminding you to stop the container before gaming
|-- claude-local-toggle.sh          - the actual switch: on/off/status, edits ~/.claude/settings.json
|-- claude-local-desktop-toggle.sh  - wrapper for the desktop icon: flips state, confirms via notification
|-- claude-local-toggle.desktop     - desktop launcher entry
`-- install.sh                      - interactive installer running every step below, with saved defaults
```

## How the switch works

`~/.claude/settings.json` supports an `env` block that both the Claude Code CLI and the VS Code/VSCodium extension read at startup. `claude-local-toggle.sh` adds or removes `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and an empty `ANTHROPIC_API_KEY` from that block:

```bash
claude-local-toggle.sh on       # route everything through the local proxy
claude-local-toggle.sh off      # back to normal Pro/Max subscription auth
claude-local-toggle.sh status   # check which state you're in
```

After toggling, reload the VS Code/VSCodium window (`Ctrl+Shift+P` > "Reload Window"), the extension only reads `settings.json` at startup, not live.

If you installed the desktop icon, double-clicking it does the same thing without a terminal: it checks the current state, flips it, and confirms the new state with a desktop notification.

## Starting and stopping the model itself

The proxy running is not the same as the model being loaded. Nothing loads automatically at boot:

```bash
distrobox enter ollama-box
ollama serve
```

Before a GPU-heavy task like gaming:

```bash
distrobox stop ollama-box
```

This stops the whole container, proxy included. If local mode is toggled on when you do this, Claude Code will fail until you either restart the container or toggle back off.

## Manual verification

There's no automated test suite (this is glue between existing tools, not a library), so changes are verified manually:

1. `claude-local-toggle.sh status` reports the expected state after `on` and `off`.
2. With the proxy up and Ollama serving, a Claude Code session in local mode successfully completes a simple tool-calling task (file search, small edit) using the local model, confirmed via `log_level: DEBUG` in `litellm_config.yaml` showing the request routed to the local backend.
3. With Ollama stopped and local mode on, a request fails with a clean connection error rather than silently reaching a billed cloud endpoint.
4. With local mode off, Claude Code behaves identically to a machine that never installed this project.
5. `install.sh` re-run a second time with saved answers completes without prompting for anything already answered, and does not duplicate or corrupt existing systemd units or `settings.json` content.

## Known limitations

- Whether `notify-send` on your specific desktop session honors `urgency=critical` and stays up until clicked, rather than timing out, isn't confirmed against every notification daemon.
- The proxy's model-name matching assumes Claude Code sends the literal strings `claude-haiku-4-5`, `claude-sonnet-5`, or `claude-opus-4-8`. If a future Claude Code release sends a different string (a full versioned ID, for example), that request won't match anything in `litellm_config.yaml` and will fail even with the proxy up and Ollama serving. Enable `log_level: DEBUG` in the config to check what's actually arriving if this happens.
- This project assumes an existing Distrobox container with Ollama already installed. `install.sh` checks that the container exists and exits with an error if it doesn't, it does not attempt to create or configure one, since getting GPU passthrough right on container creation isn't something worth guessing at silently.

## License

Not yet decided. Treat this as all-rights-reserved until a LICENSE file is added.
