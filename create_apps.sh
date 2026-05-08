#!/usr/bin/env bash
#
# create_apps.sh — Standalone utility to create SearchStax Site Search apps.
#
# This is a sibling to migrate.sh but does NOT depend on Drupal / drush.
# It hits the SearchStax REST API directly. Endpoint + body shape were
# reverse-engineered from the SearchStudio SPA (the Drupal module does
# not expose app creation).
#
# Typical usage:
#
#   ./create_apps.sh acme-client01-dev acme-client02-dev acme-client03-dev
#
# Interactive (no args):
#
#   ./create_apps.sh
#   → logs in, prompts for account/env/region, then app names one at a time
#
# Flags:
#
#   --account=<name>          SearchStax account (skip if login sees only one)
#   --environment=<value>     Production | Sandbox | Development
#   --region-id=<int>         plan_region_id (list shown if omitted)
#   --platform-version-id=<int>
#                             Optional; omit to let the server choose a default
#   --deployment-uid=<str>    Optional: attach to a specific hosted deployment
#   --default                 Mark the new app as the account default
#   --api-password=<str>      Sets api_password on the new app
#   --engine-password=<str>   Sets engine_password on the new app
#   --dry-run                 Don't POST; show the request body instead
#   --yes, -y                 Don't ask for confirmation before creating
#   --logout                  Delete cached session (.session) and exit
#   -h, --help                Show this help
#
# Environment variables (loaded from .env if present):
#
#   SEARCHSTAX_USER, SEARCHSTAX_PASS, SEARCHSTAX_2FA    credentials
#   SEARCHSTAX_ACCOUNT, SEARCHSTAX_ENVIRONMENT,
#   SEARCHSTAX_REGION_ID, SEARCHSTAX_PLATFORM_VERSION_ID
#                                                       pre-fill answers

set -uo pipefail

SSX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SSX_SCRIPT_DIR/lib/common.sh"

# --- flag parsing ---------------------------------------------------------

SSX_ACCOUNT=""
SSX_ENV=""
SSX_REGION_ID=""
SSX_PLATFORM_VERSION_ID=""
SSX_DEPLOYMENT_UID=""
SSX_APP_DEFAULT="false"
SSX_API_PASSWORD=""
SSX_ENGINE_PASSWORD=""
SSX_APP_NAMES=()

usage() {
  sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'
}

SSX_LOGOUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)                 SSX_DRY_RUN=1 ;;
    --yes|-y)                  SSX_YES=1 ;;
    --logout)                  SSX_LOGOUT=1 ;;
    --account=*)               SSX_ACCOUNT="${1#*=}" ;;
    --environment=*)           SSX_ENV="${1#*=}" ;;
    --region-id=*)             SSX_REGION_ID="${1#*=}" ;;
    --platform-version-id=*)   SSX_PLATFORM_VERSION_ID="${1#*=}" ;;
    --deployment-uid=*)        SSX_DEPLOYMENT_UID="${1#*=}" ;;
    --api-password=*)          SSX_API_PASSWORD="${1#*=}" ;;
    --engine-password=*)       SSX_ENGINE_PASSWORD="${1#*=}" ;;
    --default)                 SSX_APP_DEFAULT="true" ;;
    -h|--help)                 usage; exit 0 ;;
    --)                        shift; while [[ $# -gt 0 ]]; do SSX_APP_NAMES+=("$1"); shift; done; break ;;
    -*)                        log_err "Unknown flag: $1"; usage; exit 64 ;;
    *)                         SSX_APP_NAMES+=("$1") ;;
  esac
  shift || true
done

# --- init -----------------------------------------------------------------

ssx_init_log
ssx_load_env

# Honor env-var defaults (flag wins if both present)
: "${SSX_ACCOUNT:=${SEARCHSTAX_ACCOUNT:-}}"
: "${SSX_ENV:=${SEARCHSTAX_ENVIRONMENT:-}}"
: "${SSX_REGION_ID:=${SEARCHSTAX_REGION_ID:-}}"
: "${SSX_PLATFORM_VERSION_ID:=${SEARCHSTAX_PLATFORM_VERSION_ID:-}}"

# Require python3 (used for JSON parsing and building).
if ! command -v python3 >/dev/null 2>&1; then
  die "python3 is required for JSON parsing. Install it or use a machine that has it."
