-- Schema shape and the fail-closed grants.
begin;
select plan(13);

select has_table('fhir', 'resource_type', 'registry table exists');
select has_table('fhir', 'resource_history', 'history table exists');
select has_table('fhir', 'audit_log', 'audit table exists');
select has_table('fhir', 'patient_access', 'access grants table exists');
select has_table('fhir', 'patient', 'patient table exists');
select has_table('fhir', 'observation', 'observation table exists');
select has_column('fhir', 'observation', 'patient_id', 'resource tables carry the patient compartment column');
select has_function('fhir', 'define_resource', 'define_resource exists');
select has_function('fhir', 'import_bundle', 'import_bundle exists');
select is((select count(*)::int from fhir.resource_type), 26, 'registry lists the 26 shipped resource types');
select ok(not has_schema_privilege('anon', 'fhir', 'usage'), 'anon has no access to the fhir schema');
select ok(has_schema_privilege('authenticated', 'fhir', 'usage'), 'authenticated can use the fhir schema');
select ok(
  (select relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'fhir' and c.relname = 'observation'),
  'row level security is enabled on resource tables');

select * from finish();
rollback;
