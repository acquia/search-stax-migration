#!/usr/bin/env bash
# tests/test-phase-continues-onward.sh
#
# Naming a phase means "pick up here": `./srsx-migrate server` must run server
# and then every phase after it, so an operator who restarts mid-migration is
# not left having to invoke each remaining phase by hand. `--only` opts out.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log ---"; cat "$2"; }; exit 1; }

export SRSX_DEMO_HOME=/tmp/srsx-demo-home-onward
seed_home() {
    rm -rf "$SRSX_DEMO_HOME"
    mkdir -p "$SRSX_DEMO_HOME/state"
    cat > "$SRSX_DEMO_HOME/migration.env" <<'EOF'
ACQUIA_APP="demoapp"
ACQUIA_TARGET_ENV="dev"
SEARCHSTAX_APP_ENDPOINT="https://h.searchstax.com/29847/core1/select"
SEARCHSTAX_ANALYTICS_URL=""
SECRET_STORAGE="key"
EOF
    : > "$SRSX_DEMO_HOME/state/init.done"
}

# --- starting at 'server' must reach every later phase ----------------------
seed_home
LOG=/tmp/srsx-onward.log
./srsx-migrate --demo --yes server </dev/null >"$LOG" 2>&1 \
    || fail "'server' run exited non-zero" "$LOG"

for p in server index views route validate handoff cleanup; do
    grep -q "^▶ Phase: ${p} " "$LOG" || fail "phase '${p}' did not run when starting at 'server'" "$LOG"
done
# Phases before the named one must be skipped entirely.
for p in preflight backup install provision configure; do
    grep -q "^▶ Phase: ${p} " "$LOG" && fail "phase '${p}' ran but comes before 'server'" "$LOG"
done

echo "  named phase continues through the remaining phases OK"

# --- --only runs exactly one phase ------------------------------------------
seed_home
LOG_ONLY=/tmp/srsx-onward-only.log
./srsx-migrate --demo --yes server --only </dev/null >"$LOG_ONLY" 2>&1 \
    || fail "'server --only' run exited non-zero" "$LOG_ONLY"

grep -q "^▶ Phase: server " "$LOG_ONLY" || fail "'server --only' did not run server" "$LOG_ONLY"
count="$(grep -c "^▶ Phase: " "$LOG_ONLY" || true)"
[[ "$count" == "1" ]] || fail "'--only' ran ${count} phases, expected exactly 1" "$LOG_ONLY"

echo "  --only runs exactly one phase OK"

# --- validate stays single: it is read-only and often aimed at another env ---
seed_home
LOG_VAL=/tmp/srsx-onward-validate.log
./srsx-migrate --demo --yes validate </dev/null >"$LOG_VAL" 2>&1 \
    || fail "'validate' run exited non-zero" "$LOG_VAL"
grep -q "^▶ Phase: handoff " "$LOG_VAL" \
    && fail "'validate' must not roll on into handoff/cleanup" "$LOG_VAL"

echo "  validate does not continue onward OK"
echo "  phase-continues-onward OK"
