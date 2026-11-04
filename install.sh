#!/bin/bash
# Taskflow installer.
#
#   Install the latest release:
#     curl -fsSL https://raw.githubusercontent.com/shihab-abir/Work-Management-App/main/install.sh | bash
#
#   Options (pass after `bash -s --` when piping, or directly when running a local copy):
#     --version v0.1.0   install a specific release
#     --from-source      build from source instead of downloading (needs Xcode Command Line Tools)
#     --no-open          don't launch Taskflow when done
#
# Installs:  ~/Applications/Taskflow.app   and the `taskflow` command in ~/.local/bin
set -euo pipefail

REPO="shihab-abir/Work-Management-App"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Taskflow.app"
BIN_DIR="$HOME/.local/bin"
VERSION=""
FROM_SOURCE=0
OPEN_APP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value like v0.1.0}"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --no-open) OPEN_APP=0; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\033[32m→\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- Requirements -----------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "Taskflow is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || die "Taskflow needs a Mac with Apple silicon (M1 or newer)."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 26 )) || die "Taskflow needs macOS 26 or newer (you have $(sw_vers -productVersion))."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Get Taskflow.app ---------------------------------------------------------
build_from_source() {
  xcode-select -p >/dev/null 2>&1 || {
    xcode-select --install >/dev/null 2>&1 || true
    die "Building needs Apple's Command Line Tools. Finish the installer that just opened, then run this again."
  }
  local src
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
  if [[ -n "$here" && -d "$here/Sources/TaskflowCore" ]]; then
    src="$here"                       # running from a checkout
  else
    step "Downloading source"
    src="$WORK/src"
    git clone --quiet --depth 1 ${VERSION:+--branch "$VERSION"} "https://github.com/$REPO.git" "$src"
  fi
  step "Building (takes a minute or two)"
  (cd "$src" && scripts/build.sh >/dev/null)
  BUILT="$src/build/Taskflow.app"
}

download_release() {
  local api="https://api.github.com/repos/$REPO/releases/latest"
  [[ -n "$VERSION" ]] && api="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
  local url
  url="$(curl -fsSL "$api" 2>/dev/null | grep -o '"browser_download_url": *"[^"]*macos-arm64\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')" || true
  [[ -n "$url" ]] || return 1
  step "Downloading $(basename "$url")"
  curl -fL --progress-bar "$url" -o "$WORK/Taskflow.zip" || return 1
  if curl -fsSL "$url.sha256" -o "$WORK/Taskflow.zip.sha256" 2>/dev/null; then
    local expected actual
    expected="$(awk '{print $1}' "$WORK/Taskflow.zip.sha256")"
    actual="$(shasum -a 256 "$WORK/Taskflow.zip" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "Download checksum mismatch — please try again."
  fi
  ditto -x -k "$WORK/Taskflow.zip" "$WORK/unpacked"
  BUILT="$WORK/unpacked/Taskflow.app"
  [[ -d "$BUILT" ]]
}

bold "Installing Taskflow"
if (( FROM_SOURCE )); then
  build_from_source
elif ! download_release; then
  step "No downloadable release found — building from source instead"
  build_from_source
fi

# --- Install -----------------------------------------------------------------
if pgrep -xq Taskflow; then
  step "Closing the running copy"
  "$APP/Contents/MacOS/taskflow-cli" quit >/dev/null 2>&1 || osascript -e 'quit app "Taskflow"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Taskflow 2>/dev/null || true
fi

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP"
ditto "$BUILT" "$APP"
# Not notarized (no paid Apple Developer ID yet): clear the download flag so macOS lets it open.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
ln -sf "$APP/Contents/MacOS/taskflow-cli" "$BIN_DIR/taskflow"
step "Installed $APP"
step "Installed the taskflow command in $BIN_DIR"

# Make sure ~/.local/bin is on PATH for new terminal windows.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    PROFILE="$HOME/.zprofile"
    [[ "${SHELL:-}" == */bash ]] && PROFILE="$HOME/.bash_profile"
    if ! grep -qs '.local/bin' "$PROFILE"; then
      printf '\n# Added by the Taskflow installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$PROFILE"
      step "Added ~/.local/bin to your PATH in $PROFILE (open a new Terminal window to use it)"
    fi
    ;;
esac

echo
bold "Done!"
echo "  Open the panel:   taskflow"
echo "  Close it:         taskflow quit"
echo "  All commands:     taskflow help"
echo
echo "On first launch, choose your Obsidian vault (or any folder) — tasks are saved there as Markdown."

(( OPEN_APP )) && open "$APP"
exit 0
