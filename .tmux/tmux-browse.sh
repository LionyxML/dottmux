#!/usr/bin/env bash

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
CACHE="${TMPDIR:-/tmp}/tmux-browse-preview"
# Previews are cached across invocations (fzf re-runs them on every redraw), so
# nothing here is short-lived by nature. Entries older than this are swept when
# the picker opens; 0 disables the sweep.
CACHE_TTL_MIN=${TMUX_BROWSE_CACHE_TTL_MIN:-1440}

# rimgo (imgur frontend) instances, tried in order when imgur itself is down,
# rate-limiting, or UA-blocking. Instances come and go and some sit behind JS
# anti-bot challenges curl cannot pass, so override the list when needed:
#   export TMUX_BROWSE_IMGUR_MIRRORS='rimgo.foo.tld other.tld'
IMGUR_MIRRORS=${TMUX_BROWSE_IMGUR_MIRRORS:-'rimgo.canine.tools rimgo.manerakai.com rimgo.catsarch.com rimgo.bloat.cat rimgo.vern.cc imgur.artemislena.eu'}

# Image hosts whose pages are worth scraping for an og:image (albums, galleries,
# single-image permalinks). Kept to an allowlist so hovering a link in fzf never
# fetches arbitrary pages.
is_image_host() {
    case "$1" in
    *//imgur.com/* | *.imgur.com/* | \
        *//flickr.com/* | *.flickr.com/* | \
        *//giphy.com/* | *.giphy.com/* | \
        *//tenor.com/* | *.tenor.com/* | \
        *//ibb.co/* | *.ibb.co/* | *.imgbb.com/* | \
        *//postimg.cc/* | *.postimg.cc/* | \
        *//prnt.sc/* | *//imgbox.com/* | *.imgbox.com/* | \
        *//redd.it/* | *.redd.it/* | *//reddit.com/*/comments/* | *.reddit.com/*/comments/* | \
        *//unsplash.com/* | *.unsplash.com/* | \
        *//deviantart.com/* | *.deviantart.com/* | \
        *//artstation.com/* | *.artstation.com/* | \
        *commons.wikimedia.org/wiki/File:*)
        return 0
        ;;
    esac
    return 1
}

is_audio_url() {
    case "$1" in
    *.mp3 | *.m4a | *.aac | *.opus | *.ogg | *.oga | *.flac | *.wav | *.wma | *.aif | *.aiff | \
        *.mp3\?* | *.m4a\?* | *.aac\?* | *.opus\?* | *.ogg\?* | *.oga\?* | *.flac\?* | \
        *.wav\?* | *.wma\?* | *.aif\?* | *.aiff\?*)
        return 0
        ;;
    esac
    return 1
}

# Scrape a preview image out of a page: og:image/twitter:image if present,
# otherwise the first content <img> (rimgo, for one, ships no social meta tags).
# Prints nothing when the page has neither, or when the fetch fails.
og_image_for() {
    page=$1
    html=$(curl -fsSL --connect-timeout 3 --max-time "${2:-8}" -A "$UA" -H 'Accept: text/html' "$page" 2>/dev/null | head -c 300000) || return 0
    [ -n "$html" ] || return 0
    html=$(printf '%s' "$html" | tr '\n\r\t' '   ')
    meta=$(printf '%s' "$html" | grep -oE '<meta[^>]*>' |
        grep -iE '(og:image(:secure_url|:url)?|twitter:image(:src)?)' | head -n1)
    if [ -n "$meta" ]; then
        img=$(printf '%s' "$meta" | grep -oE 'content=("[^"]*"|'"'"'[^'"'"']*'"'"')' | head -n1 |
            sed -E 's/^content=.//; s/.$//; s/&amp;/\&/g')
    else
        # First <img> pointing at a real image file, skipping site chrome
        # (logos, icons, favicons) which lives under /static, /assets, etc.
        img=$(printf '%s' "$html" | grep -oE '<img[^>]*>' |
            grep -oE 'src=("[^"]*"|'"'"'[^'"'"']*'"'"')' |
            sed -E 's/^src=.//; s/.$//; s/&amp;/\&/g' |
            grep -iE '\.(png|jpe?g|gif|webp|bmp)(\?|$)' |
            grep -viE '(/static/|/assets/|/icons?/|favicon|logo|sprite|avatar|/emoji)' |
            head -n1)
    fi
    [ -n "$img" ] || return 0
    # Resolve protocol-relative and root-relative URLs against the page.
    case "$img" in
    //*) img="https:$img" ;;
    /*) img="$(printf '%s' "$page" | grep -oE '^https?://[^/]+')$img" ;;
    http*) ;;
    *) return 0 ;;
    esac
    printf '%s' "$img"
}

# imgur page -> og:image, falling back to rimgo mirrors when imgur gives us
# nothing (down, 429, UA block). A mirror serving an anti-bot challenge has no
# og:image either, so it just falls through to the next one.
imgur_image_for() {
    img=$(og_image_for "$1")
    [ -n "$img" ] && {
        printf '%s' "$img"
        return 0
    }
    path=${1#*://}
    path=${path#*/}
    for m in $IMGUR_MIRRORS; do
        # Short timeout per mirror: dead instances must not stall the preview.
        img=$(og_image_for "https://$m/$path" 4)
        [ -n "$img" ] && {
            printf '%s' "$img"
            return 0
        }
    done
}

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
    *)
        is_image_host "$1" || return 0
        # Cache the scrape: fzf re-runs the preview on every redraw.
        mkdir -p "$CACHE"
        u="$CACHE/$(printf '%s' "$1" | cksum | tr -d ' /').url"
        # Only a successful scrape is cached, so a rate-limited host is retried.
        if [ ! -s "$u" ]; then
            case "$1" in
            *//imgur.com/* | *.imgur.com/*) imgur_image_for "$1" >"$u" ;;
            *) og_image_for "$1" >"$u" ;;
            esac
            [ -s "$u" ] || rm -f "$u"
        fi
        [ -s "$u" ] && cat "$u"
        ;;
    esac
}

