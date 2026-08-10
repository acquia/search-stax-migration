#!/usr/bin/env bash
# tests/check-install-manifest.sh
#
# install.sh downloads an explicit FILES list. When a new runtime file is added
# to the repo but not to that list, every fresh install is silently incomplete —
# which is exactly how lib/php-eval/import-config-yaml.php went missing and blew
# up the 'server' phase on a real migration ("php-eval script missing: …").
#
# This check fails if the manifest and the repo's runtime trees disagree.
# Only runtime files ship; tests/ and docs/ are intentionally excluded.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sed -n '/^FILES=(/,/^)/p' install.sh \
  | grep -oE '"[^"]+"' | tr -d '"' | sort > "$work/manifest.txt"

find srsx-migrate lib templates -type f | sort > "$work/ondisk.txt"

missing="$(comm -23 "$work/ondisk.txt" "$work/manifest.txt")"
stale="$(comm -13 "$work/ondisk.txt" "$work/manifest.txt")"

rc=0
if [[ -n "$missing" ]]; then
    echo "FAIL: these runtime files exist but install.sh will NOT download them:"
    sed 's/^/    /' <<<"$missing"
    echo "  → add them to the FILES array in install.sh"
    rc=1
fi
if [[ -n "$stale" ]]; then
    echo "FAIL: install.sh lists files that no longer exist:"
    sed 's/^/    /' <<<"$stale"
    echo "  → remove them from the FILES array in install.sh"
    rc=1
fi
(( rc == 0 )) || exit 1

# Every script srsx-migrate hands to drush_php must actually ship.
while IFS= read -r s; do
    [[ -f "lib/php-eval/${s}" ]] \
        || { echo "FAIL: srsx-migrate calls drush_php ${s} but lib/php-eval/${s} is missing"; exit 1; }
    grep -qxF "lib/php-eval/${s}" "$work/manifest.txt" \
        || { echo "FAIL: drush_php ${s} is not in the install.sh FILES manifest"; exit 1; }
done < <(grep -oE 'drush_php [a-z0-9-]+\.php' srsx-migrate | awk '{print $2}' | sort -u)

echo "OK: install.sh manifest matches the repo ($(wc -l < "$work/manifest.txt" | tr -d ' ') files)."
