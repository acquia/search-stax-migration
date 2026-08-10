#!/usr/bin/env bash
# tests/test-provision-skip-when-endpoint-set.sh
#
# Regression test: when SEARCHSTAX_APP_ENDPOINT is already set in
# migration.env, `./srsx-migrate provision` must short-circuit cleanly
# WITHOUT reaching the SearchStax API. We prove "no network" by putting
# a failing curl shim on PATH and asserting it never fires.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

WORK="/tmp/srsx-provision-skip-test"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/state"

# A curl shim that fails if invoked.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: curl was invoked during provision short-circuit" >&2
echo "  args: $*" >&2
exit 42
EOF
chmod +x "$WORK/bin/curl"

# Pre-populate the env file with an endpoint, plus a minimal init marker so
# ensure_init() doesn't try to run the wizard.
cat > "$WORK/migration.env" <<'EOF'
ACQUIA_APP="demoapp"
ACQUIA_TARGET_ENV="dev"
SEARCHSTAX_APP_ENDPOINT="https://already.set.example.com/solr"
EOF

# Point SRSX_HOME at $WORK so artifacts/state/logs land there, and prepend
# our shim to PATH so the tripwire fires if provision ever calls curl.
export SRSX_HOME="$WORK"
export STATE_DIR="$WORK/state"   # belt-and-suspenders (script derives this from SRSX_HOME)
export PATH="$WORK/bin:$PATH"

# Make ensure_init a no-op by pre-marking init.done.
mkdir -p "$WORK/state"
: > "$WORK/state/init.done"

# Provision should print the skip message and exit 0. --only keeps this to the
# one phase; without it a named phase continues into the ones that follow.
out="$(./srsx-migrate --yes provision --only </dev/null 2>&1)" || {
    rc=$?
    echo "FAIL: provision exited $rc"
    echo "--- output ---"
    echo "$out"
    exit 1
}

if ! grep -q "App endpoint already configured" <<<"$out"; then
    echo "FAIL: expected 'App endpoint already configured' short-circuit message"
    echo "--- output ---"
    echo "$out"
    exit 1
fi

if grep -q "curl was invoked" <<<"$out"; then
    echo "FAIL: curl tripwire fired — provision attempted real HTTP"
    echo "--- output ---"
    echo "$out"
    exit 1
fi

# state/done-provision marker must exist.
if [[ ! -f "$WORK/state/done-provision" ]]; then
    echo "FAIL: state/done-provision marker not written"
    exit 1
fi

echo "  provision-skip-when-endpoint-set OK"
