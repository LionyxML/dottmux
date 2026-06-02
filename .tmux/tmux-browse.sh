#!/usr/bin/env bash

content=$(tmux capture-pane -J -p -t "$TMUX_PANE")

urls=$(echo "$content" | grep -Eo 'https?://[^ ]+' | sort -u)
[ -n "$urls" ] || exit 0

url=$(echo "$urls" | fzf --border --prompt "Select an URL to browse: ")
[ -n "$url" ] || exit 0

# Classify URL so the most relevant action is offered first.
is_image=0
is_youtube=0
case "$url" in
*.png | *.jpg | *.jpeg | *.gif | *.webp | *.bmp | *.svg | \
    *.png\?* | *.jpg\?* | *.jpeg\?* | *.gif\?* | *.webp\?* | *.bmp\?* | *.svg\?*)
    is_image=1
    ;;
esac
thumb=""
case "$url" in
*youtube.com/* | *youtu.be/*)
    is_youtube=1
    # Pull the 11-char video id from watch?v=, youtu.be/ or /embed/ forms.
    vid=$(printf '%s' "$url" | grep -oE '(v=|youtu\.be/|/embed/)[A-Za-z0-9_-]{11}' | head -n1 | grep -oE '[A-Za-z0-9_-]{11}$')
    [ -n "$vid" ] && thumb="https://img.youtube.com/vi/$vid/sddefault.jpg"
    ;;
esac

# Build action menu: smart default first, then the always-available options.
actions=""
[ "$is_image" -eq 1 ] && actions+="Preview image (kitty icat)\n"
[ "$is_youtube" -eq 1 ] && actions+="Play with mpv\n"
[ -n "$thumb" ] && actions+="Preview thumbnail (kitty icat)\n"
actions+="Open with w3m\nOpen in default browser\nCopy to clipboard"

action=$(printf '%b' "$actions" | fzf --border --prompt "Action: ")
[ -n "$action" ] || exit 0

open_browser() {
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        open "$url"
    fi
}

copy_clipboard() {
    if [ "$(uname)" = "Darwin" ]; then
        printf '%s' "$url" | pbcopy
    elif [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$url" | wl-copy
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$url" | xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$url" | xsel --clipboard --input
    else
        echo 'No clipboard tool found (pbcopy/wl-copy/xclip/xsel).' >&2
    fi
}

case "$action" in
"Preview image (kitty icat)")
    kitty @ launch --type=tab --title "image" bash -c "
            f=\$(mktemp)
            if curl -fsSL '$url' -o \"\$f\"; then
                kitty +kitten icat \"\$f\"
            else
                echo 'Failed to fetch image.'
            fi
            rm -f \"\$f\"
            read -rsp 'Press RET to close...'
        "
    ;;
"Preview thumbnail (kitty icat)")
    kitty @ launch --type=tab --title "thumbnail" bash -c "
            f=\$(mktemp)
            if curl -fsSL '$thumb' -o \"\$f\"; then
                kitty +kitten icat \"\$f\"
            else
                echo 'Failed to fetch thumbnail.'
            fi
            rm -f \"\$f\"
            read -rsp 'Press RET to close...'
        "
    ;;
"Play with mpv")
    kitty @ launch --type=tab --title "mpv" bash -c "
            mpv '$url'
            read -rsp 'Press RET to close...'
        "
    ;;
"Open with w3m")
    kitty @ launch --type=tab --title "w3m" w3m "$url"
    ;;
"Open in default browser")
    open_browser
    ;;
"Copy to clipboard")
    copy_clipboard
    ;;
esac
