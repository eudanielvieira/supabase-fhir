-- =============================================================================
-- supabase-fhir | 0005 RPC API
-- FHIR-flavoured operations callable with supabase.schema('fhir').rpc(...).
-- All of them run as the caller (SECURITY INVOKER) so RLS always applies.
-- Errors go through fhir.fail(): PostgREST maps PT400, PT404, PT409 to HTTP 400/404/409
-- and 42501 to 403, and the response "details" carries a FHIR OperationOutcome.
-- =============================================================================

-- Table backing a resource type, or null when it was never defined.
create or replace function fhir.resource_table(resource_type text)
returns text
language sql stable parallel safe
set search_path = ''
as $$
  select t.table_name from fhir.resource_type t where t.resource_type = $1;
$$;

-- id of the resource of the given type carrying identifier 'system|value' (or just 'value').
create or replace function fhir.find_by_identifier(resource_type text, identifier text)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  tbl   text := fhir.resource_table(resource_type);
  token text := replace(identifier, '%7C', '|');
  sys   text;
  val   text;
  found text;
begin
  if tbl is null or token is null or token = '' then
    return null;
  end if;
  if position('|' in token) > 0 then
    sys := split_part(token, '|', 1);
    val := substr(token, position('|' in token) + 1);
  else
    val := token;
  end if;
  execute format('select id from fhir.%I where resource @> $1 limit 1', tbl)
    into found
    using jsonb_build_object('identifier', jsonb_build_array(
      jsonb_strip_nulls(jsonb_build_object('system', nullif(sys, ''), 'value', val))));
  return found;
end;
$$;

-- 'Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|123' -> 'Practitioner/<id>' or null.
create or replace function fhir.resolve_conditional_reference(reference text)
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  parts text[] := regexp_match(reference, '^([A-Z][A-Za-z]+)\?identifier=(.+)$');
  found text;
begin
  if parts is null then
    return null;
  end if;
  found := fhir.find_by_identifier(parts[1], parts[2]);
  return case when found is null then null else parts[1] || '/' || found end;
end;
$$;

-- -----------------------------------------------------------------------------
-- Audited access
-- The log writers are SECURITY DEFINER so they can append to fhir.audit_log, but they
-- never trust their arguments: log_access looks the row up and checks that the caller
-- may read it, log_search checks the patient scope. A client cannot fabricate entries
-- for data it cannot see. Calls with no JWT (migrations, psql, tests) or with the
-- service role are trusted, as they bypass RLS anyway.
-- -----------------------------------------------------------------------------
create or replace function fhir.trusted_caller()
returns boolean
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claims', true), '') is null
      or fhir.actor_role() = 'service_role';
$$;

