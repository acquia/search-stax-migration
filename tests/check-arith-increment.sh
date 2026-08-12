#!/usr/bin/env bash
# tests/check-arith-increment.sh
#
# `set -e` + `((x++))` silently kills the script.
#
# `((expr))` exits non-zero when expr evaluates to 0, and post-increment
# evaluates to the OLD value. So `((tries++))` with tries=0 returns 1, which
# under `set -e` ends the run with no message at all. That is exactly how
# configure died right after the analytics-URL prompt:
#
#     ? SearchStax analytics URL (or press Enter to skip):
#     <nothing — exit 1>
#
# Pre-increment `((++x))` is safe only while the new value is non-zero, which
# is a property of the data, not of the code. So require an assignment form.
#
# This is version-dependent, which is how it survived local testing: bash 3.2
# (the macOS default) does not abort, bash 5 does — and srsx-migrate re-execs
# itself under bash 4+.
#
# C-style `for ((i = 0; i < n; i++))` is exempt: the increment is part of the
# loop construct, not a standalone command, and its status is not tested.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

rc=0
for f in srsx-migrate install.sh lib/searchstax_api.sh lib/demo/bin/*; do
    [[ -f "$f" ]] || continue
    # Standalone (( ... ++ )) / (( ... -- )) statements, excluding `for ((...))`.
    hits="$(grep -nE '^[[:space:]]*\(\([^)]*(\+\+|--)[^)]*\)\)' "$f" \
            | grep -vE '\bfor[[:space:]]*\(\(' || true)"
    if [[ -n "$hits" ]]; then
        echo "FAIL: $f uses a bare ((x++)) / ((x--)) statement:"
        sed 's/^/    /' <<<"$hits"
        rc=1
    fi
done

if (( rc != 0 )); then
    cat <<'EOF'
  → ((x++)) returns the OLD value as its exit status, so it returns 1 when the
    variable is 0 and `set -e` ends the run silently.
    Use an assignment instead:   x=$((x + 1))
EOF
    exit 1
fi

# Prove the failure mode still exists, so the check above is not guarding
# against a myth. It must be probed with the interpreter srsx-migrate actually
# re-execs into: bash 3.2 (the macOS default) does NOT abort here, bash 5 does,
# which is why this survived local testing.
probe_bash=""
for cand in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash5 bash; do
    if command -v "$cand" >/dev/null 2>&1 \
       && "$cand" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
        probe_bash="$cand"
        break
    fi
done

if [[ -z "$probe_bash" ]]; then
    echo "OK: no bare ((x++)) statements (bash 4+ not found, skipped the behaviour probe)."
    exit 0
fi

if "$probe_bash" -c 'set -e; n=0; (( n++ )); echo reached' 2>/dev/null | grep -q reached; then
    echo "FAIL: ${probe_bash} did not abort on ((n++)) at n=0; the guard may be unnecessary"
    exit 1
fi
if ! "$probe_bash" -c 'set -e; n=0; n=$((n + 1)); echo reached' 2>/dev/null | grep -q reached; then
    echo "FAIL: the recommended assignment form should not abort under set -e"
    exit 1
fi

echo "OK: no bare ((x++)) statements that set -e would turn into a silent exit."
