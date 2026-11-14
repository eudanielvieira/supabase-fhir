-- import_bundle: reference resolution, idempotency, conditional create, deletes and RLS (UC-012).
begin;
select plan(19);

create function pg_temp.login(user_id uuid, extra_claims jsonb default '{}'::jsonb) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', user_id::text, 'role', 'authenticated') || extra_claims)::text, true);
  set local role authenticated;
end $$;

create function pg_temp.sample_bundle() returns jsonb language sql as $$
  select $j${
    "resourceType": "Bundle", "type": "transaction",
    "entry": [
      {"fullUrl": "urn:uuid:11111111-1111-4111-8111-111111111111",
       "resource": {"resourceType": "Patient", "name": [{"family": "Bundle"}]},
       "request": {"method": "POST", "url": "Patient"}},
      {"fullUrl": "urn:uuid:33333333-3333-4333-8333-333333333333",
       "resource": {"resourceType": "Encounter", "status": "finished", "class": {"code": "AMB"},
                    "subject": {"reference": "urn:uuid:11111111-1111-4111-8111-111111111111"},
                    "serviceProvider": {"reference": "Organization?identifier=urn:test|org-1"},
                    "participant": [{"individual": {"reference": "Practitioner?identifier=urn:test|npi-9"}}]},
       "request": {"method": "POST", "url": "Encounter"}},
      {"fullUrl": "urn:uuid:22222222-2222-4222-8222-222222222222",
       "resource": {"resourceType": "Organization", "name": "Imported Clinic", "identifier": [{"system": "urn:test", "value": "org-1"}]},
       "request": {"method": "POST", "url": "Organization", "ifNoneExist": "identifier=urn:test|org-1"}},
      {"fullUrl": "urn:uuid:44444444-4444-4444-8444-444444444444",
       "resource": {"resourceType": "Observation", "status": "final", "code": {"text": "hr"},
                    "subject": {"reference": "urn:uuid:11111111-1111-4111-8111-111111111111"},
                    "encounter": {"reference": "urn:uuid:33333333-3333-4333-8333-333333333333"}},
       "request": {"method": "POST", "url": "Observation"}}
    ]}$j$::jsonb;
$$;

insert into fhir.practitioner (resource) values
  ('{"resourceType":"Practitioner","id":"imp-pr9","identifier":[{"system":"urn:test","value":"npi-9"}]}');

select results_eq(
  $$select e -> 'response' ->> 'status' from jsonb_array_elements(fhir.import_bundle(pg_temp.sample_bundle()) -> 'entry') e$$,
  $$values ('201 Created'), ('201 Created'), ('201 Created'), ('201 Created')$$,
  'every entry is created on first import');
select is((select id from fhir.patient where family_name = 'Bundle'), '11111111-1111-4111-8111-111111111111', 'urn:uuid fullUrls become the resource id');
select is((select resource #>> '{subject,reference}' from fhir.encounter where id = '33333333-3333-4333-8333-333333333333'),
  'Patient/11111111-1111-4111-8111-111111111111', 'urn:uuid references are rewritten to Type/id');
select is((select resource #>> '{serviceProvider,reference}' from fhir.encounter where id = '33333333-3333-4333-8333-333333333333'),
  'Organization/22222222-2222-4222-8222-222222222222', 'conditional references resolve against the bundle, even to later entries');
select is((select resource #>> '{participant,0,individual,reference}' from fhir.encounter where id = '33333333-3333-4333-8333-333333333333'),
  'Practitioner/imp-pr9', 'conditional references resolve against existing rows');
select is((select patient_id from fhir.observation where id = '44444444-4444-4444-8444-444444444444'),
  '11111111-1111-4111-8111-111111111111', 'imported resources land in the right compartment');

select results_eq(
  $$select e -> 'response' ->> 'status' from jsonb_array_elements(fhir.import_bundle(pg_temp.sample_bundle()) -> 'entry') e$$,
  $$values ('200 OK'), ('200 OK'), ('200 OK'), ('200 OK')$$,
  're-importing the same bundle updates instead of duplicating');
select is((select version_id from fhir.patient where id = '11111111-1111-4111-8111-111111111111'), 2, 'upserted resources get a new version');
select is((select count(*)::int from fhir.organization where resource @> '{"identifier":[{"system":"urn:test","value":"org-1"}]}'), 1,
  'ifNoneExist with an identifier reuses the existing resource');
select is((select fhir.import_bundle('{"resourceType":"Bundle","type":"batch","entry":[]}'::jsonb) ->> 'type'), 'batch-response', 'batch bundles answer with a batch-response');

select throws_ok($$select fhir.import_bundle('{"resourceType":"Patient"}'::jsonb)$$, 'PT400', null, 'non-bundles are rejected');
select throws_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[{"resource":{"resourceType":"Specimen"}}]}'::jsonb)$$,
  'PT400', null, 'unknown resource types are rejected');

select lives_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[{"request":{"method":"DELETE","url":"Observation/44444444-4444-4444-8444-444444444444"}}]}'::jsonb)$$,
  'DELETE entries are accepted');
select is_empty($$select 1 from fhir.observation where id = '44444444-4444-4444-8444-444444444444'$$, 'DELETE entries remove the resource');

select lives_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[
    {"fullUrl":"urn:uuid:55555555-5555-4555-8555-555555555555","resource":{"resourceType":"Patient","identifier":[{"system":"urn:test","value":"urn:uuid:66666666-6666-4666-8666-666666666666"}]},"request":{"method":"POST","url":"Patient"}},
    {"fullUrl":"urn:uuid:66666666-6666-4666-8666-666666666666","resource":{"resourceType":"Observation","status":"final","code":{"text":"x"},"subject":{"reference":"urn:uuid:55555555-5555-4555-8555-555555555555"}},"request":{"method":"POST","url":"Observation"}}]}'::jsonb)$$,
  'a bundle whose identifier equals a fullUrl imports');
select is((select resource #>> '{identifier,0,value}' from fhir.patient where id = '55555555-5555-4555-8555-555555555555'),
  'urn:uuid:66666666-6666-4666-8666-666666666666', 'only reference values are rewritten; identifiers are left alone');

-- RLS applies to imports too
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d01', 'carol@test.local');
insert into fhir.patient (resource) values ('{"resourceType":"Patient","id":"imp-other","name":[{"family":"Other"}]}');
insert into fhir.patient_access (user_id, patient_id, access_level) values
  ('00000000-0000-4000-8000-000000000d01', '11111111-1111-4111-8111-111111111111', 'write');
select pg_temp.login('00000000-0000-4000-8000-000000000d01');
select lives_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[{"resource":{"resourceType":"Observation","status":"final","code":{"text":"ok"},"subject":{"reference":"Patient/11111111-1111-4111-8111-111111111111"}}}]}'::jsonb)$$,
  'a clinician imports into a compartment they can write');
select throws_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[{"resource":{"resourceType":"Observation","status":"final","code":{"text":"no"},"subject":{"reference":"Patient/imp-other"}}}]}'::jsonb)$$,
  '42501', null, 'imports into other compartments are refused by RLS');
select throws_ok(
  $$select fhir.import_bundle('{"resourceType":"Bundle","type":"transaction","entry":[{"resource":{"resourceType":"Organization","name":"Rogue"}}]}'::jsonb)$$,
  '42501', null, 'non-admins cannot import reference data');

reset role;
select * from finish();
rollback;
