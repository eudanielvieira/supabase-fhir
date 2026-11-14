# HTTP API

Everything in supabase-fhir is reachable over plain HTTP through PostgREST, the API layer
Supabase runs in front of Postgres. No SDK is required: any language with an HTTP client works.
The TypeScript client in `packages/typescript/` and the Go and Python examples in `examples/` are
thin wrappers around the calls on this page.

All examples assume:

```bash
export SUPABASE_URL=http://127.0.0.1:54321          # printed by `bun run db:start`
export SUPABASE_ANON_KEY=...                         # same place, or Project Settings > API
```

## 1. Sign in and get a JWT

Supabase Auth (GoTrue) issues the token. The password grant is the simplest for scripts;
apps normally use the Supabase auth client for their platform.

```bash
JWT=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
  -d '{"email":"clinician@example.com","password":"supabase-fhir"}' | jq -r .access_token)
```

Every request below sends two headers: `apikey` (the anon key) and `Authorization: Bearer $JWT`.
The database decides what the token may see; the API only forwards the identity.

## 2. Headers that select the fhir schema

PostgREST serves the `public` schema by default. Point it at `fhir`:

| Verb | Header |
|---|---|
| `GET`, `HEAD` | `Accept-Profile: fhir` |
| `POST`, `PATCH`, `DELETE`, RPC calls | `Content-Profile: fhir` |

Forgetting the header gives `404 relation not found` or `404 function not found`.

## 3. FHIR operations (RPC)

`POST $SUPABASE_URL/rest/v1/rpc/<function>` with a JSON body holding the named arguments.
Scalars come back as a bare JSON value; set-returning functions come back as a JSON array.

