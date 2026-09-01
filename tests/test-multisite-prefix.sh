#!/usr/bin/env bash
# tests/test-multisite-prefix.sh
#
# Integration tests for ensure_site_prefix_map:
#   1) Duplicate prefix rejected on re-prompt; final map is correct.
#   2) Pre-set SITE_PREFIX_MAP survives a --force configure re-run without
#      triggering the wizard.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log tail ---"; tail -60 "$2"; }; exit 1; }

# ---------------------------------------------------------------------------
# Common env setup — topology + credentials pre-seeded so only the prefix
# wizard runs (or doesn't run) during configure.
# ---------------------------------------------------------------------------
_seed_env() {
  local home="$1" sites="$2"
  rm -rf "$home"
  mkdir -p "$home/state"
  cat > "$home/migration.env" <<EOF
ACQUIA_APP="demoapp"
ACQUIA_TARGET_ENV="dev"
SITES="${sites}"
SEARCHSTAX_APP_COUNT="1"
SITE_APP_MAP="${sites//,/=1,}=1"
SEARCHSTAX_APP_ENDPOINT_1="https://pre.searchstax.com"
SEARCHSTAX_APP_ENDPOINT="https://pre.searchstax.com"
SEARCHSTAX_WRITE_TOKEN_1="pretok"
SEARCHSTAX_READ_TOKEN_1="pretok"
SECRET_STORAGE="key"
EOF
  : > "$home/state/init.done"
}

SITES2="https://site1.example.com,https://site2.example.com"

# ---------------------------------------------------------------------------
# Scenario 1 — duplicate prefix rejected, re-prompt accepted.
# ---------------------------------------------------------------------------
# DEMO_ANSWERS sequence for ensure_site_prefix_map (2 sites):
#   site1 gets "dup_" (accepted)
#   site2 gets "dup_" (REJECTED — already used), then "site2_" (accepted)
# The analytics-url ask_saved call (current="", FORCE=0) falls through to
# stdin=/dev/null which gives "" (au=""), analytics key is then skipped.
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-prefix-1
_seed_env "$SRSX_DEMO_HOME" "$SITES2"

PFX1_LOG=/tmp/srsx-prefix-1.log
DEMO_ANSWERS="dup_,dup_,site2_" \
    ./srsx-migrate --demo configure --only </dev/null >"$PFX1_LOG" 2>&1 \
    || fail "scenario 1 configure exited non-zero" "$PFX1_LOG"

grep -q "already used by another site" "$PFX1_LOG" \
    || fail "duplicate-prefix warning not found in log" "$PFX1_LOG"

PFXENV="$SRSX_DEMO_HOME/migration.env"
grep -q '^SITE_PREFIX_MAP="https://site1.example.com=dup_,https://site2.example.com=site2_"$' "$PFXENV" \
    || fail "SITE_PREFIX_MAP not persisted correctly" "$PFX1_LOG"

echo "  prefix scenario 1 (duplicate rejected, re-prompt consumed) OK"

# ---------------------------------------------------------------------------
# Scenario 2 — preset SITE_PREFIX_MAP survives --force.
# ---------------------------------------------------------------------------
# Pre-seed the map; run configure --force.  ensure_site_prefix_map checks
# SITE_PREFIX_MAP directly (not via ask_saved), so it returns early even under
# --force.  The credential prompts re-ask (FORCE=1) and consume 3 empty answers
# (endpoint, write-token, analytics-url); _persist_app_creds ignores empty
# values so the file retains the pre-seeded credentials.
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-prefix-2
_seed_env "$SRSX_DEMO_HOME" "$SITES2"

PFXENV="$SRSX_DEMO_HOME/migration.env"
printf 'SITE_PREFIX_MAP="https://site1.example.com=custom1_,https://site2.example.com=custom2_"\n' \
    >> "$PFXENV"

PFX2_LOG=/tmp/srsx-prefix-2.log
DEMO_ANSWERS=",," \
    ./srsx-migrate --demo configure --only --force </dev/null >"$PFX2_LOG" 2>&1 \
    || fail "scenario 2 configure --force exited non-zero" "$PFX2_LOG"

grep -q '^SITE_PREFIX_MAP="https://site1.example.com=custom1_,https://site2.example.com=custom2_"$' "$PFXENV" \
    || fail "SITE_PREFIX_MAP was overwritten by --force configure" "$PFX2_LOG"

if grep -q "index_prefix for" "$PFX2_LOG"; then
    fail "ensure_site_prefix_map should not prompt when SITE_PREFIX_MAP is preset" "$PFX2_LOG"
fi

echo "  prefix scenario 2 (preset map survives --force) OK"

echo "  multisite-prefix OK"
