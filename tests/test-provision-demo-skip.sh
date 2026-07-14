#!/usr/bin/env bash
# tests/test-provision-demo-skip.sh
#
# Regression test: `./srsx-migrate --demo all` must NOT invoke curl during
# the provision phase. The demo bin shim at lib/demo/bin/curl exits 97 if
# called, which would fail the demo run loudly.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

export SRSX_DEMO_HOME=/tmp/srsx-demo-home-provisiontest
rm -rf "$SRSX_DEMO_HOME"

# Same scripted-answers payload as the resume test / Makefile target —
# provision must NOT consume an extra answer, so this list stays at 10.
DEMO_ANSWERS="demoapp,dev,n,main,https://searchcloud-2-us-east-1.searchstax.com/12345/demoapp-123/update,read_token,write_token,https://analytics.demo.searchstax.com,analytics_key,1" \
    ./srsx-migrate --demo all </dev/null >/tmp/srsx-demo-provision.log 2>&1 || {
        rc=$?
        echo "FAIL: ./srsx-migrate --demo all exited $rc"
        tail -40 /tmp/srsx-demo-provision.log
        exit 1
    }

# The provision phase must have been visited and skipped.
if ! grep -q "Phase: provision" /tmp/srsx-demo-provision.log; then
    echo "FAIL: provision phase header not seen in demo run"
    tail -40 /tmp/srsx-demo-provision.log
    exit 1
fi
if ! grep -q "Demo mode — skipping SearchStax API calls" /tmp/srsx-demo-provision.log; then
    echo "FAIL: provision did not print demo-mode skip message"
    tail -40 /tmp/srsx-demo-provision.log
    exit 1
fi

# The curl tripwire must NOT have fired.
if grep -q "demo tripwire: curl invoked" /tmp/srsx-demo-provision.log; then
    echo "FAIL: lib/demo/bin/curl tripwire fired — provision touched the network in demo"
    tail -40 /tmp/srsx-demo-provision.log
    exit 1
fi

echo "  provision-demo-skip OK"
