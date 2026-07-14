#!/usr/bin/env bash
# tests/test-safety-guards.sh
#
# Regression tests for the safety-guard fixes:
#   1. `--dry-run preflight` completes (it used to die on the empty capture).
#   2. Preflight makes no mutating drush calls (sapi-rt / sapi-i moved to
#      the guarded 'index' phase).
#   3. is_prod_env recognizes ACSF-style NNlive env names.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

ANSWERS="demoapp,dev,n,main,https://searchcloud-2-us-east-1.searchstax.com/12345/demoapp-123/update,read_token,write_token,https://analytics.demo.searchstax.com,analytics_key,1"

# --- 1. dry-run preflight completes -----------------------------------------
export SRSX_HOME=/tmp/srsx-safety-test
rm -rf "$SRSX_HOME"
mkdir -p "$SRSX_HOME"
if ! DEMO_ANSWERS="$ANSWERS" ./srsx-migrate --dry-run preflight </dev/null \
     >/tmp/srsx-safety-dryrun.log 2>&1; then
  echo "FAIL: './srsx-migrate --dry-run preflight' exited non-zero"
  tail -20 /tmp/srsx-safety-dryrun.log
  exit 1
fi
grep -q "Phase 'preflight' complete" /tmp/srsx-safety-dryrun.log || {
  echo "FAIL: dry-run preflight did not complete"
  tail -20 /tmp/srsx-safety-dryrun.log
  exit 1
}
echo "  dry-run preflight OK"

# --- 2. preflight is read-only ----------------------------------------------
# The audit log of a dry-run prints every command preflight would run;
# none of them may be a mutating search-api command.
if grep -E 'sapi-rt|sapi-i\b|search-api:(reset-tracker|index|clear|rebuild-tracker)' \
     /tmp/srsx-safety-dryrun.log | grep -v '^#'; then
  echo "FAIL: preflight would run a mutating search-api command (see above)"
  exit 1
fi
echo "  preflight read-only OK"

# --- 3. ACSF prod names are guarded -----------------------------------------
# Extract is_prod_env + PROD_ENV_NAMES into a scratch shell and probe it.
probe() {
  bash -c "
    $(sed -n '/^readonly -a PROD_ENV_NAMES=/p' srsx-migrate)
    $(awk '/^is_prod_env\(\)/,/^}/' srsx-migrate)
    is_prod_env '$1'
  "
}
for name in prod production live 01live 02live 10live; do
  probe "$name" || { echo "FAIL: is_prod_env('$name') should be true"; exit 1; }
done
for name in dev test stage ode1 feature-live; do
  probe "$name" && { echo "FAIL: is_prod_env('$name') should be false"; exit 1; }
done
echo "  ACSF prod-name detection OK"

rm -rf "$SRSX_HOME"
echo "PASS: safety guards"
