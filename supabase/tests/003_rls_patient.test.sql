-- A patient portal user sees only their own compartment; anon sees nothing (UC-007, UC-011, UC-006).
begin;
select plan(17);

create function pg_temp.login(user_id uuid, extra_claims jsonb default '{}'::jsonb) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', user_id::text, 'role', 'authenticated') || extra_claims)::text, true);
  set local role authenticated;
end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000a01', 'alice@test.local'),
  ('00000000-0000-4000-8000-000000000a02', 'bob@test.local');
insert into fhir.patient (resource) values
  ('{"resourceType":"Patient","id":"rls-p1","name":[{"family":"Alice"}]}'),
  ('{"resourceType":"Patient","id":"rls-p2","name":[{"family":"Bob"}]}');
insert into fhir.observation (resource) values
  ('{"resourceType":"Observation","id":"rls-o1","status":"final","code":{"text":"a"},"subject":{"reference":"Patient/rls-p1"}}'),
  ('{"resourceType":"Observation","id":"rls-o2","status":"final","code":{"text":"b"},"subject":{"reference":"Patient/rls-p2"}}'),
  ('{"resourceType":"Observation","id":"rls-o3","status":"final","code":{"text":"c"}}');
insert into fhir.organization (resource) values ('{"resourceType":"Organization","id":"rls-org","name":"Clinic"}');
update fhir.observation set resource = resource || '{"status":"amended"}' where id in ('rls-o1', 'rls-o2');
insert into fhir.patient_access (user_id, patient_id, access_level) values
  ('00000000-0000-4000-8000-000000000a01', 'rls-p1', 'read'),
  ('00000000-0000-4000-8000-000000000a02', 'rls-p2', 'read');

-- alice: patient user with read access to her own compartment
select pg_temp.login('00000000-0000-4000-8000-000000000a01');
select results_eq($$select id from fhir.patient order by id$$, $$values ('rls-p1')$$, 'a patient sees only their own Patient');
select results_eq($$select id from fhir.observation order by id$$, $$values ('rls-o1')$$, 'a patient sees only observations in their compartment');
select is_empty($$select id from fhir.observation where id = 'rls-o3'$$, 'rows without a patient are hidden from non-admins');
select results_eq($$select id from fhir.organization where id = 'rls-org'$$, $$values ('rls-org')$$, 'reference data is readable by any signed-in user');
select throws_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","status":"final","code":{"text":"x"},"subject":{"reference":"Patient/rls-p1"}}')$$,
  '42501', null, 'read access does not allow inserts');
update fhir.observation set resource = resource || '{"status":"final"}' where id = 'rls-o1';
select is((select resource ->> 'status' from fhir.observation where id = 'rls-o1'), 'amended', 'read access does not allow updates (row untouched)');
delete from fhir.observation where id = 'rls-o1';
select isnt_empty($$select 1 from fhir.observation where id = 'rls-o1'$$, 'read access does not allow deletes (row untouched)');
select results_eq($$select version_id, operation from fhir.resource_history where id = 'rls-o1'$$, $$values (1, 'update')$$, 'history of own compartment is visible');
select is_empty($$select 1 from fhir.resource_history where id = 'rls-o2'$$, 'history of other compartments is hidden');
select is_empty($$select 1 from fhir.audit_log$$, 'audit log is hidden from non-admins');
select results_eq($$select patient_id from fhir.patient_access$$, $$values ('rls-p1')$$, 'users see only their own grants');
select throws_ok(
  $$insert into fhir.patient_access (user_id, patient_id) values ('00000000-0000-4000-8000-000000000a01', 'rls-p2')$$,
  '42501', null, 'users cannot grant themselves access');
select throws_ok($$select fhir.read_resource('Patient', 'rls-p2')$$, 'PT404', null, 'read_resource answers 404 outside the compartment');
select is((select fhir.read_resource('Patient', 'rls-p1') ->> 'id'), 'rls-p1', 'read_resource returns own resources');
select throws_ok($$select fhir.patient_everything('rls-p2')$$, 'PT404', null, 'patient_everything answers 404 outside the compartment');
select is((select (fhir.patient_everything('rls-p1') ->> 'total')::int), 2, 'patient_everything returns the compartment (Patient + Observation)');

-- anon: nothing at all
select pg_temp.logout();
set local role anon;
select throws_ok($$select count(*) from fhir.patient$$, '42501', null, 'anon cannot touch the fhir schema');
reset role;

select * from finish();
rollback;
