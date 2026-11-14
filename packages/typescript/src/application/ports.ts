import type * as r4 from 'fhir/r4';
import type { AnyResource, ResourceOf, ResourceType } from '../domain/resource-types';

export interface HistoryEntry<R> {
  versionId: number;
  resource: R;
  lastUpdated: string;
  operation: 'current' | 'update' | 'delete';
}

export interface UpdateOptions {
  /** Current version the caller expects (FHIR If-Match). Mismatch raises a 409 FhirError. */
  expectedVersion?: number;
}

/** Options for search(). Every search is audited as one event with its filters and result count. */
export interface SearchOptions {
  /** Restrict to one Patient compartment. */
  patientId?: string;
  /** Equality filters on the table's scalar columns (generated search columns included). */
  where?: Record<string, string | number | boolean | null>;
  /** 1 to 1000, default 100. */
  limit?: number;
  offset?: number;
  /** Order by last_updated. Defaults to 'desc'. */
  order?: 'asc' | 'desc';
}

/** What any FHIR storage adapter must offer. The Supabase implementation lives in infrastructure/. */
export interface FhirRepository {
  read<T extends ResourceType>(type: T, id: string): Promise<ResourceOf<T>>;
  create<R extends AnyResource>(resource: R): Promise<R>;
  update<R extends AnyResource>(resource: R, options?: UpdateOptions): Promise<R>;
  remove(type: ResourceType, id: string): Promise<void>;
  history<T extends ResourceType>(type: T, id: string): Promise<HistoryEntry<ResourceOf<T>>[]>;
  search<T extends ResourceType>(type: T, options?: SearchOptions): Promise<ResourceOf<T>[]>;
  everything(patientId: string): Promise<r4.Bundle>;
  importBundle(bundle: r4.Bundle): Promise<r4.Bundle>;
}
