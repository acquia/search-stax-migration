#!/usr/bin/env bash
# tests/test-resume-after-completion.sh
#
# Regression test: when a previous run completed every phase (state/last-phase
# == the last phase in PHASE_ORDER), running `./srsx-migrate --demo` with no
# args MUST exit 0 cleanly AND print the "All phases were completed" guidance
# to stdout.
#
# History: a latent `set -e` tripwire on `((i++))` (post-increment with i=0
# returns exit status 1) inside resume_or_select() killed the script silently
# whenever last-phase wasn't the FIRST phase. Combined with the tee
# process-substitution race on quick exit, the user saw nothing at all and
# assumed --demo was broken.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

export SRSX_DEMO_HOME=/tmp/srsx-demo-home-resumetest
rm -rf "$SRSX_DEMO_HOME"

# Run a full demo first so state/last-phase=cleanup is left behind.
DEMO_ANSWERS="demoapp,dev,n,main,https://demo.searchstax.com,read_token,write_token,https://analytics.demo.searchstax.com,analytics_key,1" \
    ./srsx-migrate --demo all </dev/null >/dev/null 2>&1

[[ "$(cat "$SRSX_DEMO_HOME/state/last-phase" 2>/dev/null)" == "cleanup" ]] \
    || { echo "FAIL: setup did not leave state/last-phase=cleanup in $SRSX_DEMO_HOME"; exit 1; }

# Now invoke `./srsx-migrate --demo` with no subcommand. This used to die
# silently with exit code 1 and no output past the demo banner.
out="$(./srsx-migrate --demo </dev/null 2>&1)"
rc=$?

if (( rc != 0 )); then
    echo "FAIL: ./srsx-migrate --demo exited $rc when all phases were already done"
    echo "--- output ---"
    echo "$out"
    exit 1
fi

if ! grep -q "All phases were completed on a previous run" <<<"$out"; then
    echo "FAIL: expected guidance message not printed"
    echo "--- output ---"
    echo "$out"
    exit 1
fi

if ! grep -q "rm -rf state/" <<<"$out"; then
    echo "FAIL: expected recovery hint (rm -rf state/...) not printed"
    echo "--- output ---"
    echo "$out"
    exit 1
fi

echo "  resume-after-completion OK"
