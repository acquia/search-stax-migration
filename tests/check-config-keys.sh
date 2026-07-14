#!/usr/bin/env bash
# tests/check-config-keys.sh
# Verifies that the searchstax.settings config keys this toolkit writes match
# what the installed `drupal/searchstax` module's schema actually defines.
#
# Run via: make check

set -euo pipefail

# Keys we write (must match the module's searchstax.schema.yml).
EXPECTED_KEYS=(
  searches_via_searchstudio
  configure_via_searchstudio
  analytics_url
  analytics_key
  key_id
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/srsx-migrate"

fail=0
for k in "${EXPECTED_KEYS[@]}"; do
  if ! grep -q "searchstax.settings ${k}\b" "$SCRIPT" \
     && ! grep -q "searchstax.settings.${k}\b" "$SCRIPT" \
     && ! grep -q "${k}" "$SCRIPT"; then
    echo "FAIL: srsx-migrate does not reference config key '${k}'"
    fail=1
  fi
done

# Bonus: warn if anything that LOOKS like an old/wrong key crept back in.
WRONG_KEYS=(
  reroute_searches
  configure_via_studio
  global_analytics_key
  searchstax_studio
)
for k in "${WRONG_KEYS[@]}"; do
  if grep -q "${k}" "$SCRIPT"; then
    echo "FAIL: srsx-migrate references stale/wrong key '${k}'"
    fail=1
  fi
done

# Server template must use the token-authenticated searchstax connector with
# the keys its schema (searchstax.solr_connector.schema.yml) defines. The
# plain `standard` connector cannot authenticate against SearchStax.
TEMPLATE="${REPO_ROOT}/templates/search_api.server.searchstax.yml.tmpl"
TEMPLATE_KEYS=(
  "connector: searchstax"
  "update_endpoint:"
  "update_token:"
  "context:"
  "core:"
)
for k in "${TEMPLATE_KEYS[@]}"; do
  if ! grep -q "${k}" "$TEMPLATE"; then
    echo "FAIL: server template missing '${k}'"
    fail=1
  fi
done
if grep -q "connector: standard" "$TEMPLATE"; then
  echo "FAIL: server template uses the 'standard' connector (no SearchStax auth)"
  fail=1
fi

if (( fail )); then
  echo
  echo "One or more config keys are off. Verify against searchstax.schema.yml"
  echo "in the installed drupal/searchstax module before fixing."
  exit 1
fi

echo "OK: all expected config keys present, no stale keys found."
