#!/usr/bin/env bash
#
# Cacty Voice — one-shot setup & run.
#
# Builds CactyVoice (the macOS automation app), launches it with its loopback
# bridge, pauses for the one unavoidable manual step (granting macOS
# permissions — Apple forbids doing this programmatically), then starts the
# Pipecat voice bot.
#
# Usage:
#   ./run.sh                 # build + launch Cacty + grant gate + run bot
#   ./run.sh --skip-build    # skip the swift build/bundle step (faster reruns)
#   ./run.sh --cacty-only    # set up Cacty only; don't start the voice bot
#
# Ctrl-C stops the voice bot. CactyVoice keeps running in the menu bar; stop it
# with:  pkill -x CactyVoice
#
set -uo pipefail

# ---- locations -------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACTY_DIR="$ROOT/cacty"
SERVER_DIR="$ROOT/server"
APP_BUNDLE="$CACTY_DIR/build/CactyVoice.app"
ENV_FILE="$SERVER_DIR/.env"
BRIDGE_URL="http://127.0.0.1:8765"

SKIP_BUILD=0
CACTY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --cacty-only) CACTY_ONLY=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---- pretty output ---------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
die()  { printf "  \033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }
step() { printf "\n\033[1m▶ %s\033[0m\n" "$1"; }

# ---------------------------------------------------------------------------
step "1/5  Preflight checks"

[ -d "$CACTY_DIR" ]  || die "cacty/ not found at $CACTY_DIR"
[ -d "$SERVER_DIR" ] || die "server/ not found at $SERVER_DIR"
command -v swift >/dev/null || die "swift not found (install Xcode / command line tools)"
command -v uv >/dev/null    || die "uv not found (https://docs.astral.sh/uv/)"
[ -f "$ENV_FILE" ] || die "$ENV_FILE missing. Copy server/.env.example to server/.env and fill in your keys."

# Pull required keys out of server/.env.
GEMINI_API_KEY="$(grep -E '^GEMINI_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' )"
GRADIUM_API_KEY="$(grep -E '^GRADIUM_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' )"
[ -n "$GEMINI_API_KEY" ]  || die "GEMINI_API_KEY is empty in server/.env (Cacty needs it)."
[ -n "$GRADIUM_API_KEY" ] || warn "GRADIUM_API_KEY is empty in server/.env — the bot's voice (TTS) won't work."
ok "tools present, server/.env has the keys"

# ---------------------------------------------------------------------------
step "2/5  Build CactyVoice"

if [ "$SKIP_BUILD" -eq 1 ]; then
  [ -d "$APP_BUNDLE" ] || die "--skip-build given but $APP_BUNDLE doesn't exist. Run once without it."
  ok "skipped (using existing bundle)"
else
  ( cd "$CACTY_DIR" && swift build ) || die "swift build failed"
  ( cd "$CACTY_DIR" && ./Scripts/build-app.sh >/tmp/cacty_build.log 2>&1 ) || { cat /tmp/cacty_build.log; die "build-app.sh failed"; }
  ok "built $APP_BUNDLE  (app shows up as 'CactyVoice')"
fi

# ---------------------------------------------------------------------------
step "3/5  Launch CactyVoice + bridge"

launch_cacty() {
  pkill -x CactyVoice >/dev/null 2>&1
  sleep 2
  # GUI apps launched via launchd inherit launchctl env, not the shell's.
  launchctl setenv GEMINI_API_KEY "$GEMINI_API_KEY"
  open "$APP_BUNDLE"
}

launch_cacty

# Wait for the loopback bridge to answer.
printf "  waiting for bridge"
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "$BRIDGE_URL/health" >/dev/null 2>&1; then
    printf "\n"; ok "bridge up at $BRIDGE_URL"; break
  fi
  printf "."; sleep 1
done
curl -fsS --max-time 2 "$BRIDGE_URL/health" >/dev/null 2>&1 || die "bridge never came up — check Console.app logs for subsystem com.cacty"

# ---------------------------------------------------------------------------
step "4/5  Grant macOS permissions (one-time, manual)"

# Ask Cacty itself whether it can act. Returns the raw text so the user sees it.
probe_perms() {
  curl -fsS --max-time 40 -X POST "$BRIDGE_URL/task" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Report your Accessibility and Screen Recording permission status in one short sentence."}' 2>/dev/null
}

cat <<'EOF'
  CactyVoice needs three permissions to control your Mac. macOS only lets YOU
  grant them (with Touch ID / your password) — no script can.

  In System Settings → Privacy & Security, turn ON the "CactyVoice" row in:
      • Accessibility      (the critical one)
      • Screen Recording
      • Input Monitoring   (for typing)

  Tips:
    - Approve the Touch ID / password prompt — that's the proof it took.
    - Ignore any plain "Cacty" row; grant the one named "CactyVoice".
    - If "CactyVoice" isn't listed, click +, press Cmd-Shift-G, and paste the
      app path printed just below, then select Cacty.app.
EOF
printf "      app path:  \033[2m%s\033[0m\n" "$APP_BUNDLE"

# Open the three panes.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" >/dev/null 2>&1
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" >/dev/null 2>&1

while true; do
  echo
  read -r -p "  Press ENTER after toggling CactyVoice ON (or type 's' to skip the check): " reply
  if [ "$reply" = "s" ]; then warn "skipping permission verification"; break; fi

  echo "  relaunching CactyVoice so Accessibility takes effect..."
  launch_cacty
  for _ in $(seq 1 20); do
    curl -fsS --max-time 2 "$BRIDGE_URL/health" >/dev/null 2>&1 && break
    sleep 1
  done

  echo "  asking CactyVoice to open Calculator as a live test..."
  result="$(curl -fsS --max-time 60 -X POST "$BRIDGE_URL/task" \
            -H 'Content-Type: application/json' \
            -d '{"prompt":"Open the Calculator app, then state whether you have Accessibility and Screen Recording permissions."}' 2>/dev/null)"
  printf "  \033[36mCacty says:\033[0m %s\n" "$result"

  if echo "$result" | grep -qiE "do not have|don'?t have|not granted|missing|disabled|denied|need .*permission|unable"; then
    warn "still looks unpermitted — re-check the CactyVoice toggles (did you get the Touch ID prompt?)"
    continue
  fi
  ok "permissions look good"
  break
done

# ---------------------------------------------------------------------------
if [ "$CACTY_ONLY" -eq 1 ]; then
  step "Done (CactyVoice only)"
  ok "CactyVoice is running with the bridge at $BRIDGE_URL"
  echo "  Start the voice bot yourself with:  cd server && uv run bot.py"
  exit 0
fi

step "5/5  Start the voice bot"

cleanup() { echo; echo "Stopping voice bot. CactyVoice stays running (pkill -x CactyVoice to stop it)."; }
trap cleanup EXIT

( cd "$SERVER_DIR" && uv sync ) || die "uv sync failed"
ok "python deps ready"
echo
bold "Bot starting on http://localhost:7860  — open it, click Connect, and talk."
bold "Try: \"Create a calendar event tomorrow at 3pm called Dentist.\""
echo
cd "$SERVER_DIR" && exec uv run bot.py
