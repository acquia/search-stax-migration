#!/usr/bin/env bash
# tests/generate-docs.sh
# Verifies docs ↔ code drift. Every phase in srsx-migrate's PHASE_ORDER must be:
#   - documented in docs/PHASES.md as its own `## <phase>` section,
#   - listed in the Acquia-doc mapping table at the top of docs/PHASES.md,
#   - present in the README phase table, IN THE SAME ORDER as PHASE_ORDER,
#   - present in the docs/QUICKSTART.md per-phase list.
# Every subcommand in the dispatch must be mentioned in README.md or QUICKSTART.
# Every relative markdown link must resolve.
#
# Presence alone is not enough: the README table once listed `install` before
# `backup` while the code ran them the other way round, and once omitted
# `solrconfig` entirely — neither is visible to a presence-only check.
#
# Usage:
#   bash tests/generate-docs.sh           # report
#   bash tests/generate-docs.sh --check   # exit non-zero on drift (used by CI)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/srsx-migrate"
PHASES_DOC="${REPO_ROOT}/docs/PHASES.md"
QUICKSTART_DOC="${REPO_ROOT}/docs/QUICKSTART.md"
README="${REPO_ROOT}/README.md"

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
    echo "MISSING in PHASES.md: '## \`${p}\`' section"
    fail=1
  fi
  if ! grep -q "^|.*\`${p}\`" "$PHASES_DOC"; then
    echo "MISSING in PHASES.md: \`${p}\` row in the Acquia-doc mapping table"
    fail=1
  fi
  if ! grep -q "^| \`${p}\`" "$README"; then
    echo "MISSING in README.md: \`${p}\` row in the phase table"
    fail=1
  fi
  if ! grep -q "srsx-migrate ${p}\b" "$QUICKSTART_DOC"; then
    echo "MISSING in QUICKSTART.md: './srsx-migrate ${p}' in the per-phase list"
    fail=1
  fi
done

# The README phase table must list phases in execution order.
readme_order="$(grep -o '^| `[a-z]*`' "$README" | tr -d '|` ' | tr '\n' ' ')"
expected_order="$(printf '%s' "$phases")"
readme_order="$(printf '%s' "$readme_order" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
expected_order="$(printf '%s' "$expected_order" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
if [[ "$readme_order" != "$expected_order" ]]; then
  echo "ORDER DRIFT in the README phase table:"
  echo "  code:   ${expected_order}"
  echo "  README: ${readme_order}"
  fail=1
fi

# Every subcommand the dispatch accepts must be discoverable in the docs.
subcommands=$(awk '
  /^[[:space:]]*(init|doctor|status|explain)\)/ {
    sub(/^[[:space:]]*/, ""); sub(/\).*/, ""); print
  }
' "$SCRIPT" | sort -u)

for s in $subcommands; do
  if ! grep -q "srsx-migrate ${s}\b" "$README" && \
     ! grep -q "srsx-migrate ${s}\b" "$QUICKSTART_DOC"; then
    echo "UNDOCUMENTED subcommand: './srsx-migrate ${s}' is dispatchable but appears in neither README.md nor QUICKSTART.md"
    fail=1
  fi
done

# Relative markdown links must resolve. A doc consolidation that leaves a
# dangling link is exactly the kind of rot this file exists to catch.
while IFS= read -r doc; do
  doc_dir="$(dirname "$doc")"
  while IFS= read -r target; do
    target="${target%%#*}"
    [[ -z "$target" ]] && continue
    if [[ ! -e "${doc_dir}/${target}" ]]; then
      echo "BROKEN LINK in ${doc#"${REPO_ROOT}"/}: ${target}"
      fail=1
    fi
  done < <( { grep -o ']([^)]*)' "$doc" || true; } \
            | sed 's/^](//; s/)$//' \
            | grep -v '^[a-z][a-z0-9+.-]*:' \
            | grep -v '^#' || true )
done < <(find "$REPO_ROOT" -name '*.md' \
           -not -path '*/searchstax-1.x/*' \
           -not -path '*/search_api-8.x-1.x/*' \
           -not -path '*/acquia_search-3.1.x/*' \
           -not -path '*/.git/*')

if (( fail )); then
  echo
  echo "Documentation is out of sync with the code."
  [[ "$mode" == "--check" ]] && exit 1
  exit 0
fi

echo "OK: every phase, subcommand, and relative link checks out (${phases})"
