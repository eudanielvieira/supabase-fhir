#!/usr/bin/env bash
# Runs every example against the running local stack and checks it completes the demo flow:
# login, list patients, audited read, search, and a 404 carrying an OperationOutcome.
#
#   SUPABASE_ANON_KEY=... bash tests/http/examples.sh
# Needs: bun, go, python3, php, ruby, mvn (Java 17+), dotnet, curl, jq.
set -uo pipefail

: "${SUPABASE_URL:=http://127.0.0.1:54321}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY (see: supabase status)}"
export SUPABASE_URL SUPABASE_ANON_KEY

pass=0
fail=0

run() { # name command...
  local name=$1
  shift
  local out
  if out=$("$@" 2>&1) && grep -q "patients visible to this user" <<<"$out" && grep -q "expected failure" <<<"$out"; then
    pass=$((pass + 1)); echo "ok - $name"
  else
    fail=$((fail + 1)); echo "not ok - $name"; echo "$out" | tail -20 | sed 's/^/    /'
  fi
}

run go      bash -c 'cd examples/go && go run .'
run python  python3 examples/python/example.py
run php     php examples/php/example.php
run ruby    ruby examples/ruby/example.rb
run java    mvn -q -B -f examples/java/pom.xml compile exec:java
run csharp  dotnet run --project examples/csharp -c Release --nologo -v q

JWT=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
  -d '{"email":"clinician@example.com","password":"supabase-fhir"}' | jq -r '.access_token // empty')

serve() { # name port command...
  local name=$1 port=$2
  shift 2
  local log body status pid
  log=$(mktemp); body=$(mktemp)
  PORT=$port "$@" >"$log" 2>&1 &
  pid=$!
  status=$(curl -s -o "$body" -w '%{http_code}' --retry 30 --retry-connrefused --retry-delay 1 \
    "http://127.0.0.1:$port/patients" -H "Authorization: Bearer $JWT")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$status" = "200" ] && [ "$(jq 'length' "$body" 2>/dev/null)" = "4" ]; then
    pass=$((pass + 1)); echo "ok - $name serves /patients with the user's JWT"
  else
    fail=$((fail + 1)); echo "not ok - $name (HTTP $status)"; tail -20 "$log" | sed 's/^/    /'; sed 's/^/    /' "$body"
  fi
  rm -f "$log" "$body"
}

serve nestjs 3301 bash -c 'cd examples/nestjs && bun run src/main.ts'
serve elysia 3302 bash -c 'cd examples/elysia && bun run src/index.ts'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