| Function | Body | Returns |
|---|---|---|
| `read_resource` | `{"resource_type":"Patient","id":"..."}` | the resource. Logs a read in `fhir.audit_log` |
| `search_resources` | `{"resource_type":"Observation","patient_id":"...","filters":{"code":"8302-2"},"max_results":50,"skip":0,"newest_first":true}` (all but `resource_type` optional) | an array of resources matching the filters (equality on the table's scalar columns). Logs one search event with the filters and the result count |
| `log_access` | `{"resource_type":"Patient","resource_id":"..."}` | empty body. Records a read you made through the table API; the database checks you may see the row first, so entries cannot be fabricated |
| `create_resource` | `{"resource":{...}}` | the stored resource with `id` and `meta` |
| `update_resource` | `{"resource":{...},"expected_version":3}` (`expected_version` optional) | the stored resource |
| `delete_resource` | `{"resource_type":"Observation","id":"..."}` | empty body |
| `history` | `{"resource_type":"Patient","id":"..."}` | `[{version_id, resource, last_updated, operation}]`, newest first |
| `patient_everything` | `{"patient_id":"..."}` | a `searchset` Bundle with the compartment the caller may see |
| `import_bundle` | `{"bundle":{"resourceType":"Bundle",...}}` | a `transaction-response` Bundle, one entry per input entry |
| `has_patient_access` | `{"patient_id":"...","level":"write"}` | `true` or `false` |
| `is_admin` | `{}` | `true` or `false` |

```bash
rpc() { curl -s -w '\n%{http_code}\n' "$SUPABASE_URL/rest/v1/rpc/$1" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $JWT" \
  -H "Content-Profile: fhir" -H "Content-Type: application/json" -d "$2"; }

rpc read_resource '{"resource_type":"Patient","id":"e34fa1e8-0cbc-0d22-89d4-6996de874bd8"}'
rpc patient_everything '{"patient_id":"e34fa1e8-0cbc-0d22-89d4-6996de874bd8"}'
rpc create_resource '{"resource":{"resourceType":"Observation","status":"final",
  "code":{"coding":[{"system":"http://loinc.org","code":"8302-2"}]},
  "subject":{"reference":"Patient/e34fa1e8-0cbc-0d22-89d4-6996de874bd8"},
  "valueQuantity":{"value":171,"unit":"cm"}}}'
rpc update_resource '{"resource":{...full resource with id...},"expected_version":1}'
rpc import_bundle "{\"bundle\":$(cat bundle.json)}"
```

## 4. Tables (search)

Every resource type is a table with the full resource in `resource` plus generated search
columns (`fhir.observation.code`, `effective_at`, `patient_id`, ...). PostgREST turns query
parameters into SQL, and row level security filters the rows.

```bash
get() { curl -s "$SUPABASE_URL/rest/v1/$1" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $JWT" -H "Accept-Profile: fhir"; }

# the patients this user may see
get 'patient?select=id,family_name,birth_date&order=family_name'

# blood pressure for one patient, newest first
get 'observation?patient_id=eq.<patient id>&code=eq.85354-9&select=resource&order=effective_at.desc&limit=20'

# active conditions
get 'condition?patient_id=eq.<patient id>&clinical_status=eq.active&select=resource'

# anything else: JSONB containment, GIN indexed
get 'patient?resource=cs.{"identifier":[{"system":"http://hl7.org/fhir/sid/us-ssn"}]}&select=id'
```

Writing straight to a table also works (`POST /rest/v1/observation` with `{"resource":{...}}`
and `Prefer: return=representation`); the triggers fill `id` and `meta`. Reads through tables
are not written to the audit log; reads through `read_resource`, `patient_everything` and
`search_resources` are, and `log_access` records a table read after the fact. Prefer
`search_resources` when the access must be traceable; prefer the table API for ad hoc filters
(`gte`, `lte`, `in`, JSONB containment) that the RPC does not expose.

Table names: `patient`, `practitioner`, `practitioner_role`, `organization`, `location`,
`medication`, `encounter`, `condition`, `observation`, `procedure`, `medication_request`,
`medication_administration`, `immunization`, `allergy_intolerance`, `diagnostic_report`,
`document_reference`, `care_plan`, `care_team`, `goal`, `device`, `imaging_study`,
`supply_delivery`, `coverage`, `claim`, `explanation_of_benefit`, `provenance`, plus
`patient_access`, `audit_log`, `resource_history` and `resource_type`.

## 5. Errors

Errors are JSON with the shape PostgREST uses, and the `details` field carries a FHIR
`OperationOutcome` as a string, so any FHIR library can parse it:

```json
{
  "code": "PT404",
  "message": "Patient/missing not found",
  "details": "{\"resourceType\": \"OperationOutcome\", \"issue\": [{\"code\": \"not-found\", \"severity\": \"error\", \"diagnostics\": \"Patient/missing not found\"}]}",
  "hint": null
}
```

| HTTP | `code` | Issue code | When |
|---|---|---|---|
| 400 | `PT400` | `invalid`, `structure`, `required`, `not-supported` | malformed input, unknown resource type |
| 400 | `23514`, `22023` | | a check constraint (wrong `resourceType`, bad id) |
| 403 | `42501` | `forbidden` | the row is visible but not writable, or RLS refused an insert |
| 404 | `PT404` | `not-found` | missing, or not visible to this user (no enumeration) |
| 409 | `PT409` | `conflict` | `expected_version` is stale |
| 401 | | | no or invalid JWT (`anon` has no access to the schema at all) |

## 6. Service role (backend jobs)

The service role key bypasses row level security. Use it server side only, for seeding,
migrations of data and administrative jobs. Send it in both headers:

```bash
curl -s "$SUPABASE_URL/rest/v1/rpc/import_bundle" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Profile: fhir" -H "Content-Type: application/json" \
  -d "{\"bundle\":$(cat synthea-patient.json)}"
```

Writes made with the service role are audited with `actor_role = service_role` and no `actor_id`.

## 7. OpenAPI

PostgREST describes the schema as OpenAPI 2.0, including every RPC and table, so you can
generate a client for your language instead of writing one:

```bash
curl -s "$SUPABASE_URL/rest/v1/" -H "apikey: $SUPABASE_ANON_KEY" -H "Accept-Profile: fhir" > fhir-openapi.json
npx @openapitools/openapi-generator-cli generate -i fhir-openapi.json -g go -o ./fhirclient
```

The `resource` column is typed as JSON in that document; pair the generated client with the
FHIR model library of your language for the resource bodies.

## 8. Direct SQL (no HTTP)

Backends that connect straight to Postgres get the same guarantees by assuming the user
before querying. With pgx, psycopg, JDBC or anything else:

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"<auth.users.id>","role":"authenticated","app_metadata":{"fhir_role":"admin"}}', true);
select fhir.read_resource('Patient', '<id>');
commit;
```

Connect as the service role (or as the owner) to bypass RLS. On a Postgres that is not
Supabase, run `sql/compat/plain-postgres.sql` first; it provides the roles and the `auth`
helpers the policies rely on.
