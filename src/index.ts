export { createFhirClient } from './infrastructure/supabase/fhir-client';
export type { FhirClient, FhirSchemaClient, ResourceQuery } from './infrastructure/supabase/fhir-client';
export type {
  AccessLevel,
  AuditAction,
  AuditLogRow,
  Database,
  FhirDatabase,
  FhirFunctions,
  FhirSchema,
  HistoryRow,
  Json,
  PatientAccessInsert,
  PatientAccessRow,
  ResourceHistoryRow,
  ResourceInsert,
  ResourceRow,
  ResourceTables,
  ResourceTypeRow,
  ResourceUpdate,
  SearchColumns,
} from './infrastructure/supabase/database.types';
export type { FhirRepository, HistoryEntry, SearchOptions, UpdateOptions } from './application/ports';
export { FhirError, fhirErrorFromPostgrest } from './domain/errors';
export type { FhirErrorStatus, PostgrestLikeError } from './domain/errors';
export { compartmentPatientId, parseReference, referenceTo } from './domain/reference';
export type { ParsedReference } from './domain/reference';
export { RESOURCE_TYPES, TABLE_NAMES, isResourceType, tableNameFor, toTableName } from './domain/resource-types';
export type { AnyResource, ResourceMap, ResourceOf, ResourceType, TableName } from './domain/resource-types';
