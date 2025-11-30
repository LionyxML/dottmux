#!/usr/bin/env bash

content=$(tmux capture-pane -J -p -t "$TMUX_PANE")

urls=$(echo "$content" | grep -Eo 'https?://[^ ]+' | sort -u)
[ -n "$urls" ] || exit 0

url=$(echo "$urls" | fzf --border --prompt "Select an URL to browse: ")
[ -n "$url" ] || exit 0

if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
else
    open "$url"
fi
