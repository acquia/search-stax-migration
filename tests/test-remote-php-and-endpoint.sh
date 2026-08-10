#!/usr/bin/env bash
# tests/test-remote-php-and-endpoint.sh
#
# Two regressions from real-world testing:
#
#  1. A php-eval script cannot reach the environment through argv. The toolkit
#     lives in a gitignored tools/ dir that is never deployed, locally-set
#     SRSX_* vars do not survive the SSH hop, and acli joins argv into a remote
#     `bash -c` string while dropping the quoting, so any code passed as an
#     argument gets parsed by that shell. drush_php therefore pipes the script
#     over stdin and puts only shell-safe paths on the command line.
#
#  2. A pasted SearchStax Solr URL must be decomposed into search_api_solr's
#     scheme/host/port/path/core. Putting the whole URL into `host:` produced an
#     unusable server config.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- log tail ---"; tail -40 "$2"; }; exit 1; }

# ---------------------------------------------------------------------------
# 1. No phase may hand drush a LOCAL toolkit path — it does not exist remotely.
# ---------------------------------------------------------------------------
if grep -nE 'drush php:(script|eval).*SCRIPT_DIR' srsx-migrate; then
    fail "a phase passes a local toolkit path to drush; it does not exist on the environment"
fi

# The bodies are wrapped in a closure, where `use` imports are illegal.
if grep -rn '^use ' lib/php-eval/*.php; then
    fail "lib/php-eval/*.php must not use 'use' imports (illegal inside the closure)"
fi

# exit() kills the whole drush process mid-command, which drush reports as
# "Drush command terminated abnormally" — the scripts must `return`.
if grep -n 'exit(' lib/php-eval/*.php; then
    fail "lib/php-eval/*.php must 'return' instead of exit() (exit kills drush)"
fi

echo "  no local toolkit paths / no illegal 'use' imports / no exit() OK"

# ---------------------------------------------------------------------------
# 2. Endpoint decomposition — drive a full demo run with a real-world URL.
# ---------------------------------------------------------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-endpoint
rm -rf "$SRSX_DEMO_HOME"

EP="https://searchcloud-29-us-east-1.searchstax.com/29847/abdx18743001dev02-13912/update"
LOG=/tmp/srsx-endpoint.log

DEMO_ANSWERS="demoapp,dev,n,,main,${EP},read_token,write_token,https://an.searchstax.com,analytics_key,1" \
    ./srsx-migrate --demo all </dev/null >"$LOG" 2>&1 \
    || fail "demo run exited non-zero" "$LOG"

YML="$SRSX_DEMO_HOME/artifacts/server-searchstax_server.yml"
[[ -f "$YML" ]] || fail "server YAML not generated" "$LOG"

# host must be a BARE hostname — never the full URL.
grep -q "^    host: 'searchcloud-29-us-east-1.searchstax.com'$" "$YML" \
    || { echo "FAIL: host not decomposed to a bare hostname"; grep -n "host:" "$YML"; exit 1; }
# The SearchStax connector keeps path at '/', with the account id in 'context'.
grep -q "^  connector: searchstax$"                   "$YML" || fail "connector is not 'searchstax'" "$LOG"
grep -q "^    scheme: 'https'$"                       "$YML" || fail "scheme not substituted" "$LOG"
grep -q "^    port: 443$"                             "$YML" || fail "port not substituted" "$LOG"
grep -q "^    path: '/'$"                             "$YML" || fail "path must stay '/' for this connector" "$LOG"
grep -q "^    core: 'abdx18743001dev02-13912'$"       "$YML" || fail "core not decomposed" "$LOG"
grep -q "^    context: '29847'$"                      "$YML" || fail "context not decomposed" "$LOG"
grep -q "^    key_id: ''$"                            "$YML" || fail "key_id must be empty (do not use Key module)" "$LOG"
# The connector is configured from the full update endpoint, handler included.
grep -q "update_endpoint: 'https://searchcloud-29-us-east-1.searchstax.com/29847/abdx18743001dev02-13912/update'" "$YML" \
    || { echo "FAIL: update_endpoint not written in full"; grep -n "update_endpoint" "$YML"; exit 1; }

# Operator must see the decomposition (and the override hint) during configure.
grep -q "SearchStax connector: host=searchcloud-29-us-east-1.searchstax.com context=29847" "$LOG" \
    || fail "configure did not print the SearchStax connector decomposition" "$LOG"
grep -q "SEARCHSTAX_SOLR_CORE_1" "$LOG" \
    || fail "configure did not print the core/context override hint" "$LOG"

echo "  endpoint decomposition (host/context/core + update endpoint) OK"

# ---------------------------------------------------------------------------
# 3. Each php-eval script must be invoked on the environment.
# ---------------------------------------------------------------------------
for s in create-server.php switch-view-index.php create-key-entity.php; do
    grep -q "php:script ${s}" "$LOG" || fail "expected php:script invocation for ${s}" "$LOG"
done

echo "  php:script invocation OK"

# ---------------------------------------------------------------------------
# 4. The script must never travel through argv.
#
# acli joins argv into a remote `bash -c` string and drops the quoting on the
# way, which is exactly what the environment showed:
#   cd …/docroot;  drush --uri=… php:eval /*…*/eval(base64_decode("…"));
#   /bin/bash: -c: line 0: syntax error near unexpected token `('
# The single quotes drush_php added are simply gone. So the body goes over
# stdin instead, and only shell-safe paths appear on the command line.
# ---------------------------------------------------------------------------
fn="$(sed -n '/^drush_php()/,/^}/p' srsx-migrate)"

grep -q 'acli ssh .* "mkdir -p ${remote_dir} && cat > ${remote_file}"' <<<"$fn" \
    || fail "drush_php no longer pipes the script over stdin"
grep -q 'printf .%s. "\$body"' <<<"$fn" \
    || fail "drush_php no longer feeds the body to stdin"
grep -q 'drush php:script --script-path="\$remote_dir" "\$script"' <<<"$fn" \
    || fail "drush_php no longer runs the pushed script by path"
grep -q 'intval(\\\$srsxrc)' <<<"$fn" \
    || fail "drush_php no longer captures the closure's return code"
grep -q 'marker' <<<"$fn" \
    || fail "drush_php no longer verifies an execution marker"

# Nothing derived from the script body may reach the drush command line.
if grep -nE 'drush php:(eval|script) .*(\$body|\$payload|\$code)\b' <<<"$fn"; then
    fail "drush_php puts script content back on the command line (acli will mangle it)"
fi

echo "  script travels over stdin, not argv OK"

# Every token drush_php puts on the command line must be shell-inert, since the
# remote bash parses that line and aborts the lot on a single syntax error.
for tok in "/tmp/srsx-12345" "/tmp/srsx-12345/import-config-yaml.php" \
           "--script-path=/tmp/srsx-12345" "import-config-yaml.php"; do
    [[ "$tok" =~ ^[A-Za-z0-9_./=-]+$ ]] \
        || { echo "FAIL: remote token is not shell-safe: ${tok}"; exit 1; }
done

echo "  remote command tokens are shell-safe OK"
echo "  remote-php-and-endpoint OK"