# Audio links have nothing to render, so preview their tags instead. ffprobe
# reads the container header over http and stops, so this costs a few KB, not
# the whole file; without ffprobe the preview falls back to type and size.
audio_preview() {
    mkdir -p "$CACHE"
    t="$CACHE/$(printf '%s' "$1" | cksum | tr -d ' /').audio"
    if [ ! -s "$t" ]; then
        {
            head=$(curl -fsSLI --connect-timeout 3 --max-time 5 -A "$UA" "$1" 2>/dev/null | tr -d '\r')
            # -f does not suppress headers of a failed HEAD, so an error page
            # would be reported as the file: keep only a 2xx response.
            case "$(printf '%s\n' "$head" | grep -iE '^HTTP/' | tail -n1 | awk '{print $2}')" in
            2*) ;;
            *) head='' ;;
            esac
            size=$(printf '%s\n' "$head" | grep -i '^content-length:' | tail -n1 | sed -E 's/^[^:]*: *//')
            ctype=$(printf '%s\n' "$head" | grep -i '^content-type:' | tail -n1 | sed -E 's/^[^:]*: *//; s/;.*//')
            if command -v ffprobe >/dev/null 2>&1; then
                # rw_timeout is in microseconds: a stalled host must not hang fzf.
                ffprobe -v quiet -rw_timeout 5000000 -user_agent "$UA" \
                    -show_format -of default=noprint_wrappers=1 "$1" 2>/dev/null |
                    awk -F'\n' '
                        {
                            i = index($0, "=")
                            if (!i) next
                            k = tolower(substr($0, 1, i - 1)); v = substr($0, i + 1)
                            if (v == "" || v == "N/A") next
                            if (k ~ /^tag:(title|artist|album|date)$/) { sub(/^tag:/, "", k); f[k] = v }
                            else if (k == "duration" || k == "bit_rate" || k == "format_long_name") f[k] = v
                        }
                        END {
                            if (f["title"])  printf "title     %s\n", f["title"]
                            if (f["artist"]) printf "artist    %s\n", f["artist"]
                            if (f["album"])  printf "album     %s\n", f["album"]
                            if (f["date"])   printf "date      %s\n", f["date"]
                            if (f["duration"]) {
                                s = int(f["duration"] + 0.5)
                                if (s >= 3600) printf "duration  %d:%02d:%02d\n", s/3600, (s%3600)/60, s%60
                                else printf "duration  %d:%02d\n", s/60, s%60
                            }
                            if (f["bit_rate"])         printf "bitrate   %d kbps\n", f["bit_rate"] / 1000
                            if (f["format_long_name"]) printf "format    %s\n", f["format_long_name"]
                        }'
            fi
            [ -n "$size" ] && awk -v b="$size" 'BEGIN{printf "size      %.1f MB\n", b/1048576}'
            [ -n "$ctype" ] && printf 'type      %s\n' "$ctype"
        } >"$t"
        [ -s "$t" ] || rm -f "$t"
    fi
    printf '%s\n\n' "$1"
    if [ -s "$t" ]; then
        cat "$t"
    else
        printf '(audio - no metadata)\n'
    fi
}

