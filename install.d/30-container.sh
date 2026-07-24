# 30-container.sh
# Sourced by install.sh. Resolves CONTAINER_NAME to a real distrobox
# container, prompting if the typed name is ambiguous or missing.

# --- Sanity check: does the container exist? ---
# Case-insensitive on purpose: container-manager GUIs (Kontainer, etc.) often
# display names title-cased even though the underlying distrobox container is
# lowercase. Match loosely, then resolve to whatever casing distrobox itself
# reports, so every later command (distrobox enter/stop) uses the real name.
# If the typed name doesn't match exactly one container (zero matches, or
# more than one - e.g. typing "box" when you have both "ollama-box" and
# "dev-box"), fall back to listing everything and letting you pick, rather
# than guessing or just failing.
resolve_container_name() {
  local DISTROBOX_LIST_RAW ALL_NAMES MATCH_COUNT RESOLVED_NAME NAMES PICK NAME_LINE
  DISTROBOX_LIST_RAW="$(distrobox list 2>/dev/null)"
  if [ -z "$DISTROBOX_LIST_RAW" ]; then
    echo "ERROR: 'distrobox list' returned nothing - is distrobox installed, and" >&2
    echo "do you have any containers created yet?" >&2
    exit 1
  fi

  # distrobox list output is a table; the name is the second field, whitespace
  # padded, header row first. Matching is restricted to that parsed name field,
  # not the whole row - grepping the raw row would also match container names
  # that only appear in the image column (e.g. typing "fedora" when a
  # container's base image is fedora:43 but its actual name is something else).
  ALL_NAMES="$(echo "$DISTROBOX_LIST_RAW" | tail -n +2 | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
  MATCH_COUNT="$(echo "$ALL_NAMES" | grep -ic "$CONTAINER_NAME" || true)"

  if [ "$MATCH_COUNT" = "1" ]; then
    RESOLVED_NAME="$(echo "$ALL_NAMES" | grep -i "$CONTAINER_NAME")"
    if [ "$RESOLVED_NAME" != "$CONTAINER_NAME" ]; then
      echo "Note: using '$RESOLVED_NAME' (the actual container name), not '$CONTAINER_NAME' as typed."
      CONTAINER_NAME="$RESOLVED_NAME"
      save_config
    fi
  else
    if [ "$MATCH_COUNT" -gt 1 ] 2>/dev/null; then
      echo "'$CONTAINER_NAME' matches more than one container - pick the one you mean:"
    else
      echo "No distrobox container matching '$CONTAINER_NAME' was found. Here's what's actually there:"
    fi
    echo
    echo "$DISTROBOX_LIST_RAW"
    echo

    NAMES="$ALL_NAMES"
    if [ -z "$NAMES" ]; then
      echo "ERROR: couldn't parse any container names out of the listing above." >&2
      exit 1
    fi

    declare -a NAME_ARR=()
    PICK_NUM=1
    while IFS= read -r NAME_LINE; do
      [ -z "$NAME_LINE" ] && continue
      NAME_ARR+=("$NAME_LINE")
      echo "  $PICK_NUM) $NAME_LINE"
      PICK_NUM=$((PICK_NUM + 1))
    done <<< "$NAMES"

    read -rp "Pick a number: " PICK
    if ! [[ "$PICK" =~ ^[0-9]+$ ]] || [ "$PICK" -lt 1 ] || [ "$PICK" -gt "${#NAME_ARR[@]}" ]; then
      echo "ERROR: '$PICK' isn't a valid choice." >&2
      exit 1
    fi
    CONTAINER_NAME="${NAME_ARR[$((PICK - 1))]}"
    save_config
    echo "Using '$CONTAINER_NAME', saved as the new default for next time."
  fi
  log "Found container $CONTAINER_NAME"
}
