import type { SupabaseClient } from '@supabase/supabase-js';
import type * as r4 from 'fhir/r4';
import type { FhirRepository, HistoryEntry, SearchOptions, UpdateOptions } from '../../application/ports';
import { fhirErrorFromPostgrest } from '../../domain/errors';
import { tableNameFor, type AnyResource, type ResourceOf, type ResourceType } from '../../domain/resource-types';
import type { FhirDatabase, FhirFunctions, Json } from './database.types';

/** PostgREST client scoped to the fhir schema, fully typed. */
export type FhirSchemaClient = ReturnType<SupabaseClient<FhirDatabase>['schema']>;

function fromTyped<T extends ResourceType>(schema: FhirSchemaClient, type: T) {
  return schema.from(tableNameFor(type));
}

/** Query builder for one resource table. */
export type ResourceQuery<T extends ResourceType> = ReturnType<typeof fromTyped<T>>;

export interface FhirClient extends FhirRepository {
  /** Raw typed access to the fhir schema for anything the helpers do not cover. */
  readonly schema: FhirSchemaClient;
  /** Typed query builder for a resource table: from('Observation').select('resource').eq('code', '8302-2').
   *  Rows read this way are not audited; call logAccess() for the ones you show. */
  from<T extends ResourceType>(type: T): ResourceQuery<T>;
  /** Records a read of a resource you fetched through from(). The database checks the access again. */
  logAccess(type: ResourceType, id: string): Promise<void>;
}

/**
 * Wraps a supabase-js client with FHIR operations. Every call goes through PostgREST
 * as the signed-in user, so row level security always applies. read(), everything() and
 * search() are audited by the database; from() is raw table access and is not.
 *
 *   const supabase = createClient<Database>(url, anonKey);
 *   const fhir = createFhirClient(supabase);
 *   const patient = await fhir.read('Patient', id);
 */
export function createFhirClient<DB extends FhirDatabase>(supabase: SupabaseClient<DB>): FhirClient {
  const schema = (supabase as unknown as SupabaseClient<FhirDatabase>).schema('fhir');

  async function call<Name extends keyof FhirFunctions>(
    name: Name,
    args: FhirFunctions[Name]['Args'],
  ): Promise<FhirFunctions[Name]['Returns']> {
    const { data, error } = await schema.rpc(name, args);
    if (error) throw fhirErrorFromPostgrest(error);
    return data as FhirFunctions[Name]['Returns'];
  }

  return {
    schema,

    from<T extends ResourceType>(type: T): ResourceQuery<T> {
      return fromTyped(schema, type);
    },

    async read<T extends ResourceType>(type: T, id: string): Promise<ResourceOf<T>> {
      const data = await call('read_resource', { resource_type: type, id });
      return data as unknown as ResourceOf<T>;
    },

    async create<R extends AnyResource>(resource: R): Promise<R> {
      const data = await call('create_resource', { resource: resource as unknown as Json });
      return data as unknown as R;
    },

    async update<R extends AnyResource>(resource: R, options: UpdateOptions = {}): Promise<R> {
      const args: FhirFunctions['update_resource']['Args'] = { resource: resource as unknown as Json };
      if (options.expectedVersion !== undefined) args.expected_version = options.expectedVersion;
      const data = await call('update_resource', args);
      return data as unknown as R;
    },

    async remove(type: ResourceType, id: string): Promise<void> {
      await call('delete_resource', { resource_type: type, id });
    },

    async history<T extends ResourceType>(type: T, id: string): Promise<HistoryEntry<ResourceOf<T>>[]> {
      const rows = await call('history', { resource_type: type, id });
      return rows.map((row) => ({
        versionId: row.version_id,
        resource: row.resource as unknown as ResourceOf<T>,
        lastUpdated: row.last_updated,
        operation: row.operation as HistoryEntry<ResourceOf<T>>['operation'],
      }));
    },

    async search<T extends ResourceType>(type: T, options: SearchOptions = {}): Promise<ResourceOf<T>[]> {
      const args: FhirFunctions['search_resources']['Args'] = { resource_type: type };
      if (options.patientId) args.patient_id = options.patientId;
      if (options.where) args.filters = options.where as Json;
      if (options.limit !== undefined) args.max_results = options.limit;
      if (options.offset !== undefined) args.skip = options.offset;
      if (options.order) args.newest_first = options.order !== 'asc';
      const rows = await call('search_resources', args);
      return rows as unknown as ResourceOf<T>[];
    },

    async logAccess(type: ResourceType, id: string): Promise<void> {
      await call('log_access', { resource_type: type, resource_id: id });
    },

    async everything(patientId: string): Promise<r4.Bundle> {
      const data = await call('patient_everything', { patient_id: patientId });
      return data as unknown as r4.Bundle;
    },

    async importBundle(bundle: r4.Bundle): Promise<r4.Bundle> {
      const data = await call('import_bundle', { bundle: bundle as unknown as Json });
      return data as unknown as r4.Bundle;
    },
  };
}