fi
if ! command -v curl >/dev/null 2>&1; then
  die "curl is required. Install it or use a machine that has it."
fi

# --- API constants --------------------------------------------------------

readonly SSX_API_V2="https://app.searchstax.com/api/rest/v2"
readonly SSX_API_EM_V1="https://app.searchstax.com/api/rest/experience-manager/v1"
readonly SSX_API_EM_V2="https://app.searchstax.com/api/rest/experience-manager/v2"
readonly SSX_REFERER="https://searchstudio.searchstax.com/"
readonly SSX_SESSION_FILE="$SSX_SCRIPT_DIR/.session"

SSX_TOKEN=""        # set by ssx_login

# --- JSON helpers ---------------------------------------------------------

# Build a JSON object from a "|"-separated list of key=type=value entries.
# Types: s (string), i (int), b (bool), o (omit if empty).
# Example:
#   ssx_json_build "name=s=my-app|default=b=false|plan_region_id=i=42|uid=s="
# Omits keys whose value is empty AND type is 'o' or when the value is empty
# for all types except 'b' (which defaults to false when empty).
ssx_json_build() {
  local spec="$1"
  python3 - <<PY
import json, os, sys
spec = os.environ.get("SSX_JSON_SPEC", """$spec""")
out = {}
for entry in spec.split("|"):
    if not entry.strip():
        continue
    try:
        key, typ, val = entry.split("=", 2)
    except ValueError:
        continue
    if val == "" and typ == "o":
        continue
    if typ == "s":
        if val == "":
            continue
        out[key] = val
    elif typ == "i":
        if val == "":
            continue
        try: out[key] = int(val)
        except ValueError: out[key] = val
    elif typ == "b":
        out[key] = (val.lower() == "true")
sys.stdout.write(json.dumps(out))
PY
}

# Print a value from a JSON response using a Python path.
# Example: ssx_json_pick '$.token' '{"token":"abc"}'
ssx_json_pick() {
  local path="$1" json="$2"
  python3 - "$path" "$json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.loads(sys.argv[2])
# Minimal path parser: "$.a.b[0].c"
def walk(d, p):
    if p.startswith("$."):
        p = p[2:]
    elif p == "$":
        return d
    parts = []
    buf = ""
    i = 0
    while i < len(p):
        c = p[i]
        if c == ".":
            if buf: parts.append(buf); buf = ""
        elif c == "[":
            if buf: parts.append(buf); buf = ""
            j = p.index("]", i)
            parts.append(int(p[i+1:j]))
            i = j
        else:
            buf += c
        i += 1
    if buf: parts.append(buf)
    for k in parts:
        if isinstance(k, int):
            d = d[k]
        else:
            d = d[k]
    return d
try:
    v = walk(data, path)
    if isinstance(v, (dict, list)):
        print(json.dumps(v))
    else:
        print(v if v is not None else "")
except (KeyError, IndexError, TypeError):
    sys.exit(2)
PY
}

# --- HTTP helper ----------------------------------------------------------

# ssx_http <method> <url> [body-json]
# Prints the response body on stdout. Returns non-zero on HTTP != 2xx.
# Writes http status + reason to stderr on error.
ssx_http() {
  local method="$1" url="$2" body="${3:-}"
  local tmp_body tmp_head
  tmp_body="$(mktemp)"
  tmp_head="$(mktemp)"
  local -a args=(-sS -X "$method" "$url"
                 -H "Referer: $SSX_REFERER"
                 -H "Accept: application/json"
                 -D "$tmp_head"
                 -o "$tmp_body"
                 -w "%{http_code}")
  if [[ -n "$SSX_TOKEN" ]]; then
    args+=(-H "Authorization: Token $SSX_TOKEN")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "$body")
  fi
  local code
  code="$(curl "${args[@]}")" || code="000"
  cat "$tmp_body"
  if [[ "$code" != 2?? ]]; then
    local detail
    detail="$(python3 -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(d.get("detail") or d.get("message") or "")' "$tmp_body" 2>/dev/null || true)"
    log_err "HTTP $code on $method $url${detail:+ — $detail}"
    rm -f "$tmp_body" "$tmp_head"
    return 1
  fi
  rm -f "$tmp_body" "$tmp_head"
  return 0
}

# --- API calls ------------------------------------------------------------

