-- Versioning, history, audit and integrity checks (UC-004, UC-005, UC-023).
-- Runs as the migration owner, so RLS does not interfere.
begin;
select plan(18);

insert into fhir.patient (resource) values
  ('{"resourceType":"Patient","name":[{"family":"Trigger"}],"birthDate":"1980-02-03","gender":"male"}');

select is((select version_id from fhir.patient where family_name = 'Trigger'), 1, 'new resources start at version 1');
select ok((select resource ->> 'id' = id from fhir.patient where family_name = 'Trigger'), 'resource.id mirrors the row id');
select is((select resource #>> '{meta,versionId}' from fhir.patient where family_name = 'Trigger'), '1', 'meta.versionId is stamped');
select ok((select resource #>> '{meta,lastUpdated}' ~ '^\d{4}-\d{2}-\d{2}T.*Z$' from fhir.patient where family_name = 'Trigger'), 'meta.lastUpdated is a UTC instant');
select is((select birth_date from fhir.patient where family_name = 'Trigger'), '1980-02-03'::date, 'search columns are generated from the resource');

insert into fhir.patient (resource) values ('{"resourceType":"Patient","id":"trg-1","name":[{"family":"Explicit"}]}');
select is((select id from fhir.patient where family_name = 'Explicit'), 'trg-1', 'a client supplied resource.id is kept');

insert into fhir.observation (resource) values
  ('{"resourceType":"Observation","id":"trg-o1","status":"final","code":{"coding":[{"system":"http://loinc.org","code":"8302-2"}]},"subject":{"reference":"Patient/trg-1"},"effectiveDateTime":"2024-01-02T03:04:05Z","valueQuantity":{"value":171.2,"unit":"cm"}}');
select is((select patient_id from fhir.observation where id = 'trg-o1'), 'trg-1', 'patient_id is derived from subject');
select is((select code from fhir.observation where id = 'trg-o1'), '8302-2', 'observation.code is generated');
select is((select value_quantity from fhir.observation where id = 'trg-o1'), 171.2::numeric, 'observation.value_quantity is generated');
select is((select effective_at from fhir.observation where id = 'trg-o1'), '2024-01-02T03:04:05Z'::timestamptz, 'observation.effective_at is generated');

update fhir.observation set resource = resource || '{"status":"amended"}' where id = 'trg-o1';
select is((select version_id from fhir.observation where id = 'trg-o1'), 2, 'updates bump version_id');
select is((select resource #>> '{meta,versionId}' from fhir.observation where id = 'trg-o1'), '2', 'meta.versionId follows version_id');
select results_eq(
  $$select version_id, operation, resource ->> 'status' from fhir.resource_history where resource_type = 'Observation' and id = 'trg-o1'$$,
  $$values (1, 'update', 'final')$$,
  'the superseded version lands in resource_history');

delete from fhir.observation where id = 'trg-o1';
select results_eq(
  $$select version_id, operation from fhir.resource_history where resource_type = 'Observation' and id = 'trg-o1' order by version_id$$,
  $$values (1, 'update'), (2, 'delete')$$,
  'deletes keep the last version in resource_history');
select results_eq(
  $$select action from fhir.audit_log where resource_type = 'Observation' and resource_id = 'trg-o1' order by id$$,
  $$values ('create'), ('update'), ('delete')$$,
  'every write is audited');

select throws_ok(
  $$insert into fhir.patient (resource) values ('{"resourceType":"Observation","id":"nope"}')$$,
  '23514', null, 'resourceType must match the table');
select throws_ok(
  $$update fhir.patient set id = 'renamed' where id = 'trg-1'$$,
  '23514', null, 'ids are immutable');
select throws_ok(
  $$insert into fhir.patient (resource) values ('{"resourceType":"Patient","id":"bad id!"}')$$,
  '23514', null, 'ids must match the FHIR id pattern');

select * from finish();
rollback;
