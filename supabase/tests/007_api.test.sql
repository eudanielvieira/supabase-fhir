-- RPC surface: create / read / update / delete / history and the helper functions (UC-003, UC-015).
begin;
select plan(22);

select is(fhir.table_name('MedicationRequest'), 'medication_request', 'table_name converts PascalCase to snake_case');
select is(fhir.table_name('ExplanationOfBenefit'), 'explanation_of_benefit', 'table_name handles three words');
select is(fhir.reference_id('Patient/abc', 'Patient'), 'abc', 'reference_id parses relative references');
select is(fhir.reference_id('https://fhir.example.org/r4/Patient/abc/_history/2', 'Patient'), 'abc', 'reference_id parses absolute versioned references');
select is(fhir.reference_id('Group/abc', 'Patient'), null, 'reference_id ignores other types');
select is(fhir.reference_id('urn:uuid:abc', 'Patient'), null, 'reference_id ignores urn references');
select is(fhir.parse_datetime('2024-03'), '2024-03-01T00:00:00Z'::timestamptz, 'partial dates are expanded in UTC');
select is(fhir.parse_datetime('not a date'), null, 'unparsable dates become null instead of failing the write');

select is((select fhir.create_resource('{"resourceType":"Patient","name":[{"family":"Api"}]}'::jsonb) #>> '{meta,versionId}'), '1', 'create_resource returns the stored resource');
select throws_ok($$select fhir.create_resource('{"name":"no type"}'::jsonb)$$, 'PT400', null, 'create_resource needs resourceType');
select throws_ok($$select fhir.create_resource('{"resourceType":"Specimen"}'::jsonb)$$, 'PT400', null, 'create_resource rejects undefined types');
select throws_ok($$select fhir.read_resource('Patient', 'does-not-exist')$$, 'PT404', null, 'read_resource answers 404 for unknown ids');

create function pg_temp.error_detail(sql text) returns jsonb language plpgsql as $$
declare d text;
begin
  execute sql;
  return null;
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return d::jsonb;
end $$;
select is((select pg_temp.error_detail($$select fhir.read_resource('Patient', 'does-not-exist')$$) ->> 'resourceType'), 'OperationOutcome',
  'errors carry a FHIR OperationOutcome in the detail');
select is((select pg_temp.error_detail($$select fhir.read_resource('Patient', 'does-not-exist')$$) #>> '{issue,0,code}'), 'not-found',
  'the OperationOutcome issue code follows the FHIR IssueType value set');
select throws_ok($$select fhir.update_resource('{"resourceType":"Patient","id":"does-not-exist"}'::jsonb)$$, 'PT404', null, 'update_resource answers 404 for unknown ids');
select throws_ok($$select fhir.delete_resource('Patient', 'does-not-exist')$$, 'PT404', null, 'delete_resource answers 404 for unknown ids');

insert into fhir.patient (resource) values ('{"resourceType":"Patient","id":"api-1","name":[{"family":"V1"}]}');
select fhir.update_resource('{"resourceType":"Patient","id":"api-1","name":[{"family":"V2"}]}'::jsonb);
select results_eq(
  $$select version_id, operation, resource #>> '{name,0,family}' from fhir.history('Patient', 'api-1')$$,
  $$values (2, 'current', 'V2'), (1, 'update', 'V1')$$,
  'history lists every version, newest first');
select fhir.delete_resource('Patient', 'api-1');
select results_eq(
  $$select version_id, operation from fhir.history('Patient', 'api-1')$$,
  $$values (2, 'delete'), (1, 'update')$$,
  'history keeps deleted resources');
select is((select count(*)::int from fhir.audit_log where resource_id = 'api-1'), 3, 'create, update and delete through the API are audited');

select is(fhir.define_resource('Specimen'), 'specimen', 'define_resource creates a new resource table');
select ok(
  (select relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'fhir' and c.relname = 'specimen'),
  'new resource tables start with RLS enabled');
select throws_ok($$select fhir.define_resource('not a type')$$, '22023', null, 'define_resource validates the type name');

select * from finish();
rollback;
