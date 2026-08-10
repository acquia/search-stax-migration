#!/usr/bin/env bash
# tests/test-cache-rebuild-resilient.sh
#
# A contrib module with a bad service definition makes Drupal's container fail
# to compile, so `drush cr` errors out:
#
#   Service "searchstax.flood_subscriber" must implement interface
#   "Symfony\Component\EventDispatcher\EventSubscriberInterface".
#
# That is a module defect, not a migration step, and it must not strand the run
# half-way through — but it must also never pass silently, because the site
# keeps serving its old container until it is fixed.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && { echo "--- output ---"; cat "$2"; }; exit 1; }

# No phase may call bare `drush cr` — that aborts the run under set -e.
if grep -nE '^[[:space:]]*drush cr[[:space:]]*$' srsx-migrate; then
    fail "use drush_cr (resilient) instead of a bare 'drush cr'"
fi
echo "  no bare 'drush cr' call sites OK"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# acli stand-in whose `cr` fails exactly the way the real one did.
cat > "$W/acli" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "cr" ]]; then
    echo 'In RegisterEventSubscribersPass.php line 33:' >&2
    echo '  Service "searchstax.flood_subscriber" must implement interface "Symfony\Component\EventDispatcher\EventSubscriberInterface".' >&2
    exit 1
  fi
done
echo "(ok)"
EOF
chmod +x "$W/acli"

sed -n '/^drush_cr()/,/^}/p' srsx-migrate > "$W/fn.sh"
sed -n '/^_ssx_service_class()/,/^}/p' srsx-migrate >> "$W/fn.sh"
[[ -s "$W/fn.sh" ]] || fail "could not extract drush_cr() from srsx-migrate"

OUT="$W/out.log"
PATH="$W:$PATH" bash -c '
set -euo pipefail
SRSX_CR_FAILED=0; SRSX_CR_PROBED=0; DEMO=0; DRY_RUN=0
warn(){ printf "[WARN] %s\n" "$*"; }
info(){ printf "%s\n" "$*"; }
audit(){ :; }
drush(){ acli remote:drush x -- "$@"; }
drush_php(){ printf "PROBE %s\n" "$*"; }
ACQUIA_APP=demoapp; EFFECTIVE_ENV=dev; DRUSH_URI=""; SRSX_CURRENT_PHASE=server
source "$1/fn.sh"
drush_cr
echo "RC=$?"
echo "FLAG=$SRSX_CR_FAILED"
' _ "$W" >"$OUT" 2>&1 || fail "drush_cr aborted the caller (it must not)" "$OUT"

grep -q "^RC=0$"   "$OUT" || fail "drush_cr did not return 0 after a failed rebuild" "$OUT"
grep -q "^FLAG=1$" "$OUT" || fail "drush_cr did not record the failure" "$OUT"
grep -q "Cache rebuild failed" "$OUT" || fail "no warning was printed" "$OUT"
grep -q "will not take effect" "$OUT" \
    || fail "consequences of a stale container were not explained" "$OUT"

# The interface error means the LOADED class is wrong, so the run must probe the
# environment rather than blame the module's source.
grep -q "PROBE inspect-service-class.php SRSX_CLASS=Drupal\\\\searchstax\\\\EventSubscriber\\\\FloodSubscriber" "$OUT" \
    || fail "the failing service class was not inspected on the environment" "$OUT"

echo "  failed rebuild warns, probes the environment, and continues OK"

# A successful rebuild must stay silent about failure and leave the flag clear.
cat > "$W/acli" <<'EOF'
#!/usr/bin/env bash
echo "[success] Cache rebuild complete."
EOF
chmod +x "$W/acli"
PATH="$W:$PATH" bash -c '
set -euo pipefail
SRSX_CR_FAILED=0; SRSX_CR_PROBED=0; DEMO=0; DRY_RUN=0
warn(){ printf "[WARN] %s\n" "$*"; }
info(){ printf "%s\n" "$*"; }
audit(){ :; }
drush(){ acli remote:drush x -- "$@"; }
drush_php(){ printf "PROBE %s\n" "$*"; }
ACQUIA_APP=demoapp; EFFECTIVE_ENV=dev; DRUSH_URI=""; SRSX_CURRENT_PHASE=server
source "$1/fn.sh"
drush_cr
echo "FLAG=$SRSX_CR_FAILED"
' _ "$W" >"$OUT" 2>&1 || fail "drush_cr failed on a healthy rebuild" "$OUT"

grep -q "^FLAG=0$" "$OUT" || fail "healthy rebuild wrongly recorded a failure" "$OUT"
grep -q "Cache rebuild failed" "$OUT" && fail "healthy rebuild printed a failure warning" "$OUT"

echo "  healthy rebuild stays clean OK"
echo "  cache-rebuild-resilient OK"
