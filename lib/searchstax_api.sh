# shellcheck shell=bash
# lib/searchstax_api.sh — SearchStax REST API helpers for srsx-migrate.
#
# Sourced once by srsx-migrate after its logging / prompt helpers are
# defined. Depends on these helpers from the parent script:
#
#   info, warn, err, ok, dim, audit            — output
#   ask, ask_secret, ask_choice, confirm        — prompts
#   _save_env_var, state_get, state_set         — persistence
#   STATE_DIR, DRY_RUN, DEMO                    — globals
#
# Requires `jq` and `curl` on PATH. The phase that uses this module
# (`phase_provision` in srsx-migrate) calls `require_cmd jq` / `require_cmd
# curl` before any helper here is invoked.
#
# ----------------------------------------------------------------------------
# Endpoints + request/response shapes were reverse-engineered from the
# SearchStudio SPA — the Drupal `searchstax` module does not expose app
# creation. Verify against a sandbox SearchStax account before trusting on a
# real customer migration. See /memories/session/plan.md, "Phase 0 —
# Pre-flight research".
# ----------------------------------------------------------------------------
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

# --- API constants --------------------------------------------------------
# Overridable via env for testing / staging endpoints.
SSX_API_V2="${SSX_API_V2:-https://app.searchstax.com/api/rest/v2}"
SSX_API_EM_V1="${SSX_API_EM_V1:-https://app.searchstax.com/api/rest/experience-manager/v1}"
SSX_API_EM_V2="${SSX_API_EM_V2:-https://app.searchstax.com/api/rest/experience-manager/v2}"
SSX_REFERER="${SSX_REFERER:-https://searchstudio.searchstax.com/}"

# --- Session state (filled in by ssx_login + ssx_pick_*) ------------------
SSX_TOKEN="${SSX_TOKEN:-}"
SSX_ACCOUNT="${SSX_ACCOUNT:-${SEARCHSTAX_ACCOUNT:-}}"
SSX_ENV="${SSX_ENV:-${SEARCHSTAX_ENVIRONMENT:-}}"
SSX_REGION_ID="${SSX_REGION_ID:-${SEARCHSTAX_REGION_ID:-}}"
SSX_APP_DEFAULT="${SSX_APP_DEFAULT:-false}"

# Optional create-app fields. Honored only when set in env (parity with the
# colleague's create_apps.sh CLI flags --platform-version-id, --deployment-uid,
# --api-password, --engine-password). srsx-migrate does not prompt for these;
# operators that want them set them in migration.env or the calling shell.
SSX_PLATFORM_VERSION_ID="${SSX_PLATFORM_VERSION_ID:-${SEARCHSTAX_PLATFORM_VERSION_ID:-}}"
SSX_DEPLOYMENT_UID="${SSX_DEPLOYMENT_UID:-${SEARCHSTAX_DEPLOYMENT_UID:-}}"
SSX_API_PASSWORD="${SSX_API_PASSWORD:-${SEARCHSTAX_API_PASSWORD:-}}"
SSX_ENGINE_PASSWORD="${SSX_ENGINE_PASSWORD:-${SEARCHSTAX_ENGINE_PASSWORD:-}}"

# --- Outputs of ssx_create_one_app / ssx_get_app_detail -------------------
# shellcheck disable=SC2034  # Consumed externally by phase_provision in srsx-migrate.
ssx_last_app_id=""
ssx_last_app_response=""
ssx_last_endpoint=""
ssx_last_read_token=""
ssx_last_write_token=""
ssx_last_analytics_url=""

# --- Tiny helpers ---------------------------------------------------------

# URL-encode via jq (avoids a python3 dep). `@uri` does RFC 3986 encoding.
ssx_urlenc() {
  jq -rn --arg s "$1" '$s|@uri'
}

# Session-file path is derived at call time so STATE_DIR can be overridden
# by --demo (which rebases SRSX_HOME under a throwaway tmpdir) without this
# module caring.
_ssx_session_file() {
  printf '%s/searchstax.session\n' "$STATE_DIR"
}

# --- HTTP helper ----------------------------------------------------------
#
# ssx_http <method> <url> [body-json]
# Prints the response body on stdout. Returns non-zero on HTTP != 2xx.
# Always invoked as bare `curl` (NOT `command curl`) so the demo-mode
# tripwire shim at lib/demo/bin/curl fires loudly if provision is ever
# reached in --demo mode (it should be short-circuited well before here).
ssx_http() {
  local method="$1" url="$2" body="${3:-}"
  local tmp; tmp="$(mktemp)"
  local -a args=(-sS -X "$method" "$url"
                 -H "Referer: $SSX_REFERER"
                 -H "Accept: application/json"
                 -o "$tmp"
                 -w '%{http_code}')
  if [[ -n "$SSX_TOKEN" ]]; then
    args+=(-H "Authorization: Token $SSX_TOKEN")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "$body")
  fi

  audit "curl -X $method $url"
  local code
  code="$(curl "${args[@]}" 2>/dev/null)" || code="000"
  cat "$tmp"
  local detail=""
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    # Best-effort extraction of a server-side error message.
    detail="$(jq -r '.detail // .message // .error // ""' < "$tmp" 2>/dev/null || true)"
    warn "HTTP $code on $method $url${detail:+ — $detail}"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# --- Session cache --------------------------------------------------------
