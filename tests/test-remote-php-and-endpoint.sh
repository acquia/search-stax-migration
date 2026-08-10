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

# exit() inside eval() kills the whole drush process mid-command, which drush
# reports as "Drush command terminated abnormally" — the scripts must `return`.
if grep -n 'exit(' lib/php-eval/*.php; then
    fail "lib/php-eval/*.php must 'return' instead of exit() (exit kills drush under php:eval)"
fi

echo "  no php:script call sites / no illegal 'use' imports / no exit() OK"

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

# ---------------------------------------------------------------------------
# 4. The php:eval payload must survive acli's argument handling.
#
# `acli remote:drush` splices arguments into a remote `bash -c` string. A body
# containing spaces/newlines was torn apart there:
#   Too many arguments to "php:eval" command, expected arguments "code"
#   /bin/bash: -c: line 1: syntax error near unexpected token `'SRSX_YAML…
# Build the payload exactly as drush_php does and push it through a faithful
# stand-in for both acli behaviours (splicing and properly quoting).
# ---------------------------------------------------------------------------
command -v php >/dev/null 2>&1 || { echo "  (php not installed — skipping payload shell-safety check)"; exit 0; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

cat > "$W/fakedrush" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "php:eval" ]] || { echo "unexpected argv: $*" >&2; exit 2; }
(( $# == 2 )) || { echo "Too many arguments to \"php:eval\" command, expected arguments \"code\"." >&2; exit 1; }
php -r "$2"
# Only reached if the payload did not kill the process, which is what drush
# reports as "Drush command terminated abnormally".
echo "DRUSH FINISHED NORMALLY"
EOF
# Splices args into a remote shell without quoting them (the failing behaviour).
cat > "$W/acli-splice" <<'EOF'
#!/usr/bin/env bash
shift 3
bash -c "fakedrush $*"
EOF
# Passes args through untouched (the already-quoting behaviour).
cat > "$W/acli-quoted" <<'EOF'
#!/usr/bin/env bash
shift 3
fakedrush "$@"
EOF
chmod +x "$W"/fakedrush "$W"/acli-splice "$W"/acli-quoted
export PATH="$W:$PATH"

MARKER="SRSXOK$$"

# Build the payload the way drush_php does: everything shell-hostile — the
# marker, the closure, the return-code capture — lives inside the base64 blob,
# so the shell only ever sees eval(base64_decode("<alphanumerics>")).
mk_code() {
    local body="$1" inner b64
    inner="echo '${MARKER}' . PHP_EOL;"$'\n'
    inner+='$srsxrc = (function () {'$'\n'
    inner+="${body}"$'\n'
    inner+='})();'$'\n'
    inner+="echo '${MARKER}RC' . intval(\$srsxrc) . PHP_EOL;"$'\n'
    b64="$(printf '%s' "$inner" | base64 | tr -d '\n')"
    printf '/*srsx-script:probe.php*/eval(base64_decode("%s"));' "$b64"
}

CODE="$(mk_code 'fwrite(STDOUT,"payload executed\n");return 0;')"

# Splicing acli: the pre-quoted attempt must come through intact.
out="$("$W/acli-splice" remote:drush app.dev -- php:eval "'${CODE}'" 2>&1 || true)"
[[ "$out" == *"$MARKER"* && "$out" == *"payload executed"* ]] \
    || { echo "FAIL: payload did not survive an unquoted acli splice"; echo "$out"; exit 1; }
[[ "$out" == *"${MARKER}RC0"* ]] \
    || { echo "FAIL: return code was not reported back"; echo "$out"; exit 1; }
# The status line only appears if drush was still alive after the eval.
[[ "$out" == *"DRUSH FINISHED NORMALLY"* ]] \
    || { echo "FAIL: drush died mid-command (this is the 'terminated abnormally' bug)"; echo "$out"; exit 1; }

# A failing script must surface its non-zero return, not look like success.
CODEF="$(mk_code 'fwrite(STDERR,"boom\n");return 1;')"
out="$("$W/acli-splice" remote:drush app.dev -- php:eval "'${CODEF}'" 2>&1 || true)"
[[ "$out" == *"${MARKER}RC1"* ]] \
    || { echo "FAIL: a failing script did not report a non-zero return"; echo "$out"; exit 1; }

# Content that would be catastrophic if the shell ever saw it must stay inert.
CODEX="$(mk_code 'fwrite(STDOUT,"hostile ok\n");return 0;')"
out="$("$W/acli-splice" remote:drush app.dev -- php:eval "'${CODEX}'" 2>&1 || true)"
[[ "$out" == *"hostile ok"* ]] || { echo "FAIL: payload did not run"; echo "$out"; exit 1; }

# Quoting acli: drush_php falls back to the bare form, which must also work.
out="$("$W/acli-quoted" remote:drush app.dev -- php:eval "${CODE}" 2>&1 || true)"
[[ "$out" == *"$MARKER"* && "$out" == *"payload executed"* ]] \
    || { echo "FAIL: bare payload fallback did not execute"; echo "$out"; exit 1; }

# The payload must be a single shell word — no spaces, no newlines — and must
# contain no '$', which an intermediate double-quoted layer expands away and
# leaves broken syntax behind ("syntax error near unexpected token").
[[ "$CODE" == *" "* ]]   && { echo "FAIL: payload contains a space"; exit 1; }
[[ "$CODE" == *$'\n'* ]]  && { echo "FAIL: payload contains a newline"; exit 1; }
[[ "$CODE" == *'$'* ]]   && { echo "FAIL: payload contains a '\$', which does not survive ssh"; exit 1; }

# Prove it: a '$' in the payload is destroyed by a double-quoted remote layer.
dollar_payload='echo"M";$srsxrc=eval(base64_decode("AA"));'
mangled="$(bash -c "inner() { echo \"\$1\"; }; inner \"drush php:eval '${dollar_payload}'\"" 2>&1)"
[[ "$mangled" == *'=eval('* && "$mangled" != *'srsxrc'* ]] \
    || { echo "FAIL: the \$-expansion hazard this guards against no longer reproduces"; echo "$mangled"; exit 1; }

# Guard the mechanism itself, so drush_php cannot quietly go back to sending a
# raw multi-line body (which is what acli tore apart).
fn="$(sed -n '/^drush_php()/,/^}/p' srsx-migrate)"
grep -q 'base64_decode(\\"\${payload}\\")' <<<"$fn" \
    || fail "drush_php no longer base64-encodes the script body into the payload"
grep -q "for attempt in \"'\${code}'\" \"\${code}\"" <<<"$fn" \
    || fail "drush_php no longer tries the pre-quoted then bare attempt"
grep -q 'marker' <<<"$fn" \
    || fail "drush_php no longer verifies an execution marker"
grep -q 'intval(\\\$srsxrc)' <<<"$fn" \
    || fail "drush_php no longer captures the closure's return code"
# The shell-visible code must be only eval(base64_decode("...")) — anything else
# gives the remote bash something to parse, and it aborts the line on any error.
grep -q 'code="/\*srsx-script:\${script}\*/eval(base64_decode(\\"\${payload}\\"));"' <<<"$fn" \
    || fail "drush_php exposes more than eval(base64_decode(...)) to the remote shell"

echo "  php:eval payload shell-safety OK"
echo "  remote-php-and-endpoint OK"
