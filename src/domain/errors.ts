export type FhirErrorStatus = 400 | 403 | 404 | 409 | 500;

/** Error raised by the FHIR client. status follows HTTP semantics so callers can map it directly. */
export class FhirError extends Error {
  readonly status: FhirErrorStatus;
  readonly code: string | undefined;

  constructor(status: FhirErrorStatus, message: string, code?: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = 'FhirError';
    this.status = status;
    this.code = code;
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

/** Maps PostgREST / Postgres error codes raised by the fhir schema to a FhirError. */
export function fhirErrorFromPostgrest(error: PostgrestLikeError): FhirError {
  const code = error.code ?? undefined;
  const status = (code && STATUS_BY_CODE[code]) || 500;
  return new FhirError(status, error.message, code, { cause: error });
}