# Render a page as text for links that have no image to show. Dumped with a
# text browser so the preview reads like the page, not like markup.
text_preview() {
    cols=${FZF_PREVIEW_COLUMNS:-80}
    mkdir -p "$CACHE"
    # Width is part of the key: a dump is only valid for the pane it was made for.
    t="$CACHE/$(printf '%s@%s' "$1" "$cols" | cksum | tr -d ' /').txt"
    if [ ! -s "$t" ]; then
        hdr="$CACHE/.hdr.$$"
        # fzf kills the preview on every scroll, which can land between curl
        # creating the header file and the rm below; drop it on the way out.
        # SIGKILL still orphans one, hence the sweep when the picker opens.
        trap 'rm -f "$hdr"' EXIT
        trap 'rm -f "$hdr"; exit 143' TERM INT HUP
        # LC_ALL=C: under a UTF-8 locale tr aborts on binary bodies with
        # "Illegal byte sequence", straight into the preview pane.
        html=$(curl -fsSL --connect-timeout 3 --max-time 6 -A "$UA" \
            -H 'Accept: text/html' -D "$hdr" "$1" 2>/dev/null | head -c 500000 | LC_ALL=C tr -d '\0')
        ctype=$(tr -d '\r' <"$hdr" 2>/dev/null | grep -i '^content-type:' | tail -n1 |
            sed -E 's/^[^:]*: *//; s/;.*//')
        rm -f "$hdr"
        trap - EXIT TERM INT HUP
        [ -n "$html" ] || {
            printf '%s\n\n(no preview)\n' "$1"
            return 0
        }
        # Binary payloads (PDFs, archives, media) dump as garbage; name the type
        # instead. Cached like a dump, so redraws do not refetch them.
        case "$html" in %PDF*) ctype=${ctype:-application/pdf} ;; esac
        case "$ctype" in
        '' | text/* | *xhtml* | *json* | *xml*) ;;
        *) printf '(%s)\n' "$ctype" >"$t" ;;
        esac
    fi
    if [ ! -s "$t" ]; then
        title=$(printf '%s' "$html" | tr '\n' ' ' |
            grep -oiE '<title[^>]*>[^<]*' | head -n1 | sed -E 's/^<title[^>]*>//; s/^ +//; s/ +$//')
        # curl + strip is the default path: no browser process, no config of
        # theirs to honour. w3m/cha only stand in where perl is missing.
        if command -v perl >/dev/null 2>&1; then
            dump=$(printf '%s' "$html" | perl -0777 -pe '
                s{<(script|style|head|noscript|svg)\b.*?</\1>}{}gis;
                s{<!--.*?-->}{}gs;
                s{<br\s*/?>}{\n}gi;
                s{<li\b[^>]*>}{\n  - }gi;
                s{</(p|div|li|tr|h[1-6]|section|article|ul|ol|blockquote)>}{\n}gi;
                s{<[^>]+>}{ }g;
                s{&nbsp;}{ }g; s{&amp;}{&}g; s{&lt;}{<}g; s{&gt;}{>}g;
                s{&quot;}{"}g; s{&#0?39;}{'"'"'}g; s{&#x27;}{'"'"'}g; s{&hellip;}{...}g;
                s{[ \t]+}{ }g; s{^ +}{}mg; s{ +$}{}mg;
            ' | fold -s -w "$cols")
        elif command -v w3m >/dev/null 2>&1; then
            dump=$(printf '%s' "$html" | w3m -dump -T text/html -cols "$cols" 2>/dev/null)
        elif command -v cha >/dev/null 2>&1; then
            dump=$(printf '%s' "$html" | COLUMNS="$cols" cha -T text/html -d 2>/dev/null)
        else
            dump=$(printf '%s' "$html" | tr '\n' ' ' | sed -E 's/<[^>]*>/ /g' | tr -s ' ' | fold -s -w "$cols")
        fi
        [ -n "$title" ] && dump=$(printf '%s\n\n%s' "$(printf '%s' "$title" | fold -s -w "$cols")" "$dump")
        # Squeeze runs of blank lines, cap the dump so the cache stays small.
        printf '%s' "$dump" | awk 'NF{b=0} !NF{b++} b<2' | head -n 400 >"$t"
        [ -s "$t" ] || rm -f "$t"
    fi
    if [ -s "$t" ]; then
        printf '%s\n\n' "$1"
        cat "$t"
    else
        printf '%s\n\n(no preview)\n' "$1"
    fi
}

