# Use cases

The map the project was built from. Ids are stable and referenced from commits and docs.
Priority uses MoSCoW (Must, Should, Could, Won't now). Milestones: MVP (first release),
v0.1 (usable from any language), v1 (next), later.

## Core idea

An open source FHIR R4 starter for Supabase, and for plain Postgres: schema, patient-compartment
row level security, audit log, version history and an HTTP contract any language can use, so a
healthcare startup does not rebuild the foundation. Synthetic data only (Synthea).

## Milestones

- **MVP**: `supabase start` loads Synthea data; a client reads through RLS with auditing on; tests pass in CI.
  UC-001 to UC-024.
- **v0.1, any language**: the database plus HTTP is the product; clients are adapters.
  UC-034 to UC-040.
- **v1 and later**: UC-025 to UC-033.

## Map

| UC | Name | Actor | Theme | Priority | Milestone | Status |
|---|---|---|---|---|---|---|
| UC-001 | Provision the FHIR schema with migrations | Developer | Schema | Must | MVP | done |
| UC-002 | Store FHIR R4 resources as JSONB with search columns | Developer | Schema | Must | MVP | done |
| UC-003 | Register a new resource type with one call | Developer | Schema | Must | MVP | done |
| UC-004 | Version resources and read their history | Developer | Versioning | Must | MVP | done |
| UC-005 | Audit create, update and delete automatically | Compliance | Audit | Must | MVP | done |
| UC-006 | Audit reads through the RPC | Compliance | Audit | Should | MVP | done |
| UC-007 | A patient reads only their own compartment | Patient | Access (RLS) | Must | MVP | done |
| UC-008 | A clinician reaches the patients they were granted | Clinician | Access (RLS) | Must | MVP | done |
| UC-009 | An admin manages access grants | Admin | Access (RLS) | Must | MVP | done |
| UC-010 | Grants with validity and expiry | Admin | Access (RLS) | Should | MVP | done |
| UC-011 | Block anonymous access to the whole schema | System | Access (RLS) | Must | MVP | done |
| UC-012 | Import a Bundle with reference resolution | Developer | Import | Must | MVP | done |
| UC-013 | Seed Synthea patients on `supabase db reset` | Developer | Import | Must | MVP | done |
| UC-014 | Load a Synthea directory into a local or hosted project | Developer | Import | Should | MVP | done |
| UC-015 | Typed TypeScript client (CRUD, history, import) | Developer | SDK | Must | MVP | done |
| UC-016 | Table types for supabase-js with `resource` typed per table | Developer | SDK | Must | MVP | done |
| UC-017 | Optimistic concurrency (expected version on update) | Developer | Versioning | Should | MVP | done |
| UC-018 | Patient `$everything` | Developer | API | Could | v1 | done |
| UC-019 | pgTAP tests for RLS, triggers and import | Developer / CI | Quality | Must | MVP | done |
| UC-020 | CI running migrations and tests | System | Quality | Must | MVP | done |
| UC-021 | Expose the `fhir` schema on the local and hosted API | Developer | Operations | Must | MVP | done |
| UC-022 | Search on common parameters through generated columns | Developer | Search | Should | MVP | done |
| UC-023 | Reject invalid resources (wrong type, mutable id) | System | Edge cases | Must | MVP | done |
| UC-024 | Usage documentation and integration examples | Developer | Docs | Must | MVP | done |
| UC-025 | A patient sees who accessed their data | Patient | Audit | Could | v1 | idea |
| UC-026 | Soft delete and restore | Developer | Versioning | Could | v1 | idea |
| UC-027 | Multi-tenant by organization | Admin | Access (RLS) | Could | v1 | idea |
| UC-028 | Full FHIR REST facade (Edge Function or service) | Developer | API | Could | v1 | idea |
| UC-029 | Audit log retention and export | Compliance | Audit | Could | v1 | idea |
| UC-030 | Realtime on resource changes | Developer | Integrations | Could | later | idea |
| UC-031 | Profile validation (US Core) on write | Developer | Quality | Won't now | later | idea |
| UC-032 | SMART on FHIR / OAuth scopes | Developer | Access (RLS) | Won't now | later | idea |
| UC-033 | Bulk export (`$export` NDJSON) | Developer | Integrations | Won't now | later | idea |
| UC-034 | Language-neutral HTTP contract documented | Developer | API | Must | v0.1 | done |
| UC-035 | Client examples in Go, Python, PHP, Java, C# and Ruby | Developer | SDK | Should | v0.1 | done |
| UC-036 | API errors as FHIR OperationOutcome | Developer | API | Should | v0.1 | done |
| UC-037 | Run on plain Postgres (compatibility layer) | Developer | Operations | Should | v0.1 | done |
| UC-038 | HTTP conformance suite in CI | Developer / CI | Quality | Should | v0.1 | done |
| UC-039 | Single-file SQL distribution | Developer | Operations | Should | v0.1 | done |
| UC-040 | Example backends (NestJS, Elysia) forwarding the user JWT | Developer | SDK | Should | v0.1 | done |

## Details

One line each: who, what they want, why it matters.

- **UC-001** Developer wants the `fhir` schema ready after `supabase db reset`; zero manual setup, same locally and hosted.
- **UC-002** Developer wants the whole resource kept with full fidelity and still filterable in SQL; one table per type, `resource jsonb`, generated `patient_id` and search columns.
- **UC-003** Developer wants `Device` or `Coverage` without copying SQL; `fhir.define_resource()` creates table, indexes, triggers, RLS and grants so the security pattern never lags.
- **UC-004** Developer wants to know what a resource looked like at each version; a trigger copies the prior version to `fhir.resource_history`, `fhir.history()` returns the timeline.
- **UC-005** Compliance wants a trail of who did what, when, on which patient; an after trigger writes to `fhir.audit_log` with actor, role, action, resource and request metadata.
- **UC-006** Compliance wants PHI reads recorded; `fhir.read_resource()` returns the resource and logs a `read`, covering what select triggers cannot.
- **UC-007** Patient wants their data and nothing else; RLS compares the row's `patient_id` with the grants of `auth.uid()`.
- **UC-008** Clinician wants to read and write the patients under their care; rows in `fhir.patient_access` with level `read` or `write`.
- **UC-009** Admin wants to grant and revoke; `app_metadata.fhir_role = 'admin'` manages `patient_access` and every resource without the service role on the client.
- **UC-010** Admin wants temporary access (on call, one visit); `valid_from` and `valid_until` are evaluated by the policies.
- **UC-011** System must have no public route to PHI; `anon` has no usage on the schema and no execute on functions.
- **UC-012** Developer wants to load transaction or batch bundles (Synthea, EHRs); `fhir.import_bundle()` resolves `urn:uuid` and conditional references and upserts by id.
- **UC-013** Developer wants realistic data in the first minute; SQL seeds with synthetic patients, providers and demo users.
- **UC-014** Developer wants N patients in any project; `bun run seed:synthea --dir` calls the RPC with the service role.
- **UC-015** Developer wants FHIR in the app without hand-written queries; `createFhirClient()` with read, create, update, remove, history, search, everything, importBundle.
- **UC-016** Developer wants `supabase.schema('fhir').from('observation')` to return `fhir4.Observation`; a `Database` type mapped over `@types/fhir`.
- **UC-017** Developer must not overwrite a concurrent edit; `update_resource(resource, expected_version)` fails with 409 when the version moved.
- **UC-018** Developer wants a whole compartment at once; `fhir.patient_everything()` returns a Bundle under RLS.
- **UC-019** Developer wants proof that isolation holds; `supabase test db` runs patient, clinician, admin and anonymous scenarios.
- **UC-020** Every pull request validates SQL and TypeScript; the workflow starts the database, runs pgTAP, unit tests and typecheck.
- **UC-021** Developer wants the tables on PostgREST; `config.toml` and the dashboard instructions add `fhir` to the exposed schemas.
- **UC-022** Developer wants to filter by code, date, status, encounter; generated, indexed columns per type.
- **UC-023** System must never store structural garbage; checks on `resourceType`, id format, immutable id and `resource.id` in sync.
- **UC-024** Developer wants to start in five minutes; README with quickstart, access model, API, seeding and deployment.
- **UC-034** Developer wants to integrate from any language without an SDK; `docs/api.md` with headers, every RPC in curl, table search, errors, OpenAPI and direct SQL.
- **UC-035** Developer wants the full flow in their language on one screen; one file per language under `examples/`, standard library (Java adds Jackson), compiled or linted in CI.
- **UC-036** Developer wants to handle errors with the FHIR library they already use; `fhir.fail()` raises with an HTTP-mapped SQLSTATE and an OperationOutcome in `details`.
- **UC-037** Developer wants the schema outside Supabase; `sql/compat/plain-postgres.sql` creates the roles and `auth` helpers, PostgREST or per-transaction claims do the rest.
- **UC-038** CI must prove every client sees the same behaviour; `tests/http/conformance.sh` (curl and jq) exercises RLS, errors, import and OpenAPI through PostgREST.
- **UC-039** Developer wants to apply the schema with any migration tool; `bun run sql:build` concatenates the migrations into `sql/dist/`, CI fails when stale.
- **UC-040** Developer wants their own API in front of the database without reimplementing access; `examples/nestjs` and `examples/elysia` build the client per request from the user's `Authorization` header.

## Out of scope for now

- UC-031 profile validation needs a validation engine.
- UC-032 SMART on FHIR: Supabase Auth covers patient and clinician apps for now; SMART scopes come later.
- UC-033 bulk export depends on storage and asynchronous jobs.
- UC-027 multi-tenant: the compartment model covers the MVP; organization becomes an extra dimension in v1.
- UC-028 FHIR REST facade: next milestone (v1), lets off-the-shelf FHIR SDKs work without knowing PostgREST.