# --- session cache --------------------------------------------------------
#
# To let you resume after a mid-run failure (e.g. an API shape surprise)
# without re-entering creds — and crucially without burning a fresh 2FA TOTP
# each time — the script caches the auth token in .session (chmod 600,
# gitignored). On startup we load the token, validate it with a cheap
# GET /account/ probe, and skip the prompt entirely if it still works.
#
# File format (JSON):
#   {"token":"...", "user":"ops@acme.com", "expire":<unix_ts>, "saved_at":<unix_ts>}
#
# The SearchStax module assumes a 24h TTL on tokens; we mirror that but
# validate before trusting. Server-side revocation or a shorter real TTL is
# caught by the probe and we fall back to prompting.

# Returns 0 and sets SSX_TOKEN if a cached session is still valid.
ssx_session_load() {
  [[ -r "$SSX_SESSION_FILE" ]] || return 1
  local parsed
  parsed="$(python3 -c '
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    t = d.get("token","")
    u = d.get("user","")
    e = int(d.get("expire", 0))
    if not t or e <= int(time.time()) + 60:  # 60s slack
        sys.exit(1)
    print("{}\t{}\t{}".format(t, u, e))
except Exception:
    sys.exit(1)
' "$SSX_SESSION_FILE" 2>/dev/null)" || return 1

  local token user expire
  IFS=$'\t' read -r token user expire <<<"$parsed"

  # Probe with /account/ to confirm the token is still honoured server-side.
  SSX_TOKEN="$token"
  if ! ssx_http GET "$SSX_API_V2/account/" >/dev/null 2>&1; then
    SSX_TOKEN=""
    rm -f "$SSX_SESSION_FILE"
    log_dim "Cached session failed validation — logging in fresh."
    return 1
  fi

  # Compute a friendly "expires in" string.
  local remaining=$(( expire - $(date +%s) ))
  local hrs=$(( remaining / 3600 ))
  local mins=$(( (remaining % 3600) / 60 ))
  log_ok "Reusing cached session as ${user:-unknown} (expires in ${hrs}h ${mins}m)"
  return 0
}

# Persists SSX_TOKEN + user email to .session.
ssx_session_save() {
  local user="$1"
  local now saved
  now="$(date +%s)"
  saved="$SSX_SESSION_FILE.tmp.$$"
  python3 -c '
import json, sys, time
d = {
  "token": sys.argv[1],
  "user": sys.argv[2],
  "expire": int(time.time()) + 86400,
  "saved_at": int(time.time()),
}
with open(sys.argv[3], "w") as f:
  json.dump(d, f)
' "$SSX_TOKEN" "$user" "$saved" \
    && mv "$saved" "$SSX_SESSION_FILE" \
    && chmod 600 "$SSX_SESSION_FILE" \
    || log_warn "Failed to write session cache at $SSX_SESSION_FILE (non-fatal)"
}

ssx_session_clear() {
  if [[ -e "$SSX_SESSION_FILE" ]]; then
    rm -f "$SSX_SESSION_FILE"
    log_ok "Cached session cleared ($SSX_SESSION_FILE)"
  else
    log_dim "No cached session to clear."
  fi
}

ssx_login() {
  log_step "SearchStax login"

  # Reuse a still-valid cached session if we have one — saves re-entering
  # creds and especially avoids burning another 2FA TOTP.
  if ssx_session_load; then
    return 0
  fi

  if [[ -z "${SEARCHSTAX_USER:-}" ]]; then
    prompt_value "SearchStax username (email)" SEARCHSTAX_USER
  fi
  if [[ -z "${SEARCHSTAX_PASS:-}" ]]; then
    prompt_password "SearchStax password" SEARCHSTAX_PASS
  fi
  if [[ -z "${SEARCHSTAX_2FA+x}" ]]; then
    prompt_value "SearchStax 2FA token (press enter if not enabled)" SEARCHSTAX_2FA ""
  fi

  # Build the login body via python3. We pass the creds inline to the
  # subprocess's environment — prompted bash vars aren't exported, so
  # os.environ in a child process can't see them otherwise.
  local body
  body="$(
    SEARCHSTAX_USER="$SEARCHSTAX_USER" \
    SEARCHSTAX_PASS="$SEARCHSTAX_PASS" \
    SEARCHSTAX_2FA="${SEARCHSTAX_2FA:-}" \
    python3 -c '
import json, os
b = {"username": os.environ["SEARCHSTAX_USER"], "password": os.environ["SEARCHSTAX_PASS"]}
t = os.environ.get("SEARCHSTAX_2FA","")
if t:
    b["tfa_token"] = t
print(json.dumps(b))'
  )" || die "Failed to build login body"

  log_info "POST $SSX_API_V2/obtain-auth-token/"
  local resp
  if ! resp="$(ssx_http POST "$SSX_API_V2/obtain-auth-token/" "$body")"; then
    die "Login failed. Check credentials / 2FA token."
  fi
  SSX_TOKEN="$(ssx_json_pick '$.token' "$resp")" || die "Login response had no 'token'"
  if [[ -z "$SSX_TOKEN" ]]; then
    die "Login response had empty 'token'"
  fi
  log_ok "Logged into SearchStax"
  ssx_session_save "$SEARCHSTAX_USER"
}

