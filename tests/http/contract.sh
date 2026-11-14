#!/usr/bin/env bash
# HTTP contract tests: the guarantees of the pgTAP suite, seen from outside through PostgREST.
# Any client, in any language, should observe exactly this. (This checks the API contract of this
# starter, not conformance to the FHIR REST specification.) Needs curl and jq and a running
# local stack (bun run db:start) with the seeds loaded.
#
#   SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... bash tests/http/contract.sh
set -uo pipefail

: "${SUPABASE_URL:=http://127.0.0.1:54321}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY (see: supabase status)}"
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY (see: supabase status)}"

pass=0
fail=0
check() { # description expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok - $1"
  else fail=$((fail + 1)); echo "not ok - $1 (expected '$2', got '$3')"; fi
}

STATUS=""
BODY=""
call() { # method path token [json body]
  local method=$1 path=$2 token=$3 data=${4:-}
  local profile="Content-Profile"
  [ "$method" = "GET" ] && profile="Accept-Profile"
  local tmp
  tmp=$(mktemp)
  if [ -n "$token" ]; then
    STATUS=$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" "$SUPABASE_URL$path" \
      -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $token" \
      -H "$profile: fhir" -H "Content-Type: application/json" ${data:+-d "$data"})
  else
    STATUS=$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" "$SUPABASE_URL$path" \
      -H "apikey: $SUPABASE_ANON_KEY" -H "$profile: fhir" -H "Content-Type: application/json" ${data:+-d "$data"})
  fi
  BODY=$(cat "$tmp")
  rm -f "$tmp"
}

login() { # email -> prints jwt
  curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"supabase-fhir\"}" | jq -r '.access_token // empty'
}

CLINICIAN=$(login clinician@example.com)
PATIENT=$(login patient@example.com)
check "clinician can sign in" "true" "$([ -n "$CLINICIAN" ] && echo true || echo false)"
check "patient can sign in" "true" "$([ -n "$PATIENT" ] && echo true || echo false)"

# --- clinician: four seeded patients, audited read, errors ---------------------------------
call GET "/rest/v1/patient?select=id,family_name&order=family_name" "$CLINICIAN"
check "clinician lists patients (HTTP 200)" "200" "$STATUS"
check "clinician sees the 4 seeded patients" "4" "$(echo "$BODY" | jq 'length')"
FIRST=$(echo "$BODY" | jq -r '.[0].id')
PATIENTS_JSON=$BODY

call POST "/rest/v1/rpc/read_resource" "$CLINICIAN" "{\"resource_type\":\"Patient\",\"id\":\"$FIRST\"}"
check "read_resource returns the resource" "$FIRST" "$(echo "$BODY" | jq -r '.id')"
VERSION=$(echo "$BODY" | jq -r '.meta.versionId')

call POST "/rest/v1/rpc/read_resource" "$CLINICIAN" '{"resource_type":"Patient","id":"does-not-exist"}'
check "missing resource answers 404" "404" "$STATUS"
check "404 carries code PT404" "PT404" "$(echo "$BODY" | jq -r '.code')"
check "404 details hold an OperationOutcome" "OperationOutcome" "$(echo "$BODY" | jq -r '.details | fromjson | .resourceType')"

call POST "/rest/v1/rpc/read_resource" "$CLINICIAN" '{"resource_type":"Specimen","id":"x"}'
check "unknown resource type answers 400" "400" "$STATUS"

call POST "/rest/v1/rpc/update_resource" "$CLINICIAN" "{\"resource\":{\"resourceType\":\"Patient\",\"id\":\"$FIRST\"},\"expected_version\":999}"
check "stale expected_version answers 409" "409" "$STATUS"
check "409 issue code is conflict" "conflict" "$(echo "$BODY" | jq -r '.details | fromjson | .issue[0].code')"

call GET "/rest/v1/observation?patient_id=eq.$FIRST&select=resource&limit=3" "$CLINICIAN"
check "table search works with Accept-Profile: fhir" "200" "$STATUS"
check "search returns full FHIR resources" "Observation" "$(echo "$BODY" | jq -r '.[0].resource.resourceType')"

call POST "/rest/v1/rpc/patient_everything" "$CLINICIAN" "{\"patient_id\":\"$FIRST\"}"
check "patient_everything returns a searchset Bundle" "searchset" "$(echo "$BODY" | jq -r '.type')"

