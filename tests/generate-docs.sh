#!/usr/bin/env bash
# tests/generate-docs.sh
# Verifies docs ↔ code drift:
#   - Every phase in srsx-migrate's PHASE_ORDER is referenced in docs/PHASES.md.
#   - Every phase has a row in docs/MAPPING.md.
#
# Usage:
#   bash tests/generate-docs.sh           # report
#   bash tests/generate-docs.sh --check   # exit non-zero on drift (used by CI)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/srsx-migrate"
PHASES_DOC="${REPO_ROOT}/docs/PHASES.md"
MAPPING_DOC="${REPO_ROOT}/docs/MAPPING.md"

# Parse the PHASE_ORDER array literal out of srsx-migrate.
phases=$(awk '
  /readonly -a PHASE_ORDER=\(/ { capture=1; next }
  capture && /\)/              { exit }
  capture                       { print }
' "$SCRIPT" | tr -s ' \t\n' ' ')

if [[ -z "$phases" ]]; then
  echo "ERROR: could not parse PHASE_ORDER from $SCRIPT"
  exit 1
fi

mode="${1:-report}"
fail=0
for p in $phases; do
  if ! grep -q "^## \`${p}\`" "$PHASES_DOC"; then
    echo "MISSING in PHASES.md: ## \`${p}\`"
    fail=1
  fi
  if ! grep -q "\`${p}\`" "$MAPPING_DOC"; then
    echo "MISSING in MAPPING.md: \`${p}\` row"
    fail=1
  fi
done

if (( fail )); then
  echo
  echo "Documentation is out of sync with PHASE_ORDER."
  [[ "$mode" == "--check" ]] && exit 1
fi

echo "OK: every phase is documented (${phases})"
