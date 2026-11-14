# Architecture decision records

Short records of the choices that are hard to reverse. Newest at the bottom.

## ADR-001 Postgres first; clients are adapters

**Context.** Access rules, auditing and versioning are the hard part of a FHIR store. Putting them
in an application layer means every client, in every language, must reimplement them correctly.

**Decision.** Everything that matters lives in Postgres: tables, row level security, triggers and
RPC functions. The public contract is HTTP through PostgREST plus direct SQL. The TypeScript client
and the examples are thin adapters and carry no rules.

**Consequences.** Any language works and gets the same guarantees. The price is that behaviour
must be tested at the database (pgTAP) and at the HTTP edge (conformance suite), and that the
SQL is the thing to read when something is unclear.

## ADR-002 One table per resource type, JSONB plus generated search columns

**Context.** Options were a single `resource` table, a fully relational mapping per type, or one
JSONB table per type.

**Decision.** One table per resource type with the full resource in `resource jsonb`, a generated
`patient_id` and generated search columns for the common search parameters, all created by
`fhir.define_resource()`.

**Consequences.** Full FHIR fidelity, natural PostgREST URLs (`/rest/v1/observation`), RLS and
indexes per type, and a new type costs one SQL call. Searches beyond the generated columns use
JSONB containment with a GIN index, which is good enough for most and can be extended per type.

## ADR-003 The Patient compartment is the unit of access

**Context.** Healthcare access control is about which patients a user may see, far more than about
which tables.

**Decision.** Every patient-scoped row carries a generated `patient_id`. Grants are rows in
`fhir.patient_access` (read or write, optionally time-boxed). Admins are identified by
`app_metadata.fhir_role = 'admin'` in the JWT, which users cannot edit. Reference data is readable
by any signed-in user and writable by admins. Anonymous has no access to the schema at all.
Deleting a Patient is admin only: it cascades to the grants and would orphan the whole
compartment, so a write grant must not be enough.

**Consequences.** One policy template covers every resource type. Rows without a patient are
admin-only by default (fail closed). Multi-tenancy by organization is a later layer, not a
replacement.

## ADR-004 Audit by triggers for writes and grants, by RPC for reads and searches, identifiers only

**Context.** Postgres has no select triggers, audit rows must never become a second copy of PHI,
and anything that can write the log must not be usable to forge it.

**Decision.** `fhir_audit_write` records create, update and delete on every resource table;
`fhir_audit_access_change` records every grant, change and revoke in `patient_access`. Reads are
recorded when they go through `read_resource()`, `patient_everything()` or `search_resources()`
(one event per search, with filters and result count), which the clients use. The log writers
(`log_access`, `log_search`) are SECURITY DEFINER but revalidate access themselves: they look the
row up and apply the same rules as the policies before inserting, answering 404 otherwise. The log
stores identifiers, actor, role and request metadata, never the payload. Only admins read it.

**Consequences.** Writes and grant changes cannot bypass the log; read entries cannot be
fabricated for data the caller cannot see. Plain table reads are not audited unless the client
calls `log_access` afterwards; documented as a known limit, with `search_resources` as the
audited alternative. Rate limiting of log writes is left to the API gateway, as it is for reads.

## ADR-005 History as superseded versions in one table

**Decision.** `fhir_record_history` copies the previous version to `fhir.resource_history` on
update and delete. `fhir.history()` unions the current row with history, newest first.

**Consequences.** Point-in-time reads and FHIR `_history` without touching the main tables.
Deleted resources keep their last version. Storage grows with edits, which is the intended trade.

## ADR-006 FHIR ids as text, UUID by default

**Decision.** `id` is `text` constrained to the FHIR id pattern, defaulting to a UUID. A client
supplied `resource.id` is kept; ids are immutable and mirrored into `resource.id`.

**Consequences.** Ids from other systems (EHRs, Synthea) round-trip unchanged. Uniqueness is per
table, as in FHIR.

## ADR-007 Errors through fhir.fail() with PostgREST status codes and an OperationOutcome

**Decision.** API functions raise with SQLSTATE `PT400`, `PT404`, `PT409` or `42501`, which
PostgREST maps to HTTP 400, 404, 409 and 403, and attach a FHIR `OperationOutcome` in the error
detail. Not found and not allowed both answer 404.

**Consequences.** Any FHIR library parses failures without custom code; ids cannot be enumerated
through error differences; the TypeScript client exposes the outcome on `FhirError`.

## ADR-008 Synthetic data only

**Decision.** Seeds and fixtures come from Synthea or are hand written. Demo users exist only in
the local seeds. The README states that no real patient data will ever be in the repository.

**Consequences.** The project can be forked, demoed and tested without any compliance exposure.
Loading real data is a deliberate act by the adopter, outside this repository.

## ADR-009 Backends forward the user JWT

**Context.** A backend in front of the database is tempted to use the service role key and
reimplement access checks.

**Decision.** The example backends (NestJS, Elysia) build the Supabase client per request from
the caller's `Authorization` header, so RLS runs as the end user. The service role is for seeding
and administrative jobs only.

**Consequences.** One set of rules, enforced in one place. Backends stay thin and cannot leak
more than the user could fetch directly.

## ADR-010 Tests are the contract, at three levels

**Decision.** pgTAP tests define the behaviour at the database (RLS, triggers, import, API), a
curl-based contract suite checks the same guarantees through PostgREST (the contract of this
starter, not FHIR REST conformance), and every example in `examples/` is run against the live
stack. CI runs all of it on every push, plus typecheck and unit tests.

**Consequences.** A change that weakens a policy fails CI before review. Contributors add a test
with every behaviour change; see CONTRIBUTING.md.
