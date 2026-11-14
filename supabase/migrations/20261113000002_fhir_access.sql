-- =============================================================================
-- supabase-fhir | 0002 access model
-- Who can see which Patient compartment.
--
--   * admins       -> JWT app_metadata.fhir_role = 'admin' (set server side, never by the user)
--   * everyone else -> explicit rows in fhir.patient_access (read or write, optionally time-boxed)
--   * service_role -> bypasses RLS (backend jobs, seeding)
--   * anon         -> no access at all
-- =============================================================================

create table fhir.patient_access (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  patient_id   text not null,
  access_level text not null default 'read'
               constraint patient_access_level check (access_level in ('read', 'write')),
  valid_from   timestamptz not null default now(),
  valid_until  timestamptz
               constraint patient_access_validity check (valid_until is null or valid_until > valid_from),
  granted_by   uuid default auth.uid(),
  reason       text,
  created_at   timestamptz not null default now(),
  constraint patient_access_unique unique (user_id, patient_id)
);
comment on table fhir.patient_access is
  'Grants a user read or write access to one Patient compartment. A patient portal user gets a row for their own Patient; a clinician gets one per patient in their care.';
create index patient_access_patient_idx on fhir.patient_access (patient_id);

-- True when the JWT carries app_metadata.fhir_role = 'admin'.
create or replace function fhir.is_admin()
returns boolean
language sql stable parallel safe
set search_path = ''
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'fhir_role') = 'admin', false);
$$;

-- Patient ids the current user may read (level = 'read') or write (level = 'write').
-- SECURITY DEFINER so policies do not recurse into patient_access RLS.
create or replace function fhir.accessible_patients(level text default 'read')
returns setof text
language sql stable security definer
set search_path = ''
as $$
  select a.patient_id
  from fhir.patient_access a
  where a.user_id = (select auth.uid())
    and a.valid_from <= now()
    and (a.valid_until is null or a.valid_until > now())
    and (level = 'read' or a.access_level = 'write');
$$;

-- Convenience predicate for custom policies and application checks.
create or replace function fhir.has_patient_access(patient_id text, level text default 'read')
returns boolean
language sql stable
set search_path = ''
as $$
  select fhir.is_admin() or $1 in (select fhir.accessible_patients($2));
$$;

revoke execute on function fhir.accessible_patients(text) from public, anon;
grant execute on function
  fhir.is_admin(),
  fhir.accessible_patients(text),
  fhir.has_patient_access(text, text)
to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Policies
-- -----------------------------------------------------------------------------
alter table fhir.patient_access enable row level security;

create policy "users read their own grants" on fhir.patient_access
  for select to authenticated
  using (user_id = (select auth.uid()) or (select fhir.is_admin()));

create policy "admins manage grants" on fhir.patient_access
  for all to authenticated
  using ((select fhir.is_admin()))
  with check ((select fhir.is_admin()));

grant select, insert, update, delete on fhir.patient_access to authenticated, service_role;

create policy "history visible within compartment" on fhir.resource_history
  for select to authenticated
  using ((select fhir.is_admin()) or patient_id in (select fhir.accessible_patients('read')));

create policy "audit log visible to admins" on fhir.audit_log
  for select to authenticated
  using ((select fhir.is_admin()));

-- -----------------------------------------------------------------------------
-- Every change to a grant is itself audited: who had access to whom, and when.
-- -----------------------------------------------------------------------------
create or replace function fhir.audit_access_change()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    insert into fhir.audit_log (action, resource_type, resource_id, patient_id, actor_id, actor_role, request)
    values ('revoke', 'PatientAccess', old.id::text, old.patient_id, auth.uid(), fhir.actor_role(),
            fhir.request_context() || jsonb_build_object('before', to_jsonb(old)));
  elsif tg_op = 'UPDATE' then
    insert into fhir.audit_log (action, resource_type, resource_id, patient_id, actor_id, actor_role, request)
    values ('grant_change', 'PatientAccess', new.id::text, new.patient_id, auth.uid(), fhir.actor_role(),
            fhir.request_context() || jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new)));
  else
    insert into fhir.audit_log (action, resource_type, resource_id, patient_id, actor_id, actor_role, request)
    values ('grant', 'PatientAccess', new.id::text, new.patient_id, auth.uid(), fhir.actor_role(),
            fhir.request_context() || jsonb_build_object('after', to_jsonb(new)));
  end if;
  return null;
end;
$$;

create trigger fhir_audit_access_change
  after insert or update or delete on fhir.patient_access
  for each row execute function fhir.audit_access_change();
