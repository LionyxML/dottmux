#!/usr/bin/env bash

# Extract the thumbnail/image URL to preview for a given link, if any.
preview_url_for() {
    case "$1" in
    *youtube.com/* | *youtu.be/*)
        v=$(printf '%s' "$1" | grep -oE '(v=|youtu\.be/|/embed/)[A-Za-z0-9_-]{11}' | head -n1 | grep -oE '[A-Za-z0-9_-]{11}$')
        [ -n "$v" ] && printf 'https://img.youtube.com/vi/%s/sddefault.jpg' "$v"
        ;;
    *.png | *.jpg | *.jpeg | *.gif | *.webp | *.bmp | \
        *.png\?* | *.jpg\?* | *.jpeg\?* | *.gif\?* | *.webp\?* | *.bmp\?*)
        printf '%s' "$1"
        ;;
    esac
}

# Re-entrant preview mode: fzf calls this same script for the highlighted line.
if [ "$1" = "--preview" ]; then
    img=$(preview_url_for "$2")
    if [ -z "$img" ]; then
        printf '%s\n\n(no preview)\n' "$2"
        exit 0
    fi
    cache="${TMPDIR:-/tmp}/tmux-browse-preview"
    mkdir -p "$cache"
    f="$cache/$(printf '%s' "$img" | cksum | tr -d ' /')"
    if [ ! -s "$f" ]; then
        curl -fsSL --max-time 5 "$img" -o "$f" || {
            rm -f "$f"
            echo 'Failed to fetch preview.'
            exit 0
        }
    fi
    # Symbol output instead of the kitty graphics protocol: renders as plain text
    # cells, so it survives tmux popups where graphics escapes are dropped.
    chafa --format symbols --symbols block+space-wide \
        --size "${FZF_PREVIEW_COLUMNS:-40}x${FZF_PREVIEW_LINES:-20}" "$f"
    exit 0
fi

content=$(tmux capture-pane -J -p -t "$TMUX_PANE")

urls=$(echo "$content" | grep -Eo 'https?://[^ ]+' | sort -u)
[ -n "$urls" ] || exit 0

url=$(echo "$urls" | fzf --border --prompt "Select an URL to browse: " \
    --preview "'$0' --preview {}" --preview-window 'right,55%,border-left')
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
command -v cha >/dev/null 2>&1 && actions+="Open with chawan\n"
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
"Open with chawan")
    kitty @ launch --type=tab --title "chawan" cha "$url"
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
