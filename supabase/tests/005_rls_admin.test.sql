-- Admins (JWT app_metadata.fhir_role = 'admin') manage everything; user_metadata cannot fake it (UC-009).
begin;
select plan(9);

create function pg_temp.login(user_id uuid, extra_claims jsonb default '{}'::jsonb) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', user_id::text, 'role', 'authenticated') || extra_claims)::text, true);
  set local role authenticated;
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000c01', 'dave@test.local'),
  ('00000000-0000-4000-8000-000000000c02', 'eve@test.local');
insert into fhir.patient (resource) values
  ('{"resourceType":"Patient","id":"ra-1","name":[{"family":"One"}]}'),
  ('{"resourceType":"Patient","id":"ra-2","name":[{"family":"Two"}]}');

select pg_temp.login('00000000-0000-4000-8000-000000000c01', '{"app_metadata":{"fhir_role":"admin"}}');
select is(fhir.is_admin(), true, 'app_metadata.fhir_role = admin is recognised');
select results_eq($$select id from fhir.patient where id like 'ra-%' order by id$$, $$values ('ra-1'), ('ra-2')$$, 'admins see every patient');
select lives_ok(
  $$insert into fhir.patient_access (user_id, patient_id, access_level) values ('00000000-0000-4000-8000-000000000c02', 'ra-1', 'read')$$,
  'admins grant access');
select lives_ok(
  $$insert into fhir.organization (resource) values ('{"resourceType":"Organization","id":"ra-org","name":"Admin Clinic"}')$$,
  'admins write reference data');
select lives_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","id":"ra-o1","status":"final","code":{"text":"orphan"}}')$$,
  'admins can write resources without a patient');
select isnt_empty($$select 1 from fhir.audit_log$$, 'admins read the audit log');

select pg_temp.login('00000000-0000-4000-8000-000000000c02', '{"user_metadata":{"fhir_role":"admin"}}');
select is(fhir.is_admin(), false, 'user_metadata cannot grant admin');
select results_eq($$select id from fhir.patient where id like 'ra-%'$$, $$values ('ra-1')$$, 'non-admins only see granted compartments');
select is_empty($$select 1 from fhir.audit_log$$, 'non-admins cannot read the audit log');

reset role;
select * from finish();
rollback;
