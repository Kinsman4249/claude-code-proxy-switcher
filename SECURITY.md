# Security Policy

## Supported Versions

Only the most recent release receives security fixes, regardless of version number. Older releases, including older major versions, are not backported.

| Version         | Supported          |
| --------------- | ------------------- |
| Latest release  | :white_check_mark: |
| Anything older  | :x:                 |

If you need a fix and you're on an older release, upgrade to the latest release first.

This policy assumes a solo maintainer, which is the normal setup for this project. If it grows into a team effort with users who genuinely need multiple supported release lines, this file can be adapted to add a longer support window instead.

## Reporting a Vulnerability

If you find a security issue in this project, **please do not file a public GitHub issue**.

Instead, open a private GitHub Security Advisory:

1. Go to the [Security tab](https://github.com/Kinsman4249/claude-code-proxy-switcher/security) of this repository.
2. Click **"Report a vulnerability"**.
3. Provide as much detail as possible: affected version, reproduction steps, impact, and any suggested mitigation.

You should receive an acknowledgment within a few business days. If the issue is confirmed, a fix will be developed privately and released as a patch version. You'll be credited in the release notes (or anonymously, if you prefer).

## Scope

In-scope:

- Vulnerabilities in `install.sh`, `claude-local-toggle.sh`, or `claude-local-desktop-toggle.sh`
- Insecure default configurations in `litellm_config.yaml` or the systemd unit files
- Any path that could cause an Anthropic API key to be required, stored, or transmitted when local mode is active (this project's entire design goal is that local mode never touches a billed cloud path)
- Any path that could allow privilege escalation or unauthorized access to credentials on the host or inside the Distrobox container

Out of scope:

- Vulnerabilities in upstream dependencies (LiteLLM, Ollama, Distrobox, Qwen model weights) - please report those to the dependency's own maintainers
- Vulnerabilities in the Anthropic API or Claude Code itself - report those to Anthropic directly
- General hardening suggestions for your own host or environment (use a feature request issue instead)