#
# Cached so a mid-run failure doesn't force a fresh 2FA TOTP on every retry.
# File format:
#   {"token":"...", "user":"ops@acme.com", "expire":<unix_ts>, "saved_at":<unix_ts>}
# Path: ${STATE_DIR}/searchstax.session  (state/ is already gitignored).

ssx_session_load() {
  local f; f="$(_ssx_session_file)"
  [[ -r "$f" ]] || return 1

  local token user expire now
  token="$(jq -r '.token // empty'        "$f" 2>/dev/null)" || return 1
  user="$( jq -r '.user // empty'         "$f" 2>/dev/null)" || true
  expire="$(jq -r '(.expire // 0)|tostring' "$f" 2>/dev/null)" || return 1
  now="$(date +%s)"
  [[ -n "$token" ]] || return 1
  [[ "$expire" =~ ^[0-9]+$ ]] || return 1
  (( expire > now + 60 )) || return 1   # 60s slack

  SSX_TOKEN="$token"
  if ! ssx_http GET "$SSX_API_V2/account/" >/dev/null 2>&1; then
    SSX_TOKEN=""
    rm -f "$f"
    dim "Cached SearchStax session failed validation — logging in fresh."
    return 1
  fi

  local remaining hrs mins
  remaining=$(( expire - now ))
  hrs=$(( remaining / 3600 ))
  mins=$(( (remaining % 3600) / 60 ))
  ok "Reusing cached SearchStax session as ${user:-unknown} (expires in ${hrs}h ${mins}m)"
  return 0
}

ssx_session_save() {
  local user="$1"
  local f tmp now expire
  f="$(_ssx_session_file)"
  mkdir -p "$STATE_DIR"
  now="$(date +%s)"
  expire=$(( now + 86400 ))
  tmp="${f}.tmp.$$"
  if jq -n --arg token "$SSX_TOKEN" \
          --arg user "$user" \
          --argjson expire "$expire" \
          --argjson saved "$now" \
          '{token: $token, user: $user, expire: $expire, saved_at: $saved}' \
          > "$tmp" 2>/dev/null \
     && mv "$tmp" "$f" \
     && chmod 600 "$f"; then
    return 0
  fi
  rm -f "$tmp"
  warn "Failed to write SearchStax session cache at $f (non-fatal)"
  return 0
}

ssx_session_clear() {
  local f; f="$(_ssx_session_file)"
  if [[ -e "$f" ]]; then
    rm -f "$f"
    ok "Cached SearchStax session cleared ($f)"
  else
    dim "No cached SearchStax session to clear."
  fi
}

# --- Login ---------------------------------------------------------------

ssx_login() {
  info "SearchStax login"

  if ssx_session_load; then
    return 0
  fi

  if [[ -z "${SEARCHSTAX_USER:-}" ]]; then
    ask "SearchStax username (email)" SEARCHSTAX_USER
  fi
  if [[ -z "${SEARCHSTAX_PASS:-}" ]]; then
    ask_secret "SearchStax password" SEARCHSTAX_PASS
  fi
  if [[ -z "${SEARCHSTAX_2FA+x}" ]]; then
    ask "SearchStax 2FA token (press Enter if not enabled)" SEARCHSTAX_2FA ""
  fi

  local body
  body="$(jq -nc \
    --arg u "$SEARCHSTAX_USER" \
    --arg p "$SEARCHSTAX_PASS" \
    --arg t "${SEARCHSTAX_2FA:-}" \
    'if $t == "" then {username:$u, password:$p}
     else {username:$u, password:$p, tfa_token:$t} end')" \
    || err "Failed to build SearchStax login body"

  local resp
  resp="$(ssx_http POST "$SSX_API_V2/obtain-auth-token/" "$body")" \
    || err "SearchStax login failed. Check credentials / 2FA token."
  SSX_TOKEN="$(jq -r '.token // empty' <<<"$resp")" \
    || err "Could not parse SearchStax login response"
  [[ -n "$SSX_TOKEN" ]] || err "SearchStax login response had no 'token' field"
  ok "Logged into SearchStax"
  ssx_session_save "$SEARCHSTAX_USER"
}

# --- Account / environment / region pickers ------------------------------