-- Records a read of one resource. read_resource and patient_everything call it; clients that
-- read through the table API can call it themselves to record the access.
create or replace function fhir.log_access(resource_type text, resource_id text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  tbl            text;
  is_compartment boolean;
  found_patient  text;
  found_version  integer;
  allowed        boolean;
begin
  select t.table_name, t.compartment into tbl, is_compartment
  from fhir.resource_type t
  where t.resource_type = $1;
  if tbl is null then
    perform fhir.fail('PT404', 'not-found', format('%s/%s not found', resource_type, resource_id));
  end if;

  execute format('select patient_id, version_id from fhir.%I where id = $1', tbl)
    into found_patient, found_version
    using resource_id;

  allowed := found_version is not null and (
    fhir.trusted_caller()
    or (select fhir.is_admin())
    or not is_compartment
    or (found_patient is not null and found_patient in (select fhir.accessible_patients('read'))));
  if not allowed then
    perform fhir.fail('PT404', 'not-found', format('%s/%s not found', resource_type, resource_id));
  end if;

  insert into fhir.audit_log
    (action, resource_type, resource_id, patient_id, version_id, actor_id, actor_role, request)
  values
    ('read', resource_type, resource_id, found_patient, found_version,
     auth.uid(), fhir.actor_role(), fhir.request_context());
end;
$$;

-- Records a search: the type, the patient scope, the filters and how many rows came back.
create or replace function fhir.log_search(resource_type text, patient_id text, filters jsonb, results integer)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if patient_id is not null and not (
    fhir.trusted_caller()
    or (select fhir.is_admin())
    or patient_id in (select fhir.accessible_patients('read'))) then
    perform fhir.fail('PT404', 'not-found', format('Patient/%s not found', patient_id));
  end if;
  insert into fhir.audit_log
    (action, resource_type, resource_id, patient_id, actor_id, actor_role, request)
  values
    ('search', resource_type, null, patient_id, auth.uid(), fhir.actor_role(),
     fhir.request_context() || jsonb_build_object('filters', coalesce(filters, '{}'::jsonb), 'results', results));
end;
$$;

-- Audited search over one resource table. filters is an object of column = value pairs on the
-- table's scalar columns (the generated search columns included), for example
-- {"code": "8302-2", "status": "final"}; a null value means "is null".
create or replace function fhir.search_resources(
  resource_type text,
  patient_id text default null,
  filters jsonb default '{}'::jsonb,
  max_results integer default 100,
  skip integer default 0,
  newest_first boolean default true
)
returns setof jsonb
language plpgsql
set search_path = ''
as $$
declare
  tbl        text := fhir.resource_table(resource_type);
  conditions text[] := array['true'];
  args       jsonb := coalesce(filters, '{}'::jsonb);
  key        text;
  val        jsonb;
  col_type   text;
  found      integer;
begin
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', resource_type));
  end if;
  if jsonb_typeof(args) <> 'object' then
    perform fhir.fail('PT400', 'invalid', 'filters must be a JSON object of column = value pairs');
  end if;
  if max_results < 1 or max_results > 1000 then
    perform fhir.fail('PT400', 'invalid', 'max_results must be between 1 and 1000');
  end if;

  for key, val in select e.key, e.value from jsonb_each(args) e loop
    select c.data_type into col_type
    from information_schema.columns c
    where c.table_schema = 'fhir' and c.table_name = tbl and c.column_name = key and c.data_type <> 'jsonb';
    if col_type is null then
      perform fhir.fail('PT400', 'not-supported', format('%s has no search column %s', resource_type, key));
    end if;
    if jsonb_typeof(val) = 'null' then
      conditions := conditions || format('%I is null', key);
    else
      conditions := conditions || format('%I = (%L)::%s', key, val #>> '{}', col_type);
    end if;
  end loop;
  if patient_id is not null then
    conditions := conditions || format('patient_id = %L', patient_id);
  end if;

  return query execute format(
    'select resource from fhir.%I where %s order by last_updated %s, id limit %s offset %s',
    tbl, array_to_string(conditions, ' and '),
    case when newest_first then 'desc' else 'asc' end, max_results, greatest(coalesce(skip, 0), 0));
  get diagnostics found = row_count;
  perform fhir.log_search(resource_type, patient_id, args, found);
end;
$$;

-- -----------------------------------------------------------------------------
-- read / create / update / delete / history
-- -----------------------------------------------------------------------------

-- Audited read. Not found and not allowed both answer PT404 (no enumeration).
create or replace function fhir.read_resource(resource_type text, id text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  tbl             text := fhir.resource_table(resource_type);
  found_resource  jsonb;
  found_patient   text;
  found_version   integer;
begin
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', resource_type));
  end if;
  execute format('select resource, patient_id, version_id from fhir.%I where id = $1', tbl)
    into found_resource, found_patient, found_version
    using id;
  if found_resource is null then
    perform fhir.fail('PT404', 'not-found', format('%s/%s not found', resource_type, id));
  end if;
  perform fhir.log_access(resource_type, id);
  return found_resource;
end;
$$;

create or replace function fhir.create_resource(resource jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  rt      text := resource ->> 'resourceType';
  tbl     text;
  created jsonb;
begin
  if rt is null then
    perform fhir.fail('PT400', 'required', 'resource.resourceType is required');
  end if;
  tbl := fhir.resource_table(rt);
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', rt));
  end if;
  execute format('insert into fhir.%I (resource) values ($1) returning resource', tbl)
    into created
    using resource;
  return created;
end;
$$;

-- Full replace. Pass expected_version for optimistic locking (FHIR If-Match).
--   PT404 unknown or invisible, 42501 visible but not writable, PT409 stale version.
create or replace function fhir.update_resource(resource jsonb, expected_version integer default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  rt              text := resource ->> 'resourceType';
  rid             text := nullif(resource ->> 'id', '');
  tbl             text;
  updated         jsonb;
  current_version integer;
begin
  if rt is null or rid is null then
    perform fhir.fail('PT400', 'required', 'resource.resourceType and resource.id are required');
  end if;
  tbl := fhir.resource_table(rt);
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', rt));
  end if;

  if expected_version is null then
    execute format('update fhir.%I set resource = $1 where id = $2 returning resource', tbl)
      into updated using resource, rid;
  else
    execute format('update fhir.%I set resource = $1 where id = $2 and version_id = $3 returning resource', tbl)
      into updated using resource, rid, expected_version;
  end if;

  if updated is null then
    execute format('select version_id from fhir.%I where id = $1', tbl) into current_version using rid;
    if current_version is null then
      perform fhir.fail('PT404', 'not-found', format('%s/%s not found', rt, rid));
    elsif expected_version is not null and current_version <> expected_version then
      perform fhir.fail('PT409', 'conflict', format('version conflict on %s/%s: expected %s, current %s', rt, rid, expected_version, current_version));
    else
      perform fhir.fail('42501', 'forbidden', format('no write access to %s/%s', rt, rid));
    end if;
  end if;
  return updated;
end;
$$;

create or replace function fhir.delete_resource(resource_type text, id text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  tbl     text := fhir.resource_table(resource_type);
  deleted integer;
  visible boolean;
begin
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', resource_type));
  end if;
  execute format('delete from fhir.%I where id = $1', tbl) using id;
  get diagnostics deleted = row_count;
  if deleted = 0 then
    execute format('select exists (select 1 from fhir.%I where id = $1)', tbl) into visible using id;
    if visible then
      perform fhir.fail('42501', 'forbidden', format('no write access to %s/%s', resource_type, id));
    end if;
    perform fhir.fail('PT404', 'not-found', format('%s/%s not found', resource_type, id));
  end if;
end;
$$;

-- Every version of a resource, newest first. operation is 'current', 'update' or 'delete'.
create or replace function fhir.history(resource_type text, id text)
returns table (version_id integer, resource jsonb, last_updated timestamptz, operation text)
language plpgsql stable
set search_path = ''
as $$
declare
  tbl text := fhir.resource_table(resource_type);
begin
  if tbl is null then
    perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s', resource_type));
  end if;
  return query execute format($sql$
    select c.version_id, c.resource, c.last_updated, 'current'::text
    from fhir.%I c where c.id = $1
    union all
    select h.version_id, h.resource, h.last_updated, h.operation
    from fhir.resource_history h where h.resource_type = $2 and h.id = $1
    order by 1 desc$sql$, tbl)
    using id, resource_type;
end;
$$;

-- Patient $everything: a searchset Bundle with the whole compartment the caller may see.
create or replace function fhir.patient_everything(patient_id text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  patient  jsonb;
  entries  jsonb := '[]'::jsonb;
  chunk    jsonb;
  rt       record;
begin
  select p.resource into patient from fhir.patient p where p.id = $1;
  if patient is null then
    perform fhir.fail('PT404', 'not-found', format('Patient/%s not found', patient_id));
  end if;
  perform fhir.log_access('Patient', patient_id);

  for rt in select t.table_name from fhir.resource_type t where t.compartment order by t.resource_type loop
    execute format(
      'select coalesce(jsonb_agg(jsonb_build_object(''resource'', resource) order by last_updated), ''[]''::jsonb)
       from fhir.%I where patient_id = $1', rt.table_name)
      into chunk using patient_id;
    entries := entries || chunk;
  end loop;

  return jsonb_build_object(
    'resourceType', 'Bundle',
    'type', 'searchset',
    'total', jsonb_array_length(entries),
    'entry', entries
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- import_bundle: load a transaction/batch/collection Bundle atomically
--   * urn:uuid fullUrls become stable ids; references are rewritten to Type/id
--   * conditional references (Type?identifier=system|value) resolve to Type/id,
--     first against the bundle itself, then against the database
--   * request.ifNoneExist with an identifier reuses the existing resource
--   * entries are upserted by id, so re-importing the same bundle is safe
--   * request.method DELETE (url 'Type/id') removes the resource
-- Returns a transaction-response Bundle with one entry per input entry.
-- -----------------------------------------------------------------------------
create or replace function fhir.import_bundle(bundle jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  entries   jsonb;
  n         integer;
  ids       text[] := '{}';
  types     text[] := '{}';
  skip      boolean[] := '{}';
  ref_map   jsonb := '{}'::jsonb;
  i         integer;
  entry     jsonb;
  res       jsonb;
  rt        text;
  tbl       text;
  method    text;
  full_url  text;
  rid       text;
  cond      text;
  existing  text;
  ident     jsonb;
  txt       text;
  ref       text;
  resolved  text;
  version   integer;
  url_parts text[];
  responses jsonb := '[]'::jsonb;
begin
  if bundle ->> 'resourceType' is distinct from 'Bundle' then
    perform fhir.fail('PT400', 'invalid', format('expected a Bundle, got %s', coalesce(bundle ->> 'resourceType', 'nothing')));
  end if;
  entries := coalesce(bundle -> 'entry', '[]'::jsonb);
  if jsonb_typeof(entries) <> 'array' then
    perform fhir.fail('PT400', 'structure', 'Bundle.entry must be an array');
  end if;
  n := jsonb_array_length(entries);

  -- Pass 1: decide the id of every entry and map fullUrls / identifiers to Type/id.
  for i in 0 .. n - 1 loop
    entry := entries -> i;
    method := upper(coalesce(entry #>> '{request,method}', 'POST'));

    if method in ('GET', 'HEAD') then
      ids := ids || null::text; types := types || null::text; skip := skip || true;
      continue;
    end if;

    if method = 'DELETE' then
      url_parts := regexp_match(coalesce(entry #>> '{request,url}', ''), '^([A-Z][A-Za-z]+)/([A-Za-z0-9\-\.]{1,64})$');
      if url_parts is null or fhir.resource_table(url_parts[1]) is null then
        perform fhir.fail('PT400', 'invalid', format('entry %s: DELETE needs request.url like Type/id with a known type', i));
      end if;
      ids := ids || url_parts[2]; types := types || url_parts[1]; skip := skip || false;
      continue;
    end if;

    res := entry -> 'resource';
    if res is null or jsonb_typeof(res) <> 'object' then
      perform fhir.fail('PT400', 'structure', format('entry %s has no resource', i));
    end if;
    rt := res ->> 'resourceType';
    tbl := fhir.resource_table(rt);
    if tbl is null then
      perform fhir.fail('PT400', 'not-supported', format('unknown resource type %s at entry %s (define it with fhir.define_resource)', rt, i));
    end if;

    full_url := entry ->> 'fullUrl';
    rid := nullif(res ->> 'id', '');
    existing := null;
    cond := entry #>> '{request,ifNoneExist}';
    if method = 'POST' and cond like 'identifier=%' then
      existing := fhir.find_by_identifier(rt, substr(cond, 12));
    end if;
    if existing is not null then
      rid := existing;
    elsif rid is null then
      rid := case when full_url like 'urn:uuid:%' then substr(full_url, 10) else gen_random_uuid()::text end;
    end if;

    ids := ids || rid; types := types || rt; skip := skip || (existing is not null);

    if full_url is not null then
      ref_map := ref_map || jsonb_build_object(full_url, rt || '/' || rid);
    end if;
    if jsonb_typeof(res -> 'identifier') = 'array' then
      for ident in select * from jsonb_array_elements(res -> 'identifier') loop
        if ident ->> 'value' is not null then
          ref_map := ref_map
            || jsonb_build_object(rt || '?identifier=' || coalesce(ident ->> 'system', '') || '|' || (ident ->> 'value'), rt || '/' || rid)
            || jsonb_build_object(rt || '?identifier=' || (ident ->> 'value'), rt || '/' || rid);
        end if;
      end loop;
    end if;
  end loop;

  -- Pass 2: rewrite references and write.
  for i in 0 .. n - 1 loop
    entry := entries -> i;
    rid := ids[i + 1];
    rt := types[i + 1];
    method := upper(coalesce(entry #>> '{request,method}', 'POST'));

    if skip[i + 1] then
      responses := responses || jsonb_build_object('response', jsonb_strip_nulls(jsonb_build_object(
        'status', '200 OK',
        'location', case when rid is null then null else rt || '/' || rid end)));
      continue;
    end if;

    tbl := fhir.resource_table(rt);

    if method = 'DELETE' then
      execute format('delete from fhir.%I where id = $1', tbl) using rid;
      responses := responses || jsonb_build_object('response', jsonb_build_object('status', '204 No Content'));
      continue;
    end if;

    txt := ((entry -> 'resource') || jsonb_build_object('id', rid))::text;
    -- Only reference values are rewritten: jsonb text output is canonical ("reference": "..."),
    -- so an identifier.value that happens to equal a fullUrl is left alone.
    for ref in select distinct m[1] from regexp_matches(txt, '"reference": "(urn:uuid:[0-9A-Fa-f-]{36})"', 'g') as m loop
      if ref_map ? ref then
        txt := replace(txt, '"reference": "' || ref || '"', '"reference": "' || (ref_map ->> ref) || '"');
      end if;
    end loop;
    for ref in select distinct m[1] from regexp_matches(txt, '"reference": "([A-Z][A-Za-z]+\?identifier=[^"]+)"', 'g') as m loop
      resolved := coalesce(ref_map ->> replace(ref, '%7C', '|'), fhir.resolve_conditional_reference(ref));
      if resolved is not null then
        txt := replace(txt, '"reference": "' || ref || '"', '"reference": "' || resolved || '"');
      end if;
    end loop;
    res := txt::jsonb;

    execute format(
      'insert into fhir.%I (resource) values ($1)
       on conflict (id) do update set resource = excluded.resource
       returning version_id', tbl)
      into version using res;

    responses := responses || jsonb_build_object('response', jsonb_build_object(
      'status', case when version = 1 then '201 Created' else '200 OK' end,
      'location', rt || '/' || rid || '/_history/' || version,
      'etag', 'W/"' || version || '"'));
  end loop;

  return jsonb_build_object(
    'resourceType', 'Bundle',
    'type', case when bundle ->> 'type' = 'batch' then 'batch-response' else 'transaction-response' end,
    'entry', responses
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: signed-in users and the service role only.
-- -----------------------------------------------------------------------------
revoke execute on function
  fhir.resource_table(text),
  fhir.find_by_identifier(text, text),
  fhir.resolve_conditional_reference(text),
  fhir.trusted_caller(),
  fhir.log_access(text, text),
  fhir.log_search(text, text, jsonb, integer),
  fhir.search_resources(text, text, jsonb, integer, integer, boolean),
  fhir.read_resource(text, text),
  fhir.create_resource(jsonb),
  fhir.update_resource(jsonb, integer),
  fhir.delete_resource(text, text),
  fhir.history(text, text),
  fhir.patient_everything(text),
  fhir.import_bundle(jsonb)
from public, anon;

grant execute on function
  fhir.resource_table(text),
  fhir.find_by_identifier(text, text),
  fhir.resolve_conditional_reference(text),
  fhir.trusted_caller(),
  fhir.log_access(text, text),
  fhir.log_search(text, text, jsonb, integer),
  fhir.search_resources(text, text, jsonb, integer, integer, boolean),
  fhir.read_resource(text, text),
  fhir.create_resource(jsonb),
  fhir.update_resource(jsonb, integer),
  fhir.delete_resource(text, text),
  fhir.history(text, text),
  fhir.patient_everything(text),
  fhir.import_bundle(jsonb)
to authenticated, service_role;
