#!/usr/bin/env bash
# tests/test-force-all-resets-progress.sh
#
# Regression test: `./srsx-migrate --demo all --force` must clear prior
# progress state before re-running phases so stale markers cannot survive
# into a forced fresh run.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

export SRSX_DEMO_HOME=/tmp/srsx-demo-home-forceall
rm -rf "$SRSX_DEMO_HOME"

# Seed a complete run so state/ has all done markers and last-phase=cleanup.
DEMO_ANSWERS="demoapp,dev,n,main,https://searchcloud-2-us-east-1.searchstax.com/12345/demoapp-123/update,read_token,write_token,https://analytics.demo.searchstax.com,analytics_key,1" \
    ./srsx-migrate --demo all </dev/null >/tmp/srsx-demo-forceall-seed.log 2>&1 || {
        rc=$?
        echo "FAIL: seed run exited $rc"
        tail -40 /tmp/srsx-demo-forceall-seed.log
        exit 1
    }

[[ "$(cat "$SRSX_DEMO_HOME/state/last-phase" 2>/dev/null)" == "cleanup" ]] \
    || { echo "FAIL: seed run did not leave state/last-phase=cleanup"; exit 1; }

# Add stale markers that only a reset pass should remove.
touch "$SRSX_DEMO_HOME/state/done-zombie"
printf '%s\n' "stale-app-id" > "$SRSX_DEMO_HOME/state/provisioned-app-id"

./srsx-migrate --demo all --force </dev/null >/tmp/srsx-demo-forceall.log 2>&1 || {
    rc=$?
    echo "FAIL: forced rerun exited $rc"
    tail -60 /tmp/srsx-demo-forceall.log
    exit 1
}

if [[ -f "$SRSX_DEMO_HOME/state/done-zombie" ]]; then
    echo "FAIL: stale done marker survived forced all reset"
    tail -60 /tmp/srsx-demo-forceall.log
    exit 1
fi

if [[ -f "$SRSX_DEMO_HOME/state/provisioned-app-id" ]]; then
    echo "FAIL: stale provisioned-app-id survived forced all reset"
    tail -60 /tmp/srsx-demo-forceall.log
    exit 1
fi

if ! grep -q "Clearing progress markers under" /tmp/srsx-demo-forceall.log; then
    echo "FAIL: expected progress reset log line missing"
    tail -60 /tmp/srsx-demo-forceall.log
    exit 1
fi

echo "  force-all-resets-progress OK"
