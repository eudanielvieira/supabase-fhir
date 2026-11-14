-- =============================================================================
-- supabase-fhir | 0004 resource tables
-- The US Core / Synthea set. Add your own with fhir.define_resource().
-- Generated search columns mirror the most used FHIR search parameters so
-- PostgREST filters hit an index instead of parsing JSON.
-- =============================================================================

-- Reference data (not scoped to a patient, readable by every signed-in user)
select fhir.define_resource('Practitioner', false);
select fhir.define_resource('PractitionerRole', false);
select fhir.define_resource('Organization', false);
select fhir.define_resource('Location', false);
select fhir.define_resource('Medication', false);

-- Patient compartment
select fhir.define_resource('Patient');
select fhir.define_resource('Encounter');
select fhir.define_resource('Condition');
select fhir.define_resource('Observation');
select fhir.define_resource('Procedure');
select fhir.define_resource('MedicationRequest');
select fhir.define_resource('MedicationAdministration');
select fhir.define_resource('Immunization');
select fhir.define_resource('AllergyIntolerance');
select fhir.define_resource('DiagnosticReport');
select fhir.define_resource('DocumentReference');
select fhir.define_resource('CarePlan');
select fhir.define_resource('CareTeam');
select fhir.define_resource('Goal');
select fhir.define_resource('Device');
select fhir.define_resource('ImagingStudy');
select fhir.define_resource('SupplyDelivery');
select fhir.define_resource('Coverage');
select fhir.define_resource('Claim');
select fhir.define_resource('ExplanationOfBenefit');
select fhir.define_resource('Provenance');

-- Deleting a Patient removes its grants (cascade) and orphans its clinical resources,
-- so only admins may do it. Clinicians with write access still update demographics.
drop policy fhir_delete on fhir.patient;
create policy fhir_delete on fhir.patient
  for delete to authenticated
  using ((select fhir.is_admin()));

-- Access grants point at real patients and disappear with them.
alter table fhir.patient_access
  add constraint patient_access_patient_fk
  foreign key (patient_id) references fhir.patient (id) on delete cascade;

