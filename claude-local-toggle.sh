#!/usr/bin/env bash
# claude-local-toggle.sh
# On/off switch for routing Claude Code (CLI and VS Code/VSCodium extension)
# through the local-only LiteLLM proxy instead of your normal Pro
# subscription auth.
#
# ON:  edits ~/.claude/settings.json to add the proxy env block. Every
#      Claude Code request, main session and sub-agents, goes to local Qwen.
#      No API key involved anywhere, nothing bills. Sonnet/Opus are not
#      available while this is on, use it for small tasks only.
# OFF: removes that env block. Claude Code goes back to fully normal
#      behavior, Pro subscription auth, Sonnet/Opus available, as if this
#      setup didn't exist.
#
# Usage:
#   ./claude-local-toggle.sh on
#   ./claude-local-toggle.sh off
#   ./claude-local-toggle.sh status
#
# After toggling, reload the VS Code/VSCodium window (Ctrl+Shift+P >
# "Reload Window") so the extension re-reads settings.json. The extension
# does not pick up changes to this file live.

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
BACKUP_FILE="$HOME/.claude/settings.json.pre-local-toggle.bak"
PROXY_URL="http://localhost:4000"
PROXY_TOKEN="sk-local-dev-key"   # must match master_key in litellm_config.yaml

ACTION="${1:-}"

mkdir -p "$(dirname "$SETTINGS_FILE")"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

case "$ACTION" in
  on)
    # Back up whatever's there now, once, so "off" can always get back to a
    # known-good state even if this script is run repeatedly.
    if [ ! -f "$BACKUP_FILE" ]; then
      cp "$SETTINGS_FILE" "$BACKUP_FILE"
    fi

    if ! curl -s -o /dev/null -w "%{http_code}" "$PROXY_URL/health" | grep -q "200"; then
      echo "Warning: proxy not responding at $PROXY_URL." >&2
      echo "Check: systemctl --user status litellm-ollama-box.service" >&2
      echo "Turning local mode on anyway, but Claude Code will fail until the proxy is up." >&2
    fi

    python3 - "$SETTINGS_FILE" "$PROXY_URL" "$PROXY_TOKEN" << 'PYEOF'
import json, sys
path, proxy_url, proxy_token = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
data["env"] = {
    "ANTHROPIC_BASE_URL": proxy_url,
    "ANTHROPIC_AUTH_TOKEN": proxy_token,
    "ANTHROPIC_API_KEY": ""
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    echo "Local mode ON. Reload the VS Code/VSCodium window to apply."
    echo "Reminder: Sonnet/Opus are not reachable until you switch this off."
    ;;

  off)
    python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data.pop("env", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    echo "Local mode OFF. Reload the VS Code/VSCodium window to apply."
    echo "Claude Code is back on normal Pro subscription auth."
    ;;

  status)
    python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
env = data.get("env", {})
if env.get("ANTHROPIC_BASE_URL"):
    print(f"Local mode is ON, pointed at {env['ANTHROPIC_BASE_URL']}")
else:
    print("Local mode is OFF, using normal Pro subscription auth.")
PYEOF
    ;;

  *)
    echo "Usage: $0 {on|off|status}" >&2
    exit 1
    ;;
esac
