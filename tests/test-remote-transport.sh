#!/usr/bin/env bash
# tests/test-remote-transport.sh
#
# Regression test: parameters for the php-eval helpers must travel as
# php:script ARGUMENTS, and the helpers must be uploaded to the target env —
# never referenced by laptop-local path or fed via SRSX_* environment
# variables. Client env does not survive the `acli remote:drush` SSH hop
# (sshd AcceptEnv), and ${SCRIPT_DIR} does not exist on the remote host.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# 1. No helper may read SRSX_* from the environment.
if grep -n "getenv('SRSX_" lib/php-eval/*.php; then
  echo "FAIL: php-eval helpers must read drush \$extra args, not SRSX_* env vars (see above)"
  fail=1
fi

# 2. srsx-migrate must not pass a laptop-local php-eval path to the remote
#    drush. The only legal direct reference is inside drush_php_script()'s
#    demo branch (which never leaves the machine) and its local_path lookup.
if grep -nE 'drush php:script "\$\{SCRIPT_DIR\}' srsx-migrate; then
  echo "FAIL: php:script must run uploaded copies via drush_php_script, not \${SCRIPT_DIR} paths (see above)"
  fail=1
fi

# 3. No SRSX_* env-prefix on drush invocations.
if grep -nE '^[[:space:]]*SRSX_[A-Z_]+=[^=]*\\$' srsx-migrate; then
  echo "FAIL: srsx-migrate still prefixes drush calls with SRSX_* env vars (see above)"
  fail=1
fi

# 4. The transport helpers this contract relies on must exist.
for fn in srsx_remote_put drush_php_script srsx_remote_cleanup; do
  if ! grep -qE "^${fn}\(\)" srsx-migrate; then
    echo "FAIL: expected helper ${fn}() not found in srsx-migrate"
    fail=1
  fi
done

if (( fail == 0 )); then
  echo "PASS: php-eval transport uses uploaded scripts + argv (no env vars, no local paths)"
fi
exit "$fail"
