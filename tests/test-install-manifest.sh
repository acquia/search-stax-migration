#!/usr/bin/env bash
# tests/test-install-manifest.sh
#
# Regression test: install.sh's FILES manifest must list every runtime file
# tracked in git. A stale manifest ships broken installs — phases reference
# scripts that were never downloaded (e.g. import-config-yaml.php powering
# phase 'server'), and the toolkit .gitignore silently goes missing so
# customer repos can commit logs/ and state/ containing secrets.
#
# "Runtime files" = srsx-migrate, everything under lib/ and templates/, and
# the toolkit .gitignore. Docs, tests, CI config and the installer itself are
# repo-only and intentionally excluded.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

# 1. Extract the entries of the FILES=( ... ) array from install.sh.
manifest="$(
  sed -n '/^FILES=(/,/^)/p' install.sh \
    | sed -e '1d' -e '$d' \
          -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
          -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
    | sort
)"
[[ -n "$manifest" ]] || { echo "FAIL: could not parse FILES=() from install.sh"; exit 1; }

# 2. The runtime files tracked in git.
expected="$(git ls-files srsx-migrate .gitignore lib templates | sort)"

fail=0
missing="$(comm -13 <(printf '%s\n' "$manifest") <(printf '%s\n' "$expected"))"
extra="$(comm -23 <(printf '%s\n' "$manifest") <(printf '%s\n' "$expected"))"

if [[ -n "$missing" ]]; then
  echo "FAIL: runtime files tracked in git but missing from install.sh FILES:"
  printf '  %s\n' $missing
  fail=1
fi
if [[ -n "$extra" ]]; then
  echo "FAIL: install.sh FILES lists files that are not tracked in git:"
  printf '  %s\n' $extra
  fail=1
fi

if (( fail == 0 )); then
  count="$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"
  echo "PASS: install.sh manifest matches the ${count} tracked runtime files"
fi
exit "$fail"
