#!/usr/bin/env bash
# tests/test-secret-redaction.sh
#
# Regression test: secret values must never reach the tee'd logs. Runs the
# demo end-to-end with a unique analytics key and PLAIN storage (the mode
# that puts the secret on a drush cset command line), then asserts the
# secret string appears nowhere in the run's output or logs.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

SECRET="sekrit_key_do_not_log_9f3a7"
export SRSX_DEMO_HOME=/tmp/srsx-redaction-test
rm -rf "$SRSX_DEMO_HOME"

# Answer #9 is the analytics key; #10 picks "2" = plain storage.
DEMO_ANSWERS="demoapp,dev,n,main,https://searchcloud-2-us-east-1.searchstax.com/12345/demoapp-123/update,read_token,write_token,https://analytics.demo.searchstax.com,${SECRET},2" \
    ./srsx-migrate --demo all </dev/null >/tmp/srsx-redaction.log 2>&1 || {
      echo "FAIL: demo run exited non-zero"
      tail -30 /tmp/srsx-redaction.log
      exit 1
    }

fail=0
if grep -q "$SECRET" /tmp/srsx-redaction.log; then
  echo "FAIL: analytics key leaked into run output:"
  grep -n "$SECRET" /tmp/srsx-redaction.log | head -5
  fail=1
fi
if grep -rq "$SECRET" "$SRSX_DEMO_HOME/logs" 2>/dev/null; then
  echo "FAIL: analytics key leaked into logs/:"
  grep -rn "$SECRET" "$SRSX_DEMO_HOME/logs" | head -5
  fail=1
fi
if [[ -f "$SRSX_DEMO_HOME/migration.env" ]] && grep -q "$SECRET" "$SRSX_DEMO_HOME/migration.env"; then
  echo "FAIL: analytics key was persisted to migration.env"
  fail=1
fi

# The redaction marker should actually appear where the cset ran, proving
# the mechanism fired rather than the code path being skipped.
if ! grep -rq "analytics_key" /tmp/srsx-redaction.log; then
  echo "FAIL: plain-storage cset path did not run — test is vacuous"
  fail=1
fi

rm -rf "$SRSX_DEMO_HOME"
if (( fail == 0 )); then
  echo "PASS: secret redaction (no key material in output, logs, or migration.env)"
fi
exit "$fail"
