#!/usr/bin/env bash
# Installs Talk: sets up its speech engine, builds the app, puts it in
# /Applications and opens it. Safe to run again to update.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(pwd)"
SUPPORT="$HOME/Library/Application Support/Talk"
ENGINE="${TALK_ENGINE_DIR:-$SUPPORT/engine}"
APPS="${TALK_APPS_DIR:-/Applications}"
BUILD="${TALK_BUILD_DIR:-$REPO/build}"
LOG="$(mktemp -t talk-install)"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
run() {  # quiet unless it fails
  if ! "$@" >>"$LOG" 2>&1; then
    tail -25 "$LOG" >&2
    fail "Something went wrong. Full log: $LOG"
  fi
}

# -- checks ---------------------------------------------------------------

[[ "$(uname -m)" == "arm64" ]] || fail "Talk needs a Mac with Apple silicon (M1 or later)."
(( $(sw_vers -productVersion | cut -d. -f1) >= 15 )) || fail "Talk needs macOS 15 Sequoia or later."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  bold "Talk needs Apple's free Command Line Tools."
  note "A window will open. Click Install, wait for it to finish, then run ./install.sh again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  bold "Installing uv, which runs Talk's speech engine"
  run sh -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
  export PATH="$HOME/.local/bin:$PATH"
fi

# -- engine ---------------------------------------------------------------

bold "1/4  Setting up the speech engine"
mkdir -p "$ENGINE"
run rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
  "$REPO/sidecar/" "$ENGINE/"
(cd "$ENGINE" && run uv sync --no-dev)

bold "2/4  Downloading the speech model (2.5 GB, only the first time)"
(cd "$ENGINE" && uv run --no-dev python -c "
from huggingface_hub import snapshot_download
from talk_sidecar.config import DEFAULTS
snapshot_download(DEFAULTS['model'])
") || fail "The download failed. Check your connection and run ./install.sh again."

# -- app ------------------------------------------------------------------

bold "3/4  Building Talk"
# A stable signature keeps your permission grants when Talk updates.
run ./scripts/make_signing_identity.sh
SIDECAR_DIR="$ENGINE" DEST="$BUILD" run ./scripts/bundle.sh

bold "4/4  Installing to $APPS"
if [[ -z "${TALK_NO_LAUNCH:-}" ]]; then
  osascript -e 'quit app "Talk"' >/dev/null 2>&1 || true
  pkill -x Talk 2>/dev/null || true
  pkill -f "talk_sidecar --socket" 2>/dev/null || true  # an older engine
fi
mkdir -p "$APPS"
rm -rf "$APPS/Talk.app"
cp -R "$BUILD/Talk.app" "$APPS/Talk.app"

if [[ -n "${TALK_NO_LAUNCH:-}" ]]; then
  bold "Installed to $APPS/Talk.app (not launched)."
  exit 0
fi

# The globe key would otherwise also start macOS's own dictation.
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
open "$APPS/Talk.app"

bold "Done. Talk is in your menu bar."
note "Turn on the three switches Talk asks for (Microphone, Accessibility,"
note "Input Monitoring). Then hold fn anywhere and speak."
note "To update later, run: git pull && ./install.sh"
