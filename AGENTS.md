# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Copilot, Codex and similar) working with
supabase-fhir: inside this repository, or when wiring it into another project. Humans should read
README.md; this is the short, operational version.

## What this is

A FHIR R4 starter for Supabase: SQL migrations (schema, row level security, audit log, version
history, RPC API) plus a small TypeScript client. It is a template to copy, not an npm package.

## Map

| Path | Role |
|---|---|
| `supabase/migrations/20261113000001_fhir_core.sql` | schema, helpers, registry, history, audit, shared triggers |
| `supabase/migrations/20261113000002_fhir_access.sql` | `patient_access`, `is_admin()`, `accessible_patients()`, policies for history and audit |
| `supabase/migrations/20261113000003_fhir_define_resource.sql` | `fhir.define_resource()`: creates a resource table with indexes, triggers, RLS and grants |
| `supabase/migrations/20261113000004_fhir_resources.sql` | the 26 shipped resource types and their generated search columns |
| `supabase/migrations/20261113000005_fhir_api.sql` | RPCs: `read_resource`, `create_resource`, `update_resource`, `delete_resource`, `history`, `patient_everything`, `import_bundle` |
| `supabase/tests/*.test.sql` | pgTAP suite, run with `supabase test db` |
| `supabase/seeds/*.sql` | generated from Synthea by `scripts/build-seed.ts`; never edit by hand |
| `src/domain/` | resource type map, reference parsing, errors; pure, no I/O |
| `src/application/ports.ts` | `FhirRepository` interface |
| `src/infrastructure/supabase/` | `Database` type for supabase-js and `createFhirClient()` |
| `scripts/` | Synthea loaders |
| `dxspec/backlog.md` | use cases `UC-NNN` for this project (in Portuguese) |

## Invariants: never break these

1. **Fail closed.** `anon` has no usage on the `fhir` schema and must never get any. Every new
   table gets `enable row level security` and explicit grants. Never grant anything to `anon`.
2. **Resource tables come from `fhir.define_resource()`.** Do not hand-create resource tables or
   policies; add columns with `alter table ... add column ... generated always as (...) stored`.
3. **Triggers stay on.** `fhir_before_write`, `fhir_record_history` and `fhir_audit_write` must
   remain on every resource table. Do not bypass them with `session_replication_role` or by
   writing to `audit_log` / `resource_history` directly.
4. **`SECURITY DEFINER` is for logging only.** RPCs that return PHI are `SECURITY INVOKER` so RLS
   applies. Any `SECURITY DEFINER` function sets `search_path = ''` and uses qualified names.
5. **Ids are immutable** and `resource.id` always equals the `id` column. The trigger enforces it.
6. **Synthetic data only.** Fixtures and seeds come from Synthea or are made up. No real PHI, not
   even anonymised.
7. **Migrations are append only.** Add a new timestamped file; never edit a published one.
8. **Three suites must pass before you are done:** `bun run typecheck`, `bun test`, `supabase test db`.

## Recipes

### Add a resource type

```sql
-- supabase/migrations/<timestamp>_add_specimen.sql
select fhir.define_resource('Specimen');                       -- patient-scoped
alter table fhir.specimen
  add column status text generated always as (resource ->> 'status') stored;
```

Then add `Specimen: 'specimen'` to `TABLE_NAMES` and `Specimen: r4.Specimen` to `ResourceMap` in
`src/domain/resource-types.ts`, update the count in `tests/domain/resource-types.test.ts` and in
`supabase/tests/001_schema.test.sql`, and add search columns to `SearchColumns` in
`src/infrastructure/supabase/database.types.ts` if you created any.

Reference data that is not about one patient (Organization, Medication, ...) uses
`fhir.define_resource('Type', false)`: readable by every signed-in user, writable by admins.

### Grant or revoke access

```sql
insert into fhir.patient_access (user_id, patient_id, access_level, valid_until, reason)
values ('<auth.users.id>', '<patient id>', 'write', null, 'care team');

update fhir.patient_access set valid_until = now() where user_id = '<id>' and patient_id = '<pid>';
```

Only admins and the service role can write `patient_access`. A typical app creates the patient's
own `read` row at signup from a server function or an `auth.users` trigger.

### Make an admin

Set `app_metadata.fhir_role = 'admin'` on the user (server side, Admin API or SQL on
`auth.users.raw_app_meta_data`). `user_metadata` is user editable and is ignored on purpose.

### Read and write from TypeScript

```ts
const fhir = createFhirClient(supabase);          // supabase = createClient<Database>(url, key)
await fhir.read('Patient', id);                   // audited, 404 when invisible
await fhir.create({ resourceType: 'Observation', status: 'final', code: {}, subject: { reference: `Patient/${id}` } });
await fhir.update(observation, { expectedVersion: 3 });   // 409 on a stale version
await fhir.search('Observation', { patientId: id, where: { code: '8302-2' }, limit: 50 });
await fhir.everything(id);                        // Bundle
await fhir.importBundle(bundle);                  // transaction or batch
fhir.from('Condition').select('resource').eq('clinical_status', 'active');   // raw typed builder
```

Errors are `FhirError` with `status` 400, 403, 404, 409 or 500.

### Query directly in SQL

```sql
select resource from fhir.observation
where patient_id = $1 and code = $2 and effective_at between $3 and $4;
```

Prefer generated search columns; fall back to `resource @> '{...}'` (GIN indexed).

### Load synthetic data

`bun run seed:synthea --dir <synthea output> --limit 20` with `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY`. Never point it at real exports.

## Integrating into another project

1. Copy `supabase/migrations/*_fhir_*.sql` keeping the order; run `supabase db push`.
2. Add `"fhir"` to `[api] schemas` in `supabase/config.toml` and to the exposed schemas of the hosted project.
3. Copy `src/` (or just `database.types.ts`) and build `type Database = AppDatabase & FhirDatabase`.
4. Wire `patient_access` rows into your signup or onboarding flow; set the admin claim for operators.
5. Do not copy `supabase/seeds/` or the demo users into anything but local development.

## Conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`), imperative, lower case.
  No AI attribution lines in commit messages or pull requests.
- No emojis in code, docs, tests or commits.
- English in code, SQL and docs. `dxspec/` is in Portuguese by design.
- SQL: lower case keywords, snake_case, functions with `set search_path = ''`, explicit grants and
  revokes, comments on tables and functions.
- TypeScript: strict, no `any`, named exports, Bun for scripts and tests, Clean Architecture layers
  (`domain` has no imports from `infrastructure`).

## Commands

```bash
bun install
bun run typecheck
bun test
bun run db:start       # supabase start: migrations + seeds (Docker)
bun run test:db        # pgTAP
bun run db:reset
bun run seed:build --dir data/synthea/fhir --patients 4
bun run seed:synthea --dir data/synthea/fhir --limit 20
```
