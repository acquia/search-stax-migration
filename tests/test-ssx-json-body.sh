#!/usr/bin/env bash
# tests/test-ssx-json-body.sh
#
# Pins the SearchStax create-app request body shape (POST
# /experience-manager/v2/apps). Per tdd-rules: define the API contract
# FIRST, and let the test fail loudly if anyone changes the body shape
# without coordinating with whatever the SearchStudio SPA expects.
#
# Copyright 2026 Mohammad Zomorodian, Acquia Inc. (Apache-2.0)

set -euo pipefail

cd "$(dirname "$0")/.."

# Source the API module in isolation. It needs STATE_DIR + a few logging
# helpers, so stub those minimally.
STATE_DIR=/tmp
DRY_RUN=0
info() { :; }
warn() { :; }
err()  { printf 'ERR: %s\n' "$*" >&2; exit 1; }
ok()   { :; }
dim()  { :; }
audit(){ :; }

# shellcheck source=../lib/searchstax_api.sh
source ./lib/searchstax_api.sh

SSX_ENV="Development"
SSX_REGION_ID=42
SSX_APP_DEFAULT="false"

body="$(ssx_build_create_body "acme_client01_dev")"

# Required keys.
for key in name default environment plan_region_id; do
    if ! jq -e "has(\"$key\")" <<<"$body" >/dev/null; then
        echo "FAIL: body missing required key '$key'"
        echo "  body: $body"
        exit 1
    fi
done

# Value + type assertions.
[[ "$(jq -r '.name'           <<<"$body")" == "acme_client01_dev" ]] || { echo "FAIL: name"; exit 1; }
[[ "$(jq -r '.environment'    <<<"$body")" == "Development" ]]       || { echo "FAIL: environment"; exit 1; }
[[ "$(jq -r '.plan_region_id' <<<"$body")" == "42" ]]                || { echo "FAIL: plan_region_id"; exit 1; }
[[ "$(jq -r '.default'        <<<"$body")" == "false" ]]             || { echo "FAIL: default"; exit 1; }

# Type assertions: plan_region_id must be a JSON number, default a JSON bool.
[[ "$(jq -r '.plan_region_id | type' <<<"$body")" == "number"  ]] || { echo "FAIL: plan_region_id must be a number"; exit 1; }
[[ "$(jq -r '.default        | type' <<<"$body")" == "boolean" ]] || { echo "FAIL: default must be a boolean"; exit 1; }
[[ "$(jq -r '.name           | type' <<<"$body")" == "string"  ]] || { echo "FAIL: name must be a string"; exit 1; }

# Name validation: server-rule sanity.
ssx_validate_name "acme_client01_dev" || { echo "FAIL: valid name rejected"; exit 1; }
! ssx_validate_name "too-short"        2>/dev/null  || { echo "FAIL: hyphen accepted (server rejects)"; exit 1; }
! ssx_validate_name "short"            2>/dev/null  || { echo "FAIL: <6 chars accepted"; exit 1; }
! ssx_validate_name "has spaces here"  2>/dev/null  || { echo "FAIL: spaces accepted"; exit 1; }

# Optional fields must be OMITTED when their env vars are empty (the server
# applies its own defaults; we don't want to send empty strings).
for key in platform_version_id uid api_password engine_password; do
    if jq -e "has(\"$key\")" <<<"$body" >/dev/null; then
        echo "FAIL: optional key '$key' should be omitted when env is empty"
        echo "  body: $body"
        exit 1
    fi
done

# When the env vars ARE set (parity with create_apps.sh's --platform-version-id,
# --deployment-uid, --api-password, --engine-password flags), they MUST appear
# in the body with the right types.
SSX_PLATFORM_VERSION_ID=7
SSX_DEPLOYMENT_UID="dep-abc-123"
SSX_API_PASSWORD="api-secret"
SSX_ENGINE_PASSWORD="engine-secret"
body2="$(ssx_build_create_body "acme_client01_dev")"

[[ "$(jq -r '.platform_version_id'        <<<"$body2")" == "7"             ]] || { echo "FAIL: platform_version_id value"; exit 1; }
[[ "$(jq -r '.platform_version_id | type' <<<"$body2")" == "number"        ]] || { echo "FAIL: platform_version_id must be a number"; exit 1; }
[[ "$(jq -r '.uid'                        <<<"$body2")" == "dep-abc-123"   ]] || { echo "FAIL: uid value"; exit 1; }
[[ "$(jq -r '.api_password'               <<<"$body2")" == "api-secret"    ]] || { echo "FAIL: api_password value"; exit 1; }
[[ "$(jq -r '.engine_password'            <<<"$body2")" == "engine-secret" ]] || { echo "FAIL: engine_password value"; exit 1; }

echo "  ssx-json-body OK"
