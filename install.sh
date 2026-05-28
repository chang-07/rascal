#!/usr/bin/env bash
# install.sh — build FinderTwo (release) and install it for everyday use.
#
# Result:
#   - /Applications/FinderTwo.app          (Spotlight finds it; click to launch)
#   - /usr/local/bin/ft                    (CLI shortcut; opens the app)
#
# After install:
#   ft                  open at current directory
#   ft ~/Downloads      open at a specific path
#   ft .                open at $PWD
#   Spotlight → "FinderTwo"   from anywhere
#   Cmd+Space → "ft" works once Spotlight has indexed the binary
#
# Re-run any time to reinstall after updates.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$ROOT/build/FinderTwo.app"
APP_DEST_SYS="/Applications/FinderTwo.app"
APP_DEST_USER="$HOME/Applications/FinderTwo.app"
BIN_DIRS=("/usr/local/bin" "$HOME/.local/bin")

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

bold "→ Building FinderTwo (release)…"
"$ROOT/build.sh" release > /dev/null
dim "  built at $APP_SRC"

# Pick install destination — system if writable, otherwise user.
if mkdir -p /Applications 2>/dev/null && [[ -w /Applications ]]; then
    APP_DEST="$APP_DEST_SYS"
elif sudo -n true 2>/dev/null; then
    APP_DEST="$APP_DEST_SYS"
    NEED_SUDO=1
else
    mkdir -p "$HOME/Applications"
    APP_DEST="$APP_DEST_USER"
fi

bold "→ Installing app to ${APP_DEST}…"
if [[ "${NEED_SUDO:-0}" == "1" ]]; then
    sudo rm -rf "$APP_DEST"
    sudo cp -R "$APP_SRC" "$APP_DEST"
else
    rm -rf "$APP_DEST"
    cp -R "$APP_SRC" "$APP_DEST"
fi
dim "  copied"

# Pick a bin dir on PATH. Prefer a writable system dir; otherwise fall back
# to a user dir (so install.sh works without sudo).
chosen_bin=""
for d in "${BIN_DIRS[@]}"; do
    if [[ -d "$d" && -w "$d" ]]; then
        chosen_bin="$d"
        break
    fi
done
# If nothing writable, try non-interactive sudo on /usr/local/bin. If sudo
# would prompt for a password, fall back to ~/.local/bin so the install
# completes silently.
if [[ -z "$chosen_bin" ]]; then
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p /usr/local/bin
        chosen_bin="/usr/local/bin"
        NEED_SUDO_BIN=1
    else
        mkdir -p "$HOME/.local/bin"
        chosen_bin="$HOME/.local/bin"
    fi
fi

FT_BIN="${chosen_bin}/ft"
bold "→ Installing CLI to ${FT_BIN}…"
WRAPPER_BODY=$(cat <<EOF
#!/usr/bin/env bash
# ft — open FinderTwo at a path. Installed by FinderTwo's install.sh.
set -e

if [[ \$# -eq 0 ]]; then
    TARGET="\$(pwd)"
else
    if [[ "\$1" == "." ]]; then
        TARGET="\$(pwd)"
    elif [[ "\$1" =~ ^/.* ]]; then
        TARGET="\$1"
    else
        TARGET="\$(pwd)/\$1"
    fi
fi

if [[ ! -e "\$TARGET" ]]; then
    echo "ft: path does not exist: \$TARGET" >&2
    exit 1
fi

APP="$APP_DEST"
if [[ ! -d "\$APP" ]]; then
    echo "ft: FinderTwo not found at \$APP (re-run install.sh)" >&2
    exit 1
fi

open -a "\$APP" "\$TARGET"
EOF
)

if [[ "${NEED_SUDO_BIN:-0}" == "1" ]]; then
    echo "$WRAPPER_BODY" | sudo tee "$FT_BIN" >/dev/null
    sudo chmod +x "$FT_BIN"
else
    echo "$WRAPPER_BODY" > "$FT_BIN"
    chmod +x "$FT_BIN"
fi
dim "  installed wrapper"

# Make Launch Services aware of the new bundle.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREG" ]]; then
    "$LSREG" -f "$APP_DEST" 2>/dev/null || true
fi

green ""
green "✓ FinderTwo installed"
echo ""
echo "Try it now:"
echo "  ft                  open at \$(pwd)"
echo "  ft ~                open at home"
echo "  ft ~/Downloads      open at Downloads"
echo "  Spotlight → \"FinderTwo\""
echo ""
if [[ "$chosen_bin" == "$HOME/.local/bin" ]]; then
    echo "Note: $HOME/.local/bin is in PATH? If not, add it:"
    echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
fi
