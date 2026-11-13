import type { OperationOutcome } from 'fhir/r4';

export type FhirErrorStatus = 400 | 403 | 404 | 409 | 500;

/** Error raised by the FHIR client. status follows HTTP semantics so callers can map it directly. */
export class FhirError extends Error {
  readonly status: FhirErrorStatus;
  readonly code: string | undefined;
  /** The OperationOutcome the database attached to the error, when there is one. */
  readonly outcome: OperationOutcome | undefined;

  constructor(
    status: FhirErrorStatus,
    message: string,
    code?: string,
    options?: { cause?: unknown; outcome?: OperationOutcome },
  ) {
    super(message, { cause: options?.cause });
    this.name = 'FhirError';
    this.status = status;
    this.code = code;
    this.outcome = options?.outcome;
  }

  get isNotFound(): boolean {
    return this.status === 404;
  }

  get isConflict(): boolean {
    return this.status === 409;
  }

  get isForbidden(): boolean {
    return this.status === 403;
  }
}

export interface PostgrestLikeError {
  code?: string | null;
  message: string;
  details?: string | null;
  hint?: string | null;
}

const STATUS_BY_CODE: Record<string, FhirErrorStatus> = {
  PT400: 400,
  PT404: 404,
  PT409: 409,
  '22023': 400,
  '23514': 400,
  '42501': 403,
  PGRST116: 404,
};

/** fhir.fail() puts an OperationOutcome in the error detail; PostgREST exposes it as `details`. */
export function parseOperationOutcome(details: string | null | undefined): OperationOutcome | undefined {
  if (!details) return undefined;
  try {
    const parsed: unknown = JSON.parse(details);
    if (parsed && typeof parsed === 'object' && (parsed as { resourceType?: string }).resourceType === 'OperationOutcome') {
      return parsed as OperationOutcome;
    }
  } catch {
    // details was plain text
  }
  return undefined;
}

/** Maps PostgREST / Postgres error codes raised by the fhir schema to a FhirError. */
export function fhirErrorFromPostgrest(error: PostgrestLikeError): FhirError {
  const code = error.code ?? undefined;
  const status = (code && STATUS_BY_CODE[code]) || 500;
  return new FhirError(status, error.message, code, { cause: error, outcome: parseOperationOutcome(error.details) });
}
