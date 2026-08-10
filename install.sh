#!/usr/bin/env bash
# install.sh — bootstrap the Acquia Search → SearchStax migration toolkit.
#
# Usage (public repo):
#   curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/acquia/search-stax-migration/main/install.sh | bash -s -- --target /path/to/repo
#
# Usage (private repo — set GITHUB_TOKEN or GH_TOKEN before running):
#   export GITHUB_TOKEN="ghp_..."
#   curl -fsSL \
#     -H "Authorization: Bearer $GITHUB_TOKEN" \
#     -H "Accept: application/vnd.github.raw" \
#     "https://api.github.com/repos/acquia/search-stax-migration/contents/install.sh?ref=main" | bash
#
# The installer automatically detects GITHUB_TOKEN / GH_TOKEN and uses the
# GitHub Contents API for all subsequent file downloads, so the entire
# installation works against a private repository without any extra steps.
#
# What this does:
#   1. Detects the Acquia repo root (composer.json + docroot/) — or accepts --target.
#   2. Creates <repo>/tools/searchstax-migration/ next to docroot/.
#   3. Downloads srsx-migrate, lib/, templates/ from GitHub at the pinned ref.
#   4. Writes a default migration.env and prints next-step guidance.
#
# Re-running this script is safe; existing files are overwritten EXCEPT
# migration.env (which is preserved if it already exists).
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — pinning the ref makes the curl|bash deterministic per release.
# ---------------------------------------------------------------------------
REPO="${SRSX_REPO:-acquia/search-stax-migration}"
REF="${SRSX_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
API_BASE="https://api.github.com/repos/${REPO}/contents"
AUTH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
TARGET=""
DOCS_URL="https://docs.acquia.com/acquia-cloud-platform/migrating-acquia-search-powered-searchstax"

# The set of files the installer downloads. Keep aligned with the repo layout —
# tests/check-install-manifest.sh fails the build if this drifts.
FILES=(
  "srsx-migrate"
  "lib/searchstax_api.sh"
  "lib/php-eval/clone-index.php"
  "lib/php-eval/create-key-entity.php"
  "lib/php-eval/import-config-yaml.php"
  "lib/php-eval/inspect-service-class.php"
  "lib/php-eval/switch-view-index.php"
  "lib/php-eval/set-multisite-prefix.php"
  "lib/demo/bin/drush"
  "lib/demo/bin/composer"
  "lib/demo/bin/acli"
  "lib/demo/bin/curl"
  "lib/demo/bin/git"
  "lib/demo/bin/jq"
  "lib/demo/fixtures/drush-status.json"
  "lib/demo/fixtures/drush-sapi-s.json"
  "lib/demo/fixtures/drush-sapi-i.json"
  "lib/demo/fixtures/drush-sapi-i-after-clone.json"
  "lib/demo/fixtures/drush-config-get.json"
  "lib/demo/fixtures/drush-pm-list.json"
  "lib/demo/fixtures/composer-require.txt"
  "lib/demo/fixtures/clone-index-result.txt"
  "lib/demo/fixtures/switch-view-result.txt"
  "templates/search_api.server.searchstax.yml.tmpl"
)

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --ref)    REF="$2"; RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"; shift 2 ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Copyright/p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers — minimal, no dependency on the main script.
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  C_HEAD=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi

