import type * as r4 from 'fhir/r4';

/**
 * Resource types that ship with a table, mapped to their table name.
 * Keep in sync with supabase/migrations/*_fhir_resources.sql.
 */
export const TABLE_NAMES = {
  Patient: 'patient',
  Practitioner: 'practitioner',
  PractitionerRole: 'practitioner_role',
  Organization: 'organization',
  Location: 'location',
  Medication: 'medication',
  Encounter: 'encounter',
  Condition: 'condition',
  Observation: 'observation',
  Procedure: 'procedure',
  MedicationRequest: 'medication_request',
  MedicationAdministration: 'medication_administration',
  Immunization: 'immunization',
  AllergyIntolerance: 'allergy_intolerance',
  DiagnosticReport: 'diagnostic_report',
  DocumentReference: 'document_reference',
  CarePlan: 'care_plan',
  CareTeam: 'care_team',
  Goal: 'goal',
  Device: 'device',
  ImagingStudy: 'imaging_study',
  SupplyDelivery: 'supply_delivery',
  Coverage: 'coverage',
  Claim: 'claim',
  ExplanationOfBenefit: 'explanation_of_benefit',
  Provenance: 'provenance',
} as const satisfies Record<string, string>;

export type ResourceType = keyof typeof TABLE_NAMES;
export type TableName = (typeof TABLE_NAMES)[ResourceType];

export const RESOURCE_TYPES = Object.keys(TABLE_NAMES) as ResourceType[];

/** FHIR R4 TypeScript type for each supported resource type. */
export interface ResourceMap {
  Patient: r4.Patient;
  Practitioner: r4.Practitioner;
  PractitionerRole: r4.PractitionerRole;
  Organization: r4.Organization;
  Location: r4.Location;
  Medication: r4.Medication;
  Encounter: r4.Encounter;
  Condition: r4.Condition;
  Observation: r4.Observation;
  Procedure: r4.Procedure;
  MedicationRequest: r4.MedicationRequest;
  MedicationAdministration: r4.MedicationAdministration;
  Immunization: r4.Immunization;
  AllergyIntolerance: r4.AllergyIntolerance;
  DiagnosticReport: r4.DiagnosticReport;
  DocumentReference: r4.DocumentReference;
  CarePlan: r4.CarePlan;
  CareTeam: r4.CareTeam;
  Goal: r4.Goal;
  Device: r4.Device;
  ImagingStudy: r4.ImagingStudy;
  SupplyDelivery: r4.SupplyDelivery;
  Coverage: r4.Coverage;
  Claim: r4.Claim;
  ExplanationOfBenefit: r4.ExplanationOfBenefit;
  Provenance: r4.Provenance;
}

export type ResourceOf<T extends ResourceType> = ResourceMap[T];
export type AnyResource = ResourceMap[ResourceType];

export function isResourceType(value: string): value is ResourceType {
  return Object.prototype.hasOwnProperty.call(TABLE_NAMES, value);
}

/** Table backing a supported resource type. */
export function tableNameFor<T extends ResourceType>(type: T): (typeof TABLE_NAMES)[T] {
  return TABLE_NAMES[type];
}

/** Same rule as fhir.table_name() in SQL, for resource types added with fhir.define_resource(). */
export function toTableName(resourceType: string): string {
  return resourceType.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
}