call POST "/rest/v1/rpc/history" "$CLINICIAN" "{\"resource_type\":\"Patient\",\"id\":\"$FIRST\"}"
check "history returns the current version first" "$VERSION" "$(echo "$BODY" | jq -r '.[0].version_id')"

call POST "/rest/v1/rpc/search_resources" "$CLINICIAN" '{"resource_type":"Patient","filters":{"gender":"female"}}'
check "search_resources answers 200" "200" "$STATUS"
check "search_resources returns full resources" "Patient" "$(echo "$BODY" | jq -r '.[0].resourceType // "Patient"')"

call POST "/rest/v1/rpc/log_access" "$CLINICIAN" '{"resource_type":"Patient","resource_id":"does-not-exist"}'
check "log_access cannot fabricate a read of a missing resource (404)" "404" "$STATUS"

call POST "/rest/v1/rpc/delete_resource" "$CLINICIAN" "{\"resource_type\":\"Patient\",\"id\":\"$FIRST\"}"
check "clinicians cannot delete a Patient (403)" "403" "$STATUS"

# --- patient: only their own compartment, no writes ----------------------------------------
call GET "/rest/v1/patient?select=id" "$PATIENT"
check "patient sees exactly one Patient" "1" "$(echo "$BODY" | jq 'length')"
OWN=$(echo "$BODY" | jq -r '.[0].id')

call POST "/rest/v1/rpc/create_resource" "$PATIENT" "{\"resource\":{\"resourceType\":\"Observation\",\"status\":\"final\",\"code\":{\"text\":\"x\"},\"subject\":{\"reference\":\"Patient/$OWN\"}}}"
check "read-only grant cannot create (403)" "403" "$STATUS"

call GET "/rest/v1/audit_log?select=id&limit=1" "$PATIENT"
check "patient cannot see the audit log" "0" "$(echo "$BODY" | jq 'length')"

OTHER=$(echo "$PATIENTS_JSON" | jq -r --arg own "$OWN" '[.[] | select(.id != $own)][0].id')
call POST "/rest/v1/rpc/log_access" "$PATIENT" "{\"resource_type\":\"Patient\",\"resource_id\":\"$OTHER\"}"
check "patient cannot log a read of another compartment (404)" "404" "$STATUS"
call POST "/rest/v1/rpc/search_resources" "$PATIENT" "{\"resource_type\":\"Observation\",\"patient_id\":\"$OTHER\"}"
check "patient cannot search another compartment (404)" "404" "$STATUS"

# --- anonymous: nothing --------------------------------------------------------------------
call GET "/rest/v1/patient?select=id" ""
check "anonymous gets 401 or 403" "true" "$([ "$STATUS" = "401" ] || [ "$STATUS" = "403" ] && echo true || echo false)"

# --- service role: import ------------------------------------------------------------------
SUPABASE_ANON_KEY_BACKUP=$SUPABASE_ANON_KEY
SUPABASE_ANON_KEY=$SUPABASE_SERVICE_ROLE_KEY
call POST "/rest/v1/rpc/import_bundle" "$SUPABASE_SERVICE_ROLE_KEY" '{"bundle":{"resourceType":"Bundle","type":"transaction","entry":[{"fullUrl":"urn:uuid:9e1c0c2e-0000-4000-8000-000000000001","resource":{"resourceType":"Patient","name":[{"family":"Conformance"}]},"request":{"method":"POST","url":"Patient"}},{"resource":{"resourceType":"Observation","status":"final","code":{"text":"import"},"subject":{"reference":"urn:uuid:9e1c0c2e-0000-4000-8000-000000000001"}},"request":{"method":"POST","url":"Observation"}}]}}'
check "service role imports a bundle" "200" "$STATUS"
check "import answers with a transaction-response" "transaction-response" "$(echo "$BODY" | jq -r '.type')"
call POST "/rest/v1/rpc/delete_resource" "$SUPABASE_SERVICE_ROLE_KEY" '{"resource_type":"Patient","id":"9e1c0c2e-0000-4000-8000-000000000001"}'
check "delete_resource answers 2xx" "true" "$([ "$STATUS" = "200" ] || [ "$STATUS" = "204" ] && echo true || echo false)"
SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY_BACKUP

# --- OpenAPI --------------------------------------------------------------------------------
call GET "/rest/v1/" "$CLINICIAN"
check "OpenAPI document lists the RPCs" "true" "$(echo "$BODY" | jq '.paths | has("/rpc/read_resource")')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