head() { printf '\n%s▶ %s%s\n' "$C_HEAD" "$*" "$C_RST"; }
ok()   { printf '%s[OK]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }

# ---------------------------------------------------------------------------
# Detect the Acquia repo root.
# ---------------------------------------------------------------------------
detect_repo_root() {
  local dir="${1:-$PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/composer.json" && -d "$dir/docroot" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"
}

download_file() {
  local relpath="$1"
  local dest="$2"
  local raw_url="${RAW_BASE}/${relpath}"

  if [[ -n "${AUTH_TOKEN}" ]]; then
    # Private repos require authenticated fetches from the GitHub Contents API.
    local api_url="${API_BASE}/${relpath}?ref=${REF}"
    curl -fsSL \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      -H "Accept: application/vnd.github.raw" \
      "$api_url" -o "$dest"
    return $?
  fi

  curl -fsSL "$raw_url" -o "$dest"
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
head "Acquia Search → SearchStax migration toolkit installer"
dim "Reference: ${DOCS_URL}"

require_cmd curl
require_cmd mkdir
require_cmd chmod

if [[ -z "$TARGET" ]]; then
  TARGET="$(detect_repo_root "$PWD")" || err \
    "Could not auto-detect the Acquia repo root from $PWD.
       Re-run with: bash install.sh --target /path/to/your/acquia/repo
       (Looking for a directory containing both composer.json AND docroot/)"
fi

[[ -d "$TARGET" ]] || err "Target does not exist: $TARGET"
[[ -f "$TARGET/composer.json" ]] || warn "No composer.json at $TARGET — proceeding anyway."

DEST="${TARGET}/tools/searchstax-migration"
ok "Repo root:    $TARGET"
ok "Install path: $DEST"
ok "Source ref:   ${REPO}@${REF}"
if [[ -n "${AUTH_TOKEN}" ]]; then
  ok "Download mode: authenticated GitHub API"
else
  ok "Download mode: raw.githubusercontent.com"
fi

mkdir -p "$DEST"/{lib/php-eval,lib/demo/bin,lib/demo/fixtures,templates,artifacts,logs,state}

# Keep the toolkit (and especially migration.env, which may hold secrets) out
# of the customer's repo/deploy. Written once; preserved if already present.
GITIGNORE="${DEST}/.gitignore"
if [[ ! -e "$GITIGNORE" ]]; then
  cat > "$GITIGNORE" <<'GITIGNORE_EOF'
# Managed by srsx-migrate — do NOT commit the migration toolkit into your repo.
# This directory holds runtime state, logs, artifacts, and migration.env
# (which may contain secrets). Reinstall any time via install.sh.
*
GITIGNORE_EOF
  ok "Wrote ${GITIGNORE} (keeps the toolkit + migration.env out of your repo)"
fi

head "Downloading toolkit files"
for relpath in "${FILES[@]}"; do
  dest="${DEST}/${relpath}"
  mkdir -p "$(dirname "$dest")"
  if download_file "$relpath" "$dest"; then
    dim "  + ${relpath}"
  else
    err "Download failed: ${relpath}
       (Check that ${REPO}@${REF} is reachable, the file exists, and your token has access.)"
  fi
done

# Make executables actually executable.
chmod +x "${DEST}/srsx-migrate" "${DEST}"/lib/demo/bin/*
ok "Downloaded ${#FILES[@]} files"

# ---------------------------------------------------------------------------
# Default migration.env (preserved if already present).
# ---------------------------------------------------------------------------
ENVFILE="${DEST}/migration.env"
if [[ -f "$ENVFILE" ]]; then
  warn "Existing migration.env preserved at $ENVFILE"
else
  cat > "$ENVFILE" <<'ENVEOF'
# srsx-migrate runtime configuration.
# Edit and commit-IGNORE this file. Secrets should NOT live here long-term;
# prefer the Key module (see docs/SECURITY.md).

# ---------------------------------------------------------------------------
# Acquia target (REQUIRED). The toolkit runs every drush call as
#   acli remote:drush ${ACQUIA_APP}.${ACQUIA_TARGET_ENV} -- ...
# Pick a non-prod env (dev or stage) so you can validate the migration before
# it goes live; once you're happy, deploy the staged changes through your
# normal Acquia workflow.
# Leave blank to be prompted on first run (./srsx-migrate init).
# ---------------------------------------------------------------------------
ACQUIA_APP=""
ACQUIA_TARGET_ENV="dev"

# For multi-site Drupal, leave blank for "ask interactively at runtime",
# OR set --uri values comma-separated, e.g. "https://siteA.test,https://siteB.test".
SITES=""

# Acquia Search SearchStax credentials. Leave blank to be prompted interactively.
# DO NOT commit this file with secrets in it.
SEARCHSTAX_APP_ENDPOINT=""
SEARCHSTAX_READ_TOKEN=""
SEARCHSTAX_WRITE_TOKEN=""
SEARCHSTAX_ANALYTICS_URL=""
SEARCHSTAX_ANALYTICS_KEY=""

# Where the analytics key gets stored on the Drupal side:
#   "key"   — Key module entity (recommended; matches Acquia docs)
#   "plain" — written into searchstax.settings.analytics_key directly
SECRET_STORAGE="key"

# When uninstalling acquia_search at the end, set to 1 if your site depends on
# acquia_cms_toolbar / acquia_cms_common (which require acquia_search).
KEEP_ACQUIA_SEARCH_IN_COMPOSER=0
ENVEOF
  ok "Wrote default migration.env"
fi

# ---------------------------------------------------------------------------
# Next steps banner.
# ---------------------------------------------------------------------------
head "Done. Next steps"
cat <<EOF
  1. cd $DEST
  2. ./srsx-migrate --demo               # safe walkthrough, no real changes
  3. ./srsx-migrate                      # interactive guided migration
  4. ./srsx-migrate explain <phase>      # see what each phase does
  5. ./srsx-migrate --help               # full reference

  Documentation: $DOCS_URL
  Toolkit docs:  https://github.com/${REPO}#readme
EOF