# Picks a SearchStax account and stores in SSX_ACCOUNT.
ssx_pick_account() {
  [[ -n "$SSX_ACCOUNT" ]] && { log_ok "Using account '$SSX_ACCOUNT' (pre-set)"; return 0; }

  log_info "GET $SSX_API_V2/account/"
  local resp
  resp="$(ssx_http GET "$SSX_API_V2/account/")" || die "Failed to list accounts"
  local names
  names="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for a in d.get("results", []):
    print(a.get("name",""))' <<<"$resp")"

  local -a accts=()
  while IFS= read -r n; do [[ -n "$n" ]] && accts+=("$n"); done <<<"$names"

  if ((${#accts[@]} == 0)); then
    die "Your SearchStax login has no accounts associated with it."
  fi
  if ((${#accts[@]} == 1)); then
    SSX_ACCOUNT="${accts[0]}"
    log_ok "Using only account: $SSX_ACCOUNT"
    return 0
  fi

  log_info "Choose a SearchStax account:"
  local i
  for ((i=0; i<${#accts[@]}; i++)); do
    log_dim "  [$((i+1))] ${accts[$i]}"
  done
  local pick
  while true; do
    read -r -p "Account number [1-${#accts[@]}]: " pick </dev/tty
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#accts[@]} )); then
      SSX_ACCOUNT="${accts[$((pick-1))]}"
      return 0
    fi
    echo "Enter a number 1..${#accts[@]}"
  done
}

ssx_pick_environment() {
  [[ -n "$SSX_ENV" ]] && { log_ok "Environment '$SSX_ENV' (pre-set)"; return 0; }
  local -a envs=(Production Sandbox Development)
  log_info "Choose an environment:"
  local i
  for ((i=0; i<${#envs[@]}; i++)); do
    log_dim "  [$((i+1))] ${envs[$i]}"
  done
  local pick
  while true; do
    read -r -p "Environment number [1-${#envs[@]}]: " pick </dev/tty
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#envs[@]} )); then
      SSX_ENV="${envs[$((pick-1))]}"
      return 0
    fi
    echo "Enter a number 1..${#envs[@]}"
  done
}

ssx_pick_region() {
  [[ -n "$SSX_REGION_ID" ]] && { log_ok "Region id '$SSX_REGION_ID' (pre-set)"; return 0; }

  log_info "GET $SSX_API_EM_V1/plan_regions?account=$SSX_ACCOUNT"
  local resp
  resp="$(ssx_http GET "$SSX_API_EM_V1/plan_regions?account=$(ssx_urlenc "$SSX_ACCOUNT")")" \
    || die "Failed to list regions"

  # plan_regions is messy across accounts/tiers — it can come back as:
  #   [ {id, region_served} ]                 (flat)
  #   {"data"|"results": [...]}               (enveloped flat)
  #   [ {name, regions: [ {id, region_served}, ... ]} ]   (plan-wrapped)
  #   {"plan_name": [ {id, region_served}, ... ]}         (plan-keyed)
  # Handle all of them; if we still can't make sense of it, dump the raw
  # JSON to stderr so we can share it and tune the parser.
  local table
  table="$(python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    sys.stderr.write("plan_regions: not JSON: {}\n".format(e))
    sys.stderr.write("Raw (first 2000 chars):\n{}\n".format(raw[:2000]))
    sys.exit(0)

def unwrap_to_list(obj):
    """Drill down envelopes to reach the top-level list of plans/regions."""
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        for k in ("data", "results", "plan_regions", "regions", "items"):
            v = obj.get(k)
            if isinstance(v, list):
                return v
        # Plan-keyed dict: {"Premier Plus": [{...regions...}]} → flatten values.
        flat = []
        any_list = False
        for v in obj.values():
            if isinstance(v, list):
                flat.extend(v)
                any_list = True
        if any_list:
            return flat
    return None

lst = unwrap_to_list(d)
if lst is None:
    sys.stderr.write("plan_regions: could not find a list. Raw response:\n")
    sys.stderr.write(json.dumps(d, indent=2)[:2000] + "\n")
    sys.exit(0)

def flatten_plans(lst):
    """The top-level is a list of subscription plans; the actual regions are
    nested inside each plan. Find the nested list in each plan (by name or by
    looking for any list-of-dicts field), flatten, and prefix labels with the
    plan name."""
    out = []
    for item in lst:
        if not isinstance(item, dict):
            continue
        nested = None
        # Try canonical nested-region key names first.
        for k in ("regions", "regions_served", "plan_regions",
                  "available_regions", "supported_regions", "data"):
            v = item.get(k)
            if isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
                nested = v
                break
        # Broader fallback: any list-of-dicts field within the plan entry.
        if nested is None:
            for k, v in item.items():
                if isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
                    nested = v
                    break
        if nested is not None:
            plan_label = (item.get("plan_name") or item.get("name")
                          or item.get("label") or item.get("id") or "")
            for sub in nested:
                s = dict(sub) if isinstance(sub, dict) else {}
                s.setdefault("_plan_label", str(plan_label))
                out.append(s)
        else:
            # Not plan-wrapped after all — keep as-is.
            out.append(item)
    return out

regions = flatten_plans(lst)

suspicious = 0
emitted = 0
for r in regions:
    if not isinstance(r, dict):
        continue
    rid = r.get("id")
    label = (r.get("region_served") or r.get("region") or r.get("name")
             or r.get("label") or r.get("region_name") or r.get("display_name") or "")
    plan = r.get("_plan_label", "")
    if plan and label:
        label = "{} — {}".format(plan, label)
    elif plan and not label:
        label = plan
    if rid is None or rid == "" or not label:
        suspicious += 1
    print("{}\t{}".format(rid if rid is not None else "", label))
    emitted += 1

if emitted == 0 or suspicious == emitted:
    sys.stderr.write("plan_regions: the response does not look like what we expect.\n")
    sys.stderr.write("Raw response so we can tune the parser:\n")
    sys.stderr.write(raw[:3000] + "\n")' <<<"$resp")"

  local -a ids=() labels=()
  while IFS=$'\t' read -r id label; do
    [[ -z "$id" ]] && continue
    ids+=("$id"); labels+=("$label")
  done <<<"$table"

  if ((${#ids[@]} == 0)); then
    die "No regions returned for account '$SSX_ACCOUNT'"
  fi
  log_info "Choose a region:"
  local i
  for ((i=0; i<${#ids[@]}; i++)); do
    log_dim "  [$((i+1))] id=${ids[$i]}  ${labels[$i]}"
  done
  local pick
  while true; do
    read -r -p "Region number [1-${#ids[@]}]: " pick </dev/tty
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
      SSX_REGION_ID="${ids[$((pick-1))]}"
      log_ok "Region: id=$SSX_REGION_ID (${labels[$((pick-1))]})"
      return 0
    fi
    echo "Enter a number 1..${#ids[@]}"
  done
}

# URL-encode a string via python3.
ssx_urlenc() {
  python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# POST /experience-manager/v2/apps — create one app by name.
# Sets $ssx_last_app_id on success.
ssx_create_one_app() {
  local name="$1"
  local body
  body="$(ssx_json_build "name=s=$name|default=b=$SSX_APP_DEFAULT|environment=s=$SSX_ENV|plan_region_id=i=$SSX_REGION_ID|platform_version_id=i=$SSX_PLATFORM_VERSION_ID|uid=s=$SSX_DEPLOYMENT_UID|api_password=s=$SSX_API_PASSWORD|engine_password=s=$SSX_ENGINE_PASSWORD")"

  local url="$SSX_API_EM_V2/apps?account=$(ssx_urlenc "$SSX_ACCOUNT")"

  if [[ "$SSX_DRY_RUN" == "1" ]]; then
    log_dim "dry-run: POST $url"
    log_dim "         body: $body"
    return 0
  fi

  log_info "Creating app '$name'"
  local resp
  if ! resp="$(ssx_http POST "$url" "$body")"; then
    log_err "Failed to create app '$name'"
    return 1
  fi
  # Extract the created app id for reporting
  local app_id
  app_id="$(ssx_json_pick '$.data.id' "$resp" 2>/dev/null || \
             ssx_json_pick '$.id' "$resp" 2>/dev/null || true)"
  if [[ -n "$app_id" ]]; then
    log_ok "Created app '$name' (id=$app_id)"
  else
    log_ok "Created app '$name'"
  fi
  return 0
}

# --- main ------------------------------------------------------------------

if [[ "$SSX_LOGOUT" == "1" ]]; then
  ssx_session_clear
  exit 0
fi

log_step "SearchStax app creation (account: ${SSX_ACCOUNT:-?})"
[[ "$SSX_DRY_RUN" == "1" ]] && log_warn "DRY-RUN mode: no API POST will be sent."

ssx_login
ssx_pick_account
ssx_pick_environment
ssx_pick_region

if [[ -n "$SSX_PLATFORM_VERSION_ID" ]]; then
  log_dim "Platform version id: $SSX_PLATFORM_VERSION_ID (pre-set)"
else
  log_dim "Platform version id: not set — server will use its default (override with --platform-version-id=<id>)"
fi

# Collect app names if none were given on the command line.
if ((${#SSX_APP_NAMES[@]} == 0)); then
  if [[ "$SSX_YES" == "1" ]]; then
    die "--yes mode but no app names provided. Pass them as positional args."
  fi
  log_info "Enter app names, one per line. Press Enter on an empty line to finish."
  while true; do
    read -r -p "  App name ($((${#SSX_APP_NAMES[@]}+1))): " name </dev/tty
    [[ -z "$name" ]] && break
    SSX_APP_NAMES+=("$name")
  done
fi

if ((${#SSX_APP_NAMES[@]} == 0)); then
  log_warn "No app names to create — exiting."
  exit 0
fi

# Client-side validation. Note: the SearchStudio SPA's yup schema is wrong —
# it allows hyphens and dots, but the SERVER rejects those with "App name
# must be 6–126 characters in length, consisting only of letters, numbers,
# or underscores." We enforce the stricter server rule here, and suggest
# a corrected name so the operator can paste-and-retry without guessing.
ssx_validate_name() {
  local n="$1"
  local len=${#n}
  if (( len < 6 || len > 126 )); then
    log_err "Invalid name '$n': must be 6..126 characters (got $len)"
    return 1
  fi
  if ! [[ "$n" =~ ^[a-zA-Z0-9_]+$ ]]; then
    local suggested
    suggested="$(printf '%s' "$n" | tr -c 'A-Za-z0-9_' '_')"
    log_err "Invalid name '$n': server accepts only letters, numbers, and underscores."
    log_dim "  Suggested: $suggested"
    return 1
  fi
  return 0
}

log_step "Review"
log_info "About to create ${#SSX_APP_NAMES[@]} app(s) on account '$SSX_ACCOUNT':"
for n in "${SSX_APP_NAMES[@]}"; do
  if ssx_validate_name "$n"; then
    log_dim "  • $n  (env: $SSX_ENV, region: $SSX_REGION_ID)"
  fi
done

confirm_or_exit "Proceed?" "n"

ok=0
fail=0
skipped=0
for n in "${SSX_APP_NAMES[@]}"; do
  if ! ssx_validate_name "$n"; then
    ((skipped++)) || true
    continue
  fi
  if ssx_create_one_app "$n"; then
    ((ok++)) || true
  else
    ((fail++)) || true
  fi
done

log_step "Summary"
log_ok "Created: $ok"
[[ $fail -gt 0 ]]    && log_err  "Failed:  $fail"
[[ $skipped -gt 0 ]] && log_warn "Skipped: $skipped (invalid names)"
exit $(( fail > 0 ? 1 : 0 ))
