-- =============================================================================
-- supabase-fhir | 0003 define_resource
-- One call creates everything a resource type needs:
--
--   select fhir.define_resource('Device');            -- patient-scoped (default)
--   select fhir.define_resource('Organization', false); -- reference data, readable by all users
--
-- Table layout (fhir.<snake_case_type>):
--   id            FHIR id (text, uuid by default)
--   version_id    increments on every update
--   last_updated  stamped on every write
--   resource      the full FHIR JSON
--   patient_id    generated: the Patient compartment this row belongs to
--   created_at / created_by / updated_by
-- Plus indexes, triggers (versioning, history, audit), RLS policies and grants.
-- Idempotent: safe to re-run to refresh triggers and policies.
-- =============================================================================

create or replace function fhir.define_resource(p_resource_type text, p_compartment boolean default true)
returns text
language plpgsql
set search_path = ''
set client_min_messages to warning
as $fn$
declare
  tbl text;
  pol text;
begin
  if p_resource_type !~ '^[A-Z][A-Za-z]{1,63}$' then
    raise exception 'invalid FHIR resource type: %', p_resource_type using errcode = '22023';
  end if;
  tbl := fhir.table_name(p_resource_type);

  execute format($sql$
    create table if not exists fhir.%1$I (
      id            text primary key default gen_random_uuid()::text
                    constraint %3$I check (id ~ '^[A-Za-z0-9\-\.]{1,64}$'),
      version_id    integer not null default 1,
      last_updated  timestamptz not null default now(),
      resource      jsonb not null
                    constraint %4$I check (resource ->> 'resourceType' = %2$L),
      patient_id    text generated always as (fhir.compartment_patient_id(resource)) stored,
      created_at    timestamptz not null default now(),
      created_by    uuid,
      updated_by    uuid,
      constraint %5$I check (resource ->> 'id' = id)
    )$sql$,
    tbl, p_resource_type, tbl || '_id_format', tbl || '_resource_type', tbl || '_id_sync');

  execute format('comment on table fhir.%I is %L', tbl, 'FHIR ' || p_resource_type || ' resources');

  execute format('create index if not exists %I on fhir.%I (patient_id)', tbl || '_patient_id_idx', tbl);
  execute format('create index if not exists %I on fhir.%I (last_updated desc)', tbl || '_last_updated_idx', tbl);
  execute format('create index if not exists %I on fhir.%I using gin (resource jsonb_path_ops)', tbl || '_resource_idx', tbl);

  execute format('drop trigger if exists fhir_before_write on fhir.%I', tbl);
  execute format('create trigger fhir_before_write before insert or update on fhir.%I for each row execute function fhir.before_write()', tbl);
  execute format('drop trigger if exists fhir_record_history on fhir.%I', tbl);
  execute format('create trigger fhir_record_history after update or delete on fhir.%I for each row execute function fhir.record_history()', tbl);
  execute format('drop trigger if exists fhir_audit_write on fhir.%I', tbl);
  execute format('create trigger fhir_audit_write after insert or update or delete on fhir.%I for each row execute function fhir.audit_write()', tbl);

  execute format('alter table fhir.%I enable row level security', tbl);
  foreach pol in array array['fhir_select', 'fhir_insert', 'fhir_update', 'fhir_delete'] loop
    execute format('drop policy if exists %I on fhir.%I', pol, tbl);
  end loop;

  if p_compartment then
    execute format($sql$
      create policy fhir_select on fhir.%I for select to authenticated
        using (fhir.is_admin() or patient_id in (select fhir.accessible_patients('read')))$sql$, tbl);
    execute format($sql$
      create policy fhir_insert on fhir.%I for insert to authenticated
        with check (fhir.is_admin() or patient_id in (select fhir.accessible_patients('write')))$sql$, tbl);
    execute format($sql$
      create policy fhir_update on fhir.%I for update to authenticated
        using (fhir.is_admin() or patient_id in (select fhir.accessible_patients('write')))
        with check (fhir.is_admin() or patient_id in (select fhir.accessible_patients('write')))$sql$, tbl);
    execute format($sql$
      create policy fhir_delete on fhir.%I for delete to authenticated
        using (fhir.is_admin() or patient_id in (select fhir.accessible_patients('write')))$sql$, tbl);
  else
    execute format($sql$
      create policy fhir_select on fhir.%I for select to authenticated using (true)$sql$, tbl);
    execute format($sql$
      create policy fhir_insert on fhir.%I for insert to authenticated with check (fhir.is_admin())$sql$, tbl);
    execute format($sql$
      create policy fhir_update on fhir.%I for update to authenticated
        using (fhir.is_admin()) with check (fhir.is_admin())$sql$, tbl);
    execute format($sql$
      create policy fhir_delete on fhir.%I for delete to authenticated using (fhir.is_admin())$sql$, tbl);
  end if;

  execute format('grant select, insert, update, delete on fhir.%I to authenticated, service_role', tbl);

  insert into fhir.resource_type (resource_type, table_name, compartment)
  values (p_resource_type, tbl, p_compartment)
  on conflict (resource_type) do update set compartment = excluded.compartment;

  return tbl;
end;
$fn$;

revoke execute on function fhir.define_resource(text, boolean) from public;
