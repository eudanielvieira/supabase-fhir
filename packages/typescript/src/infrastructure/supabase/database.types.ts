import type { ResourceMap, ResourceType, TABLE_NAMES } from '../../domain/resource-types';

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

/** Columns every resource table shares (see fhir.define_resource). */
export interface ResourceRow<R> {
  id: string;
  version_id: number;
  last_updated: string;
  resource: R;
  patient_id: string | null;
  created_at: string;
  created_by: string | null;
  updated_by: string | null;
}

export interface ResourceInsert<R> {
  id?: string;
  version_id?: number;
  last_updated?: string;
  resource: R;
  created_at?: string;
  created_by?: string | null;
  updated_by?: string | null;
}

export type ResourceUpdate<R> = Partial<ResourceInsert<R>>;

/** Generated search columns, per table (see supabase/migrations/*_fhir_resources.sql). */
export interface SearchColumns {
  patient: { family_name: string | null; birth_date: string | null; gender: string | null; active: boolean | null };
  practitioner: { family_name: string | null };
  organization: { name: string | null };
  location: { name: string | null };
  encounter: {
    status: string | null;
    class_code: string | null;
    type_code: string | null;
    period_start: string | null;
    period_end: string | null;
  };
  condition: {
    clinical_status: string | null;
    verification_status: string | null;
    code: string | null;
    code_system: string | null;
    onset_at: string | null;
    abatement_at: string | null;
    encounter_id: string | null;
  };
  observation: {
    status: string | null;
    category_code: string | null;
    code: string | null;
    code_system: string | null;
    effective_at: string | null;
    value_quantity: number | null;
    value_unit: string | null;
    encounter_id: string | null;
  };
  procedure: { status: string | null; code: string | null; performed_at: string | null; encounter_id: string | null };
  medication_request: {
    status: string | null;
    intent: string | null;
    medication_code: string | null;
    authored_on: string | null;
    encounter_id: string | null;
  };
  medication_administration: { status: string | null; medication_code: string | null; effective_at: string | null };
  immunization: { status: string | null; vaccine_code: string | null; occurrence_at: string | null; encounter_id: string | null };
  allergy_intolerance: {
    clinical_status: string | null;
    code: string | null;
    category: string | null;
    criticality: string | null;
    recorded_at: string | null;
  };
  diagnostic_report: { status: string | null; code: string | null; effective_at: string | null; encounter_id: string | null };
  document_reference: { status: string | null; type_code: string | null; document_date: string | null; encounter_id: string | null };
  care_plan: { status: string | null; intent: string | null; period_start: string | null; encounter_id: string | null };
  care_team: { status: string | null; encounter_id: string | null };
  goal: { lifecycle_status: string | null };
  coverage: { status: string | null };
  claim: { status: string | null; use: string | null };
  explanation_of_benefit: { status: string | null };
}

type TableNames = typeof TABLE_NAMES;
type ExtraColumns<N extends string> = N extends keyof SearchColumns ? SearchColumns[N] : Record<never, never>;

/** One typed table per resource type: supabase.schema('fhir').from('observation') knows its Row. */
export type ResourceTables = {
  [K in ResourceType as TableNames[K]]: {
    Row: ResourceRow<ResourceMap[K]> & ExtraColumns<TableNames[K]>;
    Insert: ResourceInsert<ResourceMap[K]>;
    Update: ResourceUpdate<ResourceMap[K]>;
    Relationships: [];
  };
};

export type AccessLevel = 'read' | 'write';
export type AuditAction = 'create' | 'read' | 'update' | 'delete' | 'search' | 'grant' | 'grant_change' | 'revoke';

export interface PatientAccessRow {
  id: number;
  user_id: string;
  patient_id: string;
  access_level: AccessLevel;
  valid_from: string;
  valid_until: string | null;
  granted_by: string | null;
  reason: string | null;
  created_at: string;
}

export interface PatientAccessInsert {
  user_id: string;
  patient_id: string;
  access_level?: AccessLevel;
  valid_from?: string;
  valid_until?: string | null;
  granted_by?: string | null;
  reason?: string | null;
}

export interface AuditLogRow {
  id: number;
  occurred_at: string;
  action: AuditAction;
  resource_type: string;
  resource_id: string | null;
  patient_id: string | null;
  version_id: number | null;
  actor_id: string | null;
  actor_role: string | null;
  request: Json | null;
}

export interface ResourceHistoryRow {
  history_id: number;
  resource_type: string;
  id: string;
  version_id: number;
  resource: Json;
  patient_id: string | null;
  last_updated: string;
  updated_by: string | null;
  operation: 'update' | 'delete';
  recorded_at: string;
}

export interface ResourceTypeRow {
  resource_type: string;
  table_name: string;
  compartment: boolean;
  created_at: string;
}

export interface HistoryRow {
  version_id: number;
  resource: Json;
  last_updated: string;
  operation: string;
}

export interface FhirFunctions {
  read_resource: { Args: { resource_type: string; id: string }; Returns: Json };
  create_resource: { Args: { resource: Json }; Returns: Json };
  update_resource: { Args: { resource: Json; expected_version?: number }; Returns: Json };
  delete_resource: { Args: { resource_type: string; id: string }; Returns: undefined };
  history: { Args: { resource_type: string; id: string }; Returns: HistoryRow[] };
  patient_everything: { Args: { patient_id: string }; Returns: Json };
  import_bundle: { Args: { bundle: Json }; Returns: Json };
  search_resources: {
    Args: {
      resource_type: string;
      patient_id?: string | null;
      filters?: Json;
      max_results?: number;
      skip?: number;
      newest_first?: boolean;
    };
    Returns: Json[];
  };
  log_access: { Args: { resource_type: string; resource_id: string }; Returns: undefined };
  has_patient_access: { Args: { patient_id: string; level?: string }; Returns: boolean };
  is_admin: { Args: Record<string, never>; Returns: boolean };
  define_resource: { Args: { p_resource_type: string; p_compartment?: boolean }; Returns: string };
}

export interface FhirSchema {
  Tables: ResourceTables & {
    patient_access: {
      Row: PatientAccessRow;
      Insert: PatientAccessInsert;
      Update: Partial<PatientAccessInsert>;
      Relationships: [];
    };
    audit_log: { Row: AuditLogRow; Insert: never; Update: never; Relationships: [] };
    resource_history: { Row: ResourceHistoryRow; Insert: never; Update: never; Relationships: [] };
    resource_type: { Row: ResourceTypeRow; Insert: never; Update: never; Relationships: [] };
  };
  Views: { [_ in never]: never };
  Functions: FhirFunctions;
  Enums: { [_ in never]: never };
  CompositeTypes: { [_ in never]: never };
}

/**
 * Database type for supabase-js. Merge it with your own:
 *   type Database = MyPublicDatabase & FhirDatabase;
 */
export interface FhirDatabase {
  fhir: FhirSchema;
}

export type Database = FhirDatabase;
