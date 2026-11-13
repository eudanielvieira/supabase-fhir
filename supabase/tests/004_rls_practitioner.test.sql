-- A clinician reads and writes only the compartments granted to them, while the grant is valid
-- (UC-008, UC-010, UC-017).
begin;
select plan(15);

create function pg_temp.login(user_id uuid, extra_claims jsonb default '{}'::jsonb) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', user_id::text, 'role', 'authenticated') || extra_claims)::text, true);
  set local role authenticated;
end $$;

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000b01', 'carol@test.local');
insert into fhir.patient (resource) values
  ('{"resourceType":"Patient","id":"rp-1","name":[{"family":"Write"}]}'),
  ('{"resourceType":"Patient","id":"rp-2","name":[{"family":"Read"}]}'),
  ('{"resourceType":"Patient","id":"rp-3","name":[{"family":"Expired"}]}'),
  ('{"resourceType":"Patient","id":"rp-4","name":[{"family":"Future"}]}'),
  ('{"resourceType":"Patient","id":"rp-5","name":[{"family":"NoGrant"}]}');
insert into fhir.observation (resource) values
  ('{"resourceType":"Observation","id":"rp-o1","status":"final","code":{"text":"a"},"subject":{"reference":"Patient/rp-1"}}'),
  ('{"resourceType":"Observation","id":"rp-o2","status":"final","code":{"text":"b"},"subject":{"reference":"Patient/rp-2"}}');
insert into fhir.patient_access (user_id, patient_id, access_level, valid_from, valid_until) values
  ('00000000-0000-4000-8000-000000000b01', 'rp-1', 'write', now() - interval '1 day', null),
  ('00000000-0000-4000-8000-000000000b01', 'rp-2', 'read',  now() - interval '1 day', null),
  ('00000000-0000-4000-8000-000000000b01', 'rp-3', 'write', now() - interval '2 day', now() - interval '1 day'),
  ('00000000-0000-4000-8000-000000000b01', 'rp-4', 'write', now() + interval '1 day', null);

select pg_temp.login('00000000-0000-4000-8000-000000000b01');

select results_eq($$select id from fhir.patient where id like 'rp-%' order by id$$, $$values ('rp-1'), ('rp-2')$$,
  'only currently valid grants count (expired and future grants are ignored)');
select lives_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","id":"rp-o1b","status":"final","code":{"text":"c"},"subject":{"reference":"Patient/rp-1"}}')$$,
  'write grant allows inserts');
select throws_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","status":"final","code":{"text":"c"},"subject":{"reference":"Patient/rp-2"}}')$$,
  '42501', null, 'read grant blocks inserts');
select throws_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","status":"final","code":{"text":"c"},"subject":{"reference":"Patient/rp-3"}}')$$,
  '42501', null, 'expired grant blocks inserts');
select throws_ok(
  $$insert into fhir.observation (resource) values ('{"resourceType":"Observation","status":"final","code":{"text":"c"},"subject":{"reference":"Patient/rp-5"}}')$$,
  '42501', null, 'no grant blocks inserts');

select is(
  (select fhir.update_resource('{"resourceType":"Observation","id":"rp-o1","status":"amended","code":{"text":"a"},"subject":{"reference":"Patient/rp-1"}}'::jsonb, 1) ->> 'status'),
  'amended', 'update_resource with the current expected_version succeeds');
select throws_ok(
  $$select fhir.update_resource('{"resourceType":"Observation","id":"rp-o1","status":"final","code":{"text":"a"},"subject":{"reference":"Patient/rp-1"}}'::jsonb, 1)$$,
  'PT409', null, 'a stale expected_version answers 409');
select throws_ok(
  $$select fhir.update_resource('{"resourceType":"Observation","id":"rp-o1","status":"final","code":{"text":"a"},"subject":{"reference":"Patient/rp-2"}}'::jsonb)$$,
  '42501', null, 'moving a resource into a read-only compartment is refused');
select throws_ok(
  $$select fhir.update_resource('{"resourceType":"Observation","id":"rp-o2","status":"amended","code":{"text":"b"},"subject":{"reference":"Patient/rp-2"}}'::jsonb)$$,
  '42501', null, 'updating a visible but read-only resource answers 403');
select throws_ok(
  $$select fhir.delete_resource('Observation', 'rp-o2')$$,
  '42501', null, 'deleting a visible but read-only resource answers 403');
select lives_ok($$select fhir.delete_resource('Observation', 'rp-o1b')$$, 'write grant allows deletes');
select throws_ok(
  $$insert into fhir.organization (resource) values ('{"resourceType":"Organization","name":"Rogue"}')$$,
  '42501', null, 'reference data is writable by admins only');
select throws_ok(
  $$insert into fhir.patient_access (user_id, patient_id, access_level) values ('00000000-0000-4000-8000-000000000b01', 'rp-5', 'write')$$,
  '42501', null, 'clinicians cannot grant themselves access');
select is((select (fhir.patient_everything('rp-1') ->> 'total')::int), 2, 'patient_everything covers the granted compartment');
select throws_ok($$select fhir.patient_everything('rp-3')$$, 'PT404', null, 'patient_everything answers 404 once a grant expired');

select * from finish();
rollback;
