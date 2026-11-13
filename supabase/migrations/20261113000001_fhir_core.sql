-- =============================================================================
-- supabase-fhir | 0001 core
-- Schema, helper functions, resource type registry, version history,
-- audit log and the trigger functions shared by every resource table.
-- =============================================================================

create schema if not exists fhir;
comment on schema fhir is
  'FHIR R4 resources stored as JSONB with patient-compartment RLS, version history and audit log.';

-- Fail closed: anonymous clients never see this schema.
revoke all on schema fhir from public;
grant usage on schema fhir to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Helper functions
-- All of them are IMMUTABLE so they can back generated columns and indexes.
-- -----------------------------------------------------------------------------

-- 'MedicationRequest' -> 'medication_request'
create or replace function fhir.table_name(resource_type text)
returns text
language sql immutable strict parallel safe
set search_path = ''
as $$
  select lower(regexp_replace(resource_type, '([a-z0-9])([A-Z])', '\1_\2', 'g'));
$$;

-- fhir.reference_id('Patient/123', 'Patient') -> '123'
-- Accepts relative references, absolute URLs and versioned references.
-- Returns null for urn:uuid, conditional and foreign-type references.
create or replace function fhir.reference_id(reference text, resource_type text)
returns text
language sql immutable strict parallel safe
set search_path = ''
as $$
  select (regexp_match(
    reference,
    '(?:^|/)' || resource_type || '/([A-Za-z0-9\-\.]{1,64})(?:/_history/[^/]+)?$'
  ))[1];
$$;