# Re-entrant preview mode: fzf calls this same script for the highlighted line.
if [ "$1" = "--preview" ]; then
    img=$(preview_url_for "$2")
    if [ -z "$img" ]; then
        if is_audio_url "$2"; then
            audio_preview "$2"
        else
            text_preview "$2"
        fi
        exit 0
    fi
    mkdir -p "$CACHE"
    f="$CACHE/$(printf '%s' "$img" | cksum | tr -d ' /')"
    if [ ! -s "$f" ]; then
        curl -fsSL --max-time 5 -A "$UA" "$img" -o "$f" || {
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

# Evict stale previews once per picker launch, never in the preview path where
# it would run on every redraw. Orphaned header files go regardless of age.
if [ -d "$CACHE" ]; then
    find "$CACHE" -type f -name '.hdr.*' -mmin +5 -delete 2>/dev/null
    [ "$CACHE_TTL_MIN" -gt 0 ] 2>/dev/null &&
        find "$CACHE" -type f -mmin "+$CACHE_TTL_MIN" -delete 2>/dev/null
fi

content=$(tmux capture-pane -J -p -t "$TMUX_PANE")

# Pull URLs out of the pane, excluding characters that can never appear in one
# (quotes, brackets, backticks) and then trimming the punctuation that trails a
# URL in prose: `see http://x.dev/a.` or `("http://x.dev/b")`. Closing brackets
# are kept when the URL opened them, so wiki links like /Foo_(bar) survive.
urls=$(printf '%s\n' "$content" |
    grep -oE '(https?://|www\.)[^[:space:]<>"'"'"'`|\\^{}]+' |
    awk '{
        u = $0
        do {
            prev = u
            while (u ~ /[.,;:!?@*_~"'"'"'\140]$/) sub(/.$/, "", u)
            if (u ~ /\)$/ && gsub(/\)/, ")", u) > gsub(/\(/, "(", u)) sub(/.$/, "", u)
            if (u ~ /\]$/ && gsub(/\]/, "]", u) > gsub(/\[/, "[", u)) sub(/.$/, "", u)
        } while (u != prev)
        if (u ~ /^www\./) u = "https://" u
        if (u ~ /^https?:\/\/[^\/]+\./) print u
    }' | sort -u)
# Nothing to select: still show fzf so the popup does not blink open and shut,
# leaving no clue why. Any key closes it.
[ -n "$urls" ] || {
    printf 'No URLs found in this pane.\n' |
        fzf --tmux center --border --color=border:blue --prompt "Select an URL to browse: " \
            --header 'Press ESC or RET to close' --no-preview >/dev/null
    exit 0
}

url=$(echo "$urls" | fzf --tmux center --border --color=border:blue --prompt "Select an URL to browse: " \
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
case "$url" in
*youtube.com/* | *youtu.be/*) is_youtube=1 ;;
esac
is_audio=0
is_audio_url "$url" && is_audio=1
# Thumbnail for YouTube, og:image for image-host pages (imgur albums, etc).
thumb=""
[ "$is_image" -eq 0 ] && [ "$is_audio" -eq 0 ] && thumb=$(preview_url_for "$url")

# Build action menu: smart default first, then the always-available options.
actions=""
[ "$is_audio" -eq 1 ] && actions+="Play with mpv (pane)\n"
[ "$is_image" -eq 1 ] && actions+="Preview image (kitty icat)\n"
[ "$is_youtube" -eq 1 ] && actions+="Play with mpv\n"
if [ -n "$thumb" ]; then
    if [ "$is_youtube" -eq 1 ]; then
        actions+="Preview thumbnail (kitty icat)\n"
    else
        actions+="Preview page image (kitty icat)\n"
    fi
fi
command -v cha >/dev/null 2>&1 && actions+="Open with chawan\n"
actions+="Open with w3m\nOpen in default browser\nCopy to clipboard"

action=$(printf '%b' "$actions" | fzf --tmux center --border --color=border:blue --prompt "Action: ")
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

# Show an image in a new kitty tab, scaled to fill it. Bare `icat` draws at
# native pixel size, which leaves a small image marooned in a corner of a big
# tab; --place + --scale-up fits it to the window, aspect ratio preserved.
icat_tab() {
    kitty @ launch --type=tab --title "$1" bash -c "
            f=\$(mktemp)
            if curl -fsSL -A '$UA' '$2' -o \"\$f\"; then
                cols=\$(tput cols 2>/dev/null || echo 80)
                rows=\$(tput lines 2>/dev/null || echo 24)
                kitty +kitten icat --scale-up --place \"\${cols}x\$((rows - 1))@0x0\" \"\$f\"
                tput cup \$((rows - 1)) 0 2>/dev/null
            else
                echo 'Failed to fetch image.'
            fi
            rm -f \"\$f\"
            read -rsp 'Press RET to close...'
        "
}

case "$action" in
"Preview image (kitty icat)")
    icat_tab image "$url"
    ;;
"Preview thumbnail (kitty icat)" | "Preview page image (kitty icat)")
    icat_tab thumbnail "$thumb"
    ;;
"Play with mpv (pane)")
    # Audio needs no window, so it stays inside tmux: a short split keeps mpv's
    # keys (p, 9/0, q) one pane away and dies with the session.
    tmux split-window -v -l 8 -t "$TMUX_PANE" \
        "mpv --no-video --term-osd-bar '$url'; read -rsp 'Press RET to close...'"
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