-- -----------------------------------------------------------------------------
-- Search columns
-- -----------------------------------------------------------------------------
alter table fhir.patient
  add column family_name text generated always as (resource #>> '{name,0,family}') stored,
  add column birth_date  date generated always as (fhir.parse_date(resource ->> 'birthDate')) stored,
  add column gender      text generated always as (resource ->> 'gender') stored,
  add column active      boolean generated always as (
    case when resource ->> 'active' in ('true', 'false') then (resource ->> 'active')::boolean else true end) stored;
create index patient_family_name_idx on fhir.patient (family_name);
create index patient_birth_date_idx on fhir.patient (birth_date);

alter table fhir.practitioner
  add column family_name text generated always as (resource #>> '{name,0,family}') stored;

alter table fhir.organization
  add column name text generated always as (resource ->> 'name') stored;

alter table fhir.location
  add column name text generated always as (resource ->> 'name') stored;

alter table fhir.encounter
  add column status       text generated always as (resource ->> 'status') stored,
  add column class_code   text generated always as (resource #>> '{class,code}') stored,
  add column type_code    text generated always as (resource #>> '{type,0,coding,0,code}') stored,
  add column period_start timestamptz generated always as (fhir.parse_datetime(resource #>> '{period,start}')) stored,
  add column period_end   timestamptz generated always as (fhir.parse_datetime(resource #>> '{period,end}')) stored;
create index encounter_period_start_idx on fhir.encounter (patient_id, period_start desc);

alter table fhir.condition
  add column clinical_status     text generated always as (resource #>> '{clinicalStatus,coding,0,code}') stored,
  add column verification_status text generated always as (resource #>> '{verificationStatus,coding,0,code}') stored,
  add column code                text generated always as (resource #>> '{code,coding,0,code}') stored,
  add column code_system         text generated always as (resource #>> '{code,coding,0,system}') stored,
  add column onset_at            timestamptz generated always as (fhir.parse_datetime(resource ->> 'onsetDateTime')) stored,
  add column abatement_at        timestamptz generated always as (fhir.parse_datetime(resource ->> 'abatementDateTime')) stored,
  add column encounter_id        text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index condition_code_idx on fhir.condition (code);
create index condition_encounter_idx on fhir.condition (encounter_id);

alter table fhir.observation
  add column status         text generated always as (resource ->> 'status') stored,
  add column category_code  text generated always as (resource #>> '{category,0,coding,0,code}') stored,
  add column code           text generated always as (resource #>> '{code,coding,0,code}') stored,
  add column code_system    text generated always as (resource #>> '{code,coding,0,system}') stored,
  add column effective_at   timestamptz generated always as (fhir.parse_datetime(coalesce(
                              resource ->> 'effectiveDateTime',
                              resource #>> '{effectivePeriod,start}',
                              resource ->> 'effectiveInstant'))) stored,
  add column value_quantity numeric generated always as (
    case when jsonb_typeof(resource #> '{valueQuantity,value}') = 'number'
         then (resource #> '{valueQuantity,value}')::numeric end) stored,
  add column value_unit     text generated always as (resource #>> '{valueQuantity,unit}') stored,
  add column encounter_id   text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index observation_code_idx on fhir.observation (patient_id, code, effective_at desc);
create index observation_encounter_idx on fhir.observation (encounter_id);
create index observation_category_idx on fhir.observation (category_code);

alter table fhir.procedure
  add column status       text generated always as (resource ->> 'status') stored,
  add column code         text generated always as (resource #>> '{code,coding,0,code}') stored,
  add column performed_at timestamptz generated always as (fhir.parse_datetime(coalesce(
                            resource ->> 'performedDateTime',
                            resource #>> '{performedPeriod,start}'))) stored,
  add column encounter_id text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index procedure_code_idx on fhir.procedure (code);
create index procedure_encounter_idx on fhir.procedure (encounter_id);

alter table fhir.medication_request
  add column status          text generated always as (resource ->> 'status') stored,
  add column intent          text generated always as (resource ->> 'intent') stored,
  add column medication_code text generated always as (resource #>> '{medicationCodeableConcept,coding,0,code}') stored,
  add column authored_on     timestamptz generated always as (fhir.parse_datetime(resource ->> 'authoredOn')) stored,
  add column encounter_id    text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index medication_request_status_idx on fhir.medication_request (patient_id, status);

alter table fhir.medication_administration
  add column status          text generated always as (resource ->> 'status') stored,
  add column medication_code text generated always as (resource #>> '{medicationCodeableConcept,coding,0,code}') stored,
  add column effective_at    timestamptz generated always as (fhir.parse_datetime(coalesce(
                               resource ->> 'effectiveDateTime',
                               resource #>> '{effectivePeriod,start}'))) stored;

alter table fhir.immunization
  add column status        text generated always as (resource ->> 'status') stored,
  add column vaccine_code  text generated always as (resource #>> '{vaccineCode,coding,0,code}') stored,
  add column occurrence_at timestamptz generated always as (fhir.parse_datetime(resource ->> 'occurrenceDateTime')) stored,
  add column encounter_id  text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index immunization_vaccine_idx on fhir.immunization (vaccine_code);

alter table fhir.allergy_intolerance
  add column clinical_status text generated always as (resource #>> '{clinicalStatus,coding,0,code}') stored,
  add column code            text generated always as (resource #>> '{code,coding,0,code}') stored,
  add column category        text generated always as (resource #>> '{category,0}') stored,
  add column criticality     text generated always as (resource ->> 'criticality') stored,
  add column recorded_at     timestamptz generated always as (fhir.parse_datetime(resource ->> 'recordedDate')) stored;

alter table fhir.diagnostic_report
  add column status       text generated always as (resource ->> 'status') stored,
  add column code         text generated always as (resource #>> '{code,coding,0,code}') stored,
  add column effective_at timestamptz generated always as (fhir.parse_datetime(coalesce(
                            resource ->> 'effectiveDateTime',
                            resource #>> '{effectivePeriod,start}'))) stored,
  add column encounter_id text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;
create index diagnostic_report_encounter_idx on fhir.diagnostic_report (encounter_id);

alter table fhir.document_reference
  add column status        text generated always as (resource ->> 'status') stored,
  add column type_code     text generated always as (resource #>> '{type,coding,0,code}') stored,
  add column document_date timestamptz generated always as (fhir.parse_datetime(resource ->> 'date')) stored,
  add column encounter_id  text generated always as (fhir.reference_id(resource #>> '{context,encounter,0,reference}', 'Encounter')) stored;

alter table fhir.care_plan
  add column status       text generated always as (resource ->> 'status') stored,
  add column intent       text generated always as (resource ->> 'intent') stored,
  add column period_start timestamptz generated always as (fhir.parse_datetime(resource #>> '{period,start}')) stored,
  add column encounter_id text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;

alter table fhir.care_team
  add column status       text generated always as (resource ->> 'status') stored,
  add column encounter_id text generated always as (fhir.reference_id(resource #>> '{encounter,reference}', 'Encounter')) stored;

alter table fhir.goal
  add column lifecycle_status text generated always as (resource ->> 'lifecycleStatus') stored;

alter table fhir.coverage
  add column status text generated always as (resource ->> 'status') stored;

alter table fhir.claim
  add column status text generated always as (resource ->> 'status') stored,
  add column use    text generated always as (resource ->> 'use') stored;

alter table fhir.explanation_of_benefit
  add column status text generated always as (resource ->> 'status') stored;