-- The Patient compartment a resource belongs to, or null for resources that
-- are not about a single patient (Practitioner, Organization, ...).
create or replace function fhir.compartment_patient_id(resource jsonb)
returns text
language sql immutable strict parallel safe
set search_path = ''
as $$
  select case
    when resource ->> 'resourceType' = 'Patient' then resource ->> 'id'
    else coalesce(
      fhir.reference_id(resource #>> '{subject,reference}', 'Patient'),
      fhir.reference_id(resource #>> '{patient,reference}', 'Patient'),
      fhir.reference_id(resource #>> '{beneficiary,reference}', 'Patient'),
      (
        select fhir.reference_id(t ->> 'reference', 'Patient')
        from jsonb_array_elements(
          case when jsonb_typeof(resource -> 'target') = 'array'
               then resource -> 'target' else '[]'::jsonb end
        ) as t
        where fhir.reference_id(t ->> 'reference', 'Patient') is not null
        limit 1
      )
    )
  end;
$$;

-- FHIR dateTime/instant (including partial '2024' and '2024-03') -> timestamptz.
-- Interprets zone-less values as UTC. Returns null when unparsable.
create or replace function fhir.parse_datetime(value text)
returns timestamptz
language plpgsql immutable strict parallel safe
set search_path = ''
set timezone to 'UTC'
set datestyle to 'ISO, YMD'
as $$
begin
  return case
    when value ~ '^\d{4}$' then (value || '-01-01')::timestamptz
    when value ~ '^\d{4}-\d{2}$' then (value || '-01')::timestamptz
    else value::timestamptz
  end;
exception when others then
  return null;
end;
$$;

-- FHIR date (including partial values) -> date. Returns null when unparsable.
create or replace function fhir.parse_date(value text)
returns date
language plpgsql immutable strict parallel safe
set search_path = ''
set datestyle to 'ISO, YMD'
as $$
begin
  return case
    when value ~ '^\d{4}$' then (value || '-01-01')::date
    when value ~ '^\d{4}-\d{2}$' then (value || '-01')::date
    else left(value, 10)::date
  end;
exception when others then
  return null;
end;
$$;

-- timestamptz -> FHIR instant string in UTC ('2026-01-31T12:00:00.000Z')
create or replace function fhir.instant(value timestamptz)
returns text
language sql stable strict parallel safe
set search_path = ''
as $$
  select to_char(value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

-- Role of the caller as seen by PostgREST ('authenticated', 'service_role', ...)
-- or the database role when called outside the API (migrations, psql, tests).
create or replace function fhir.actor_role()
returns text
language sql stable parallel safe
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    current_user::text
  );
$$;

-- Request metadata PostgREST exposes as settings. Empty outside the API.
create or replace function fhir.request_context()
returns jsonb
language plpgsql stable parallel safe
set search_path = ''
as $$
declare
  headers jsonb;
begin
  begin
    headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    headers := null;
  end;
  return jsonb_strip_nulls(jsonb_build_object(
    'method', nullif(current_setting('request.method', true), ''),
    'path', nullif(current_setting('request.path', true), ''),
    'ip', headers ->> 'x-forwarded-for',
    'user_agent', headers ->> 'user-agent'
  ));
end;
$$;

grant execute on function
  fhir.table_name(text),
  fhir.reference_id(text, text),
  fhir.compartment_patient_id(jsonb),
  fhir.parse_datetime(text),
  fhir.parse_date(text),
  fhir.instant(timestamptz),
  fhir.actor_role(),
  fhir.request_context()
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Registry of resource types that have a table (filled by fhir.define_resource)
-- -----------------------------------------------------------------------------
create table fhir.resource_type (
  resource_type text primary key
    constraint resource_type_format check (resource_type ~ '^[A-Z][A-Za-z]{1,63}$'),
  table_name    text not null unique,
  compartment   boolean not null default true,
  created_at    timestamptz not null default now()
);
comment on table fhir.resource_type is
  'Resource types with a backing table. compartment=true means rows are scoped to a Patient.';

alter table fhir.resource_type enable row level security;
create policy "resource types are readable" on fhir.resource_type
  for select to authenticated using (true);
grant select on fhir.resource_type to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Version history: every superseded or deleted version of every resource
-- -----------------------------------------------------------------------------
create table fhir.resource_history (
  history_id    bigint generated always as identity primary key,
  resource_type text not null,
  id            text not null,
  version_id    integer not null,
  resource      jsonb not null,
  patient_id    text,
  last_updated  timestamptz not null,
  updated_by    uuid,
  operation     text not null constraint resource_history_operation check (operation in ('update', 'delete')),
  recorded_at   timestamptz not null default now()
);
comment on table fhir.resource_history is
  'Prior versions of resources. operation=update means superseded, delete means removed.';
create index resource_history_resource_idx on fhir.resource_history (resource_type, id, version_id desc);
create index resource_history_patient_idx on fhir.resource_history (patient_id);

alter table fhir.resource_history enable row level security;
grant select on fhir.resource_history to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Audit log: who did what to which resource (no PHI payload, only identifiers)
-- -----------------------------------------------------------------------------
create table fhir.audit_log (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  action        text not null constraint audit_log_action check (action in ('create', 'read', 'update', 'delete')),
  resource_type text not null,
  resource_id   text not null,
  patient_id    text,
  version_id    integer,
  actor_id      uuid,
  actor_role    text,
  request       jsonb
);
comment on table fhir.audit_log is
  'Access trail. Writes are recorded by triggers; reads through fhir.read_resource and fhir.patient_everything.';
create index audit_log_patient_idx on fhir.audit_log (patient_id, occurred_at desc);
create index audit_log_resource_idx on fhir.audit_log (resource_type, resource_id);
create index audit_log_actor_idx on fhir.audit_log (actor_id, occurred_at desc);

alter table fhir.audit_log enable row level security;
grant select on fhir.audit_log to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Trigger functions shared by every resource table
-- -----------------------------------------------------------------------------

-- Keeps id, version and meta in sync and stamps the actor.
create or replace function fhir.before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  now_ts timestamptz := now();
  actor  uuid := auth.uid();
  meta   jsonb;
begin
  if new.resource is null or jsonb_typeof(new.resource) <> 'object' then
    raise exception 'resource must be a JSON object' using errcode = '22023';
  end if;

  if tg_op = 'INSERT' then
    new.id := coalesce(nullif(new.resource ->> 'id', ''), new.id, gen_random_uuid()::text);
    new.version_id := 1;
    new.created_at := now_ts;
    new.created_by := actor;
  else
    if new.id is distinct from old.id then
      raise exception 'resource id is immutable (% -> %)', old.id, new.id using errcode = '23514';
    end if;
    if nullif(new.resource ->> 'id', '') is not null and new.resource ->> 'id' <> old.id then
      raise exception 'resource.id % does not match row id %', new.resource ->> 'id', old.id using errcode = '23514';
    end if;
    new.version_id := old.version_id + 1;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;

  new.last_updated := now_ts;
  new.updated_by := actor;
  meta := coalesce(new.resource -> 'meta', '{}'::jsonb)
       || jsonb_build_object('versionId', new.version_id::text, 'lastUpdated', fhir.instant(now_ts));
  new.resource := new.resource || jsonb_build_object('id', new.id, 'meta', meta);
  return new;
end;
$$;

-- Copies the superseded (or deleted) version into fhir.resource_history.
create or replace function fhir.record_history()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into fhir.resource_history
    (resource_type, id, version_id, resource, patient_id, last_updated, updated_by, operation)
  values
    (old.resource ->> 'resourceType', old.id, old.version_id, old.resource, old.patient_id,
     old.last_updated, old.updated_by, lower(tg_op));
  return null;
end;
$$;

-- Appends a create/update/delete event to fhir.audit_log.
create or replace function fhir.audit_write()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  act text := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' else 'delete' end;
begin
  if tg_op = 'DELETE' then
    insert into fhir.audit_log
      (action, resource_type, resource_id, patient_id, version_id, actor_id, actor_role, request)
    values
      (act, old.resource ->> 'resourceType', old.id, old.patient_id, old.version_id,
       auth.uid(), fhir.actor_role(), fhir.request_context());
  else
    insert into fhir.audit_log
      (action, resource_type, resource_id, patient_id, version_id, actor_id, actor_role, request)
    values
      (act, new.resource ->> 'resourceType', new.id, new.patient_id, new.version_id,
       auth.uid(), fhir.actor_role(), fhir.request_context());
  end if;
  return null;
end;
$$;

-- Records a read event. Called by the audited read RPCs.
create or replace function fhir.log_access(
  resource_type text,
  resource_id text,
  patient_id text,
  version_id integer
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into fhir.audit_log
    (action, resource_type, resource_id, patient_id, version_id, actor_id, actor_role, request)
  values
    ('read', resource_type, resource_id, patient_id, version_id,
     auth.uid(), fhir.actor_role(), fhir.request_context());
end;
$$;

revoke execute on function fhir.log_access(text, text, text, integer) from public, anon;
grant execute on function fhir.log_access(text, text, text, integer) to authenticated, service_role;
