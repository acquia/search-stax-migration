#!/usr/bin/env bash
# tests/test-multisite-app-topology.sh
#
# Covers the multisite → SearchStax-app topology mapping:
#   A) A full --demo 'all' run with 3 sites split across 2 apps (custom
#      grouping) persists SEARCHSTAX_APP_COUNT + SITE_APP_MAP and per-app
#      credentials (_1.._K), and mirrors app 1 to the unsuffixed vars.
#   B) A standalone 'configure' with 10 sites enforces the 9-sites-per-app
#      cap: answering "1" app is rejected (min 2 = ceil(10/9)) and the
#      accepted default packs 9 sites onto app 1 and the 10th onto app 2.
#
# Multisite site lists can't be scripted through DEMO_ANSWERS (comma clash),
# so we pre-seed SITES in the demo migration.env + touch state/init.done.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log tail ---"; tail -60 "$2"; }; exit 1; }

# ---------------------------------------------------------------------------
# Scenario A — 3 sites, custom split into 2 apps (a,b → app1; c → app2).
# ---------------------------------------------------------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-topology-a
rm -rf "$SRSX_DEMO_HOME"
mkdir -p "$SRSX_DEMO_HOME/state"
cat > "$SRSX_DEMO_HOME/migration.env" <<'EOF'
ACQUIA_APP="demoapp"
ACQUIA_TARGET_ENV="dev"
SITES="https://a.example.com,https://b.example.com,https://c.example.com"
EOF
: > "$SRSX_DEMO_HOME/state/init.done"

# Answer order (init already seeded, so it is skipped):
#   install branch: main
#   topology count: 2   (min=1, n=3 → custom assignment path)
#   assign a=1, b=1, c=2
#   app1 creds: endpoint, read, write, analytics-url, analytics-key
#   app2 creds: endpoint, read, write, analytics-url, analytics-key
#   analytics-key storage: 1 (Key module)
A_LOG=/tmp/srsx-topology-a.log
DEMO_ANSWERS="main,2,1,1,2,https://app1.example.searchstax.com,r1,w1,https://an1.example.searchstax.com,k1,https://app2.example.searchstax.com,r2,w2,https://an2.example.searchstax.com,k2,1" \
    ./srsx-migrate --demo all </dev/null >"$A_LOG" 2>&1 \
    || fail "scenario A run exited non-zero" "$A_LOG"

ENV_A="$SRSX_DEMO_HOME/migration.env"

grep -q '^SEARCHSTAX_APP_COUNT="2"$' "$ENV_A" \
    || fail "SEARCHSTAX_APP_COUNT=2 not persisted" "$A_LOG"

grep -q '^SITE_APP_MAP="https://a.example.com=1,https://b.example.com=1,https://c.example.com=2"$' "$ENV_A" \
    || fail "SITE_APP_MAP not persisted as expected" "$A_LOG"

grep -q '^SEARCHSTAX_APP_ENDPOINT_1="https://app1.example.searchstax.com"$' "$ENV_A" \
    || fail "app 1 endpoint not persisted" "$A_LOG"
grep -q '^SEARCHSTAX_APP_ENDPOINT_2="https://app2.example.searchstax.com"$' "$ENV_A" \
    || fail "app 2 endpoint not persisted" "$A_LOG"

grep -q '^SEARCHSTAX_READ_TOKEN_2="r2"$'  "$ENV_A" || fail "app 2 read token not persisted" "$A_LOG"
grep -q '^SEARCHSTAX_WRITE_TOKEN_2="w2"$' "$ENV_A" || fail "app 2 write token not persisted" "$A_LOG"

# App 1 must mirror the unsuffixed vars for single-app backward compatibility.
grep -q '^SEARCHSTAX_APP_ENDPOINT="https://app1.example.searchstax.com"$' "$ENV_A" \
    || fail "app 1 did not mirror unsuffixed SEARCHSTAX_APP_ENDPOINT" "$A_LOG"

[[ "$(cat "$SRSX_DEMO_HOME/state/last-phase" 2>/dev/null)" == "cleanup" ]] \
    || fail "scenario A did not complete through cleanup" "$A_LOG"

echo "  topology scenario A (3 sites → 2 apps) OK"

# ---------------------------------------------------------------------------
# Scenario B — 10 sites, capacity cap enforced (min 2 apps), default packing.
# ---------------------------------------------------------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-topology-b
rm -rf "$SRSX_DEMO_HOME"
mkdir -p "$SRSX_DEMO_HOME/state"

sites=""
for i in $(seq 1 10); do sites+="https://s${i}.example.com,"; done
sites="${sites%,}"
cat > "$SRSX_DEMO_HOME/migration.env" <<EOF
ACQUIA_APP="demoapp"
ACQUIA_TARGET_ENV="dev"
SITES="${sites}"
EOF
: > "$SRSX_DEMO_HOME/state/init.done"

# Answer order for standalone configure:
#   topology count: 1  → REJECTED (min 2 for 10 sites)
#   topology count: 2  → accepted, default packing (no per-site prompts)
#   app1: endpoint, read, write, analytics-url(blank → key skipped)
#   app2: endpoint, read, write, analytics-url(blank → key skipped)
#   analytics-key storage: 1
B_LOG=/tmp/srsx-topology-b.log
DEMO_ANSWERS="1,2,https://app1.example.searchstax.com,r1,w1,,https://app2.example.searchstax.com,r2,w2,,1" \
    ./srsx-migrate --demo configure </dev/null >"$B_LOG" 2>&1 \
    || fail "scenario B configure exited non-zero" "$B_LOG"

grep -qi "at least 2 app" "$B_LOG" \
    || fail "expected 9-per-app cap rejection message for 10 sites" "$B_LOG"

ENV_B="$SRSX_DEMO_HOME/migration.env"
grep -q '^SEARCHSTAX_APP_COUNT="2"$' "$ENV_B" \
    || fail "scenario B did not settle on 2 apps" "$B_LOG"

# Default packing: first 9 sites → app 1, 10th → app 2.
grep -q '^SITE_APP_MAP=.*https://s9.example.com=1.*https://s10.example.com=2"$' "$ENV_B" \
    || fail "default packing did not put 9 on app1 / 10th on app2" "$B_LOG"

echo "  topology scenario B (10 sites, 9-per-app cap) OK"

echo "  multisite-app-topology OK"