ssx_pick_account() {
  if [[ -n "$SSX_ACCOUNT" ]]; then
    ok "Using SearchStax account '$SSX_ACCOUNT' (pre-set)"
    return 0
  fi

  local resp
  resp="$(ssx_http GET "$SSX_API_V2/account/")" \
    || err "Failed to list SearchStax accounts"

  local -a accts=()
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] && accts+=("$n")
  done < <(jq -r '.results[]?.name // empty' <<<"$resp")

  if (( ${#accts[@]} == 0 )); then
    err "Your SearchStax login has no accounts associated with it."
  fi
  if (( ${#accts[@]} == 1 )); then
    SSX_ACCOUNT="${accts[0]}"
    ok "Using only account: $SSX_ACCOUNT"
    return 0
  fi

  ask_choice "Choose a SearchStax account" SSX_ACCOUNT "${accts[@]}"
}

ssx_pick_environment() {
  if [[ -n "$SSX_ENV" ]]; then
    ok "SearchStax environment '$SSX_ENV' (pre-set)"
    return 0
  fi
  ask_choice "Choose a SearchStax environment" SSX_ENV Production Sandbox Development
}

# plan_regions is messy across accounts/tiers — observed shapes include:
#   [ {id, region_served} ]                            (flat)
#   { "results"|"data": [ {id, region_served} ] }      (enveloped flat)
#   [ {plan_name, regions: [ {id, region_served} ] } ] (plan-wrapped)
#   { "Premier Plus": [ {id, region_served} ] }        (plan-keyed)
# The jq pipeline below flattens all four into a tab-separated
# (id, label) table. If it returns zero rows, we fall back to manual entry
# and dump the raw response so a future tweak has a starting point.
ssx_pick_region() {
  if [[ -n "$SSX_REGION_ID" ]]; then
    ok "SearchStax plan_region_id '$SSX_REGION_ID' (pre-set)"
    return 0
  fi

  local resp
  resp="$(ssx_http GET "$SSX_API_EM_V1/plan_regions?account=$(ssx_urlenc "$SSX_ACCOUNT")")" \
    || err "Failed to list SearchStax plan_regions"

  local table
  table="$(jq -r '
    def to_list:
      if type == "array" then .
      elif type == "object" then
        if .results then .results
        elif .data    then .data
        else [ .[] | select(type=="array") ] | add // []
        end
      else [] end;
    def expand_plans:
      map(
        if type == "object" and (.regions? | type) == "array" then
          (.plan_name // .name // .label // "") as $p
          | .regions | map(. + {_plan: $p})
        else [.] end
      ) | add // [];
    to_list
    | expand_plans
    | map(select(type=="object" and (.id != null)))
    | .[]
    | [
        (.id | tostring),
        ((._plan // "") + (if (._plan // "") != "" then " — " else "" end)
         + (.region_served // .region // .name // .label // .display_name // ""))
      ]
    | @tsv
  ' <<<"$resp" 2>/dev/null || true)"

  local -a ids=() labels=()
  local id label
  while IFS=$'\t' read -r id label; do
    [[ -z "$id" ]] && continue
    ids+=("$id"); labels+=("$label")
  done <<<"$table"

  if (( ${#ids[@]} == 0 )); then
    warn "Could not parse plan_regions response. Raw (truncated):"
    printf '%s\n' "${resp:0:1200}" >&2
    ask "Enter the plan_region_id manually" SSX_REGION_ID
    [[ -n "$SSX_REGION_ID" ]] || err "plan_region_id is required."
    return 0
  fi

  info "Choose a SearchStax region:"
  local i
  for ((i=0; i<${#ids[@]}; i++)); do
    dim "  [$((i+1))] id=${ids[$i]}  ${labels[$i]}"
  done

  local pick
  while true; do
    if [[ ! -t 0 ]]; then
      SSX_REGION_ID="${ids[0]}"
      ok "Non-TTY — defaulting to first region: id=$SSX_REGION_ID (${labels[0]})"
      return 0
    fi
    printf '  Region number [1-%d]: ' "${#ids[@]}"
    read -r pick </dev/tty || pick=""
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
      SSX_REGION_ID="${ids[$((pick-1))]}"
      ok "SearchStax region: id=$SSX_REGION_ID (${labels[$((pick-1))]})"
      return 0
    fi
    info "Enter a number 1..${#ids[@]}"
  done
}

# --- App name validation -------------------------------------------------
#
# Server rule: 6..126 chars of [A-Za-z0-9_]. The SearchStudio SPA's yup
# schema permits hyphens and dots, but the server rejects them with
# "App name must be 6–126 characters in length, consisting only of letters,
# numbers, or underscores." Enforce the stricter server rule client-side.
ssx_validate_name() {
  local n="$1"
  local len=${#n}
  if (( len < 6 || len > 126 )); then
    warn "Invalid app name '$n': must be 6..126 characters (got $len)"
    return 1
  fi
  if ! [[ "$n" =~ ^[A-Za-z0-9_]+$ ]]; then
    local suggested
    suggested="$(printf '%s' "$n" | tr -c 'A-Za-z0-9_' '_')"
    warn "Invalid app name '$n': server accepts only letters, numbers, underscores."
    dim  "  Suggested: $suggested"
    return 1
  fi
  return 0
}

# --- App creation --------------------------------------------------------
#
# Build the JSON body for POST /experience-manager/v2/apps. Exposed as a
# standalone function so tests/test-ssx-json-body.sh can pin the API
# contract without firing an HTTP request.
ssx_build_create_body() {
  local name="$1"
  # Start with the always-present fields, then conditionally add the four
  # optional create-time fields create_apps.sh exposes. Each optional field
  # is added only when its env var is non-empty so the API request stays
  # minimal (and so the server applies its own defaults).
  jq -nc \
    --arg name "$name" \
    --arg env "$SSX_ENV" \
    --argjson default "${SSX_APP_DEFAULT:-false}" \
    --argjson region "${SSX_REGION_ID:-0}" \
    --arg platform "${SSX_PLATFORM_VERSION_ID:-}" \
    --arg uid "${SSX_DEPLOYMENT_UID:-}" \
    --arg api_pw "${SSX_API_PASSWORD:-}" \
    --arg engine_pw "${SSX_ENGINE_PASSWORD:-}" \
    '{name: $name, default: $default, environment: $env, plan_region_id: $region}
     + (if $platform  != "" then {platform_version_id: ($platform|tonumber)} else {} end)
     + (if $uid       != "" then {uid: $uid}                                   else {} end)
     + (if $api_pw    != "" then {api_password: $api_pw}                       else {} end)
     + (if $engine_pw != "" then {engine_password: $engine_pw}                 else {} end)'
}

# POST /experience-manager/v2/apps. On success, sets ssx_last_app_id and
# ssx_last_app_response.
ssx_create_one_app() {
  local name="$1"
  ssx_last_app_id=""
  ssx_last_app_response=""

  local body
  body="$(ssx_build_create_body "$name")" \
    || { warn "Failed to build create-app body for '$name'"; return 1; }
  local url
  url="$SSX_API_EM_V2/apps?account=$(ssx_urlenc "$SSX_ACCOUNT")"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    dim "dry-run: POST $url"
    dim "         body: $body"
    return 0
  fi

  info "Creating SearchStax app '$name'"
  local resp
  resp="$(ssx_http POST "$url" "$body")" \
    || { warn "Failed to create app '$name'"; return 1; }
  ssx_last_app_response="$resp"
  ssx_last_app_id="$(jq -r '.data.id // .id // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -n "$ssx_last_app_id" ]]; then
    ok "Created app '$name' (id=$ssx_last_app_id)"
  else
    ok "Created app '$name' (id not in response)"
  fi
  return 0
}

# GET /experience-manager/v2/apps/<id>. Populates ssx_last_endpoint /
# ssx_last_read_token / ssx_last_write_token / ssx_last_analytics_url.
#
# Field paths below are best-effort: the create-response shape was inferred
# from the SearchStudio SPA. If the API rev changes field names, this
# function returns non-zero and phase_provision falls back to prompting
# the operator (same UX as the pre-provisioning script).
ssx_get_app_detail() {
  local id="$1"
  ssx_last_endpoint=""
  ssx_last_read_token=""
  ssx_last_write_token=""
  ssx_last_analytics_url=""
  [[ -n "$id" ]] || return 1

  local url
  url="$SSX_API_EM_V2/apps/${id}?account=$(ssx_urlenc "$SSX_ACCOUNT")"
  local resp
  resp="$(ssx_http GET "$url")" || {
    warn "Could not fetch app detail (id=$id); endpoint will need to be pasted manually."
    return 1
  }

  ssx_last_endpoint="$(jq -r '
    .data.endpoint_url // .endpoint_url //
    .data.solr_url      // .solr_url      //
    .data.read_url      // .read_url      // empty' <<<"$resp" 2>/dev/null || true)"
  ssx_last_read_token="$(jq -r '
    .data.read_token  // .read_token  // .data.tokens.read  // empty' <<<"$resp" 2>/dev/null || true)"
  ssx_last_write_token="$(jq -r '
    .data.write_token // .write_token // .data.tokens.write // empty' <<<"$resp" 2>/dev/null || true)"
  ssx_last_analytics_url="$(jq -r '
    .data.analytics_url // .analytics_url // empty' <<<"$resp" 2>/dev/null || true)"

  if [[ -z "$ssx_last_endpoint" ]]; then
    warn "App detail response did not include an endpoint URL in any expected field."
    dim  "  Response (first 500 chars): ${resp:0:500}"
    return 1
  fi
  return 0
}
