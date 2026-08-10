#!/usr/bin/env bash
# tests/test-remote-php-and-endpoint.sh
#
# Two regressions from real-world testing:
#
#  1. `drush php:script <local path>` can never work: drush runs on the remote
#     Acquia env via `acli remote:drush`, but the toolkit lives in a gitignored
#     tools/ dir that is never deployed — and locally-set SRSX_* env vars do not
#     survive the SSH hop. Every php-eval script must therefore be sent inline
#     via `php:eval` (see drush_php). Assert no php:script call sites remain.
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
# 1. No `drush php:script` call sites may remain (they break on the remote).
#    Comment lines are allowed — they explain why the pattern is banned.
# ---------------------------------------------------------------------------
if grep -nE '^[^#]*[^#[:alnum:]]drush php:script' srsx-migrate; then
    echo "FAIL: srsx-migrate still calls 'drush php:script' — use drush_php (php:eval) instead"
    exit 1
fi

# The php-eval bodies are eval'd, where `use` imports are illegal.
if grep -rn '^use ' lib/php-eval/*.php; then
    fail "lib/php-eval/*.php must not use 'use' imports (invalid under php:eval)"
fi

echo "  no php:script call sites / no illegal 'use' imports OK"

# ---------------------------------------------------------------------------
# 2. Endpoint decomposition — drive a full demo run with a real-world URL.
# ---------------------------------------------------------------------------
export SRSX_DEMO_HOME=/tmp/srsx-demo-home-endpoint
rm -rf "$SRSX_DEMO_HOME"

EP="https://searchcloud-29-us-east-1.searchstax.com/29847/abdx18743001dev02-13912/update"
LOG=/tmp/srsx-endpoint.log

DEMO_ANSWERS="demoapp,dev,n,main,${EP},read_token,write_token,https://an.searchstax.com,analytics_key,1" \
    ./srsx-migrate --demo all </dev/null >"$LOG" 2>&1 \
    || fail "demo run exited non-zero" "$LOG"

YML="$SRSX_DEMO_HOME/artifacts/server-searchstax_server.yml"
[[ -f "$YML" ]] || fail "server YAML not generated" "$LOG"

# host must be a BARE hostname — never the full URL.
grep -q "^    host: 'searchcloud-29-us-east-1.searchstax.com'$" "$YML" \
    || { echo "FAIL: host not decomposed to a bare hostname"; grep -n "host:" "$YML"; exit 1; }
grep -q "^    scheme: 'https'$"                       "$YML" || fail "scheme not substituted" "$LOG"
grep -q "^    port: 443$"                             "$YML" || fail "port not substituted" "$LOG"
grep -q "^    path: '/29847'$"                        "$YML" || fail "path not decomposed" "$LOG"
grep -q "^    core: 'abdx18743001dev02-13912'$"       "$YML" || fail "core not decomposed" "$LOG"

# The Solr request handler must never leak into the config.
grep -q "update" "$YML" && fail "trailing /update handler leaked into server config" "$LOG"

# Operator must see the decomposition (and the override hint) during configure.
grep -q "Solr connector: scheme=https host=searchcloud-29-us-east-1.searchstax.com" "$LOG" \
    || fail "configure did not print the Solr connector decomposition" "$LOG"
grep -q "SEARCHSTAX_SOLR_PATH_1" "$LOG" \
    || fail "configure did not print the path/core override hint" "$LOG"

echo "  endpoint decomposition (update handler stripped) OK"

# ---------------------------------------------------------------------------
# 3. php-eval scripts must travel as php:eval, carrying their marker.
# ---------------------------------------------------------------------------
for s in import-config-yaml.php switch-view-index.php create-key-entity.php; do
    grep -q "php:eval <${s}>" "$LOG" || fail "expected php:eval invocation for ${s}" "$LOG"
done

echo "  php:eval invocation OK"
echo "  remote-php-and-endpoint OK"
