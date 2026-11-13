import { describe, expect, test } from 'bun:test';
import { FhirError, fhirErrorFromPostgrest } from '../../src/domain/errors';

describe('fhirErrorFromPostgrest', () => {
  test.each([
    ['PT400', 400],
    ['PT404', 404],
    ['PT409', 409],
    ['42501', 403],
    ['23514', 400],
    ['PGRST116', 404],
    ['XX000', 500],
    [null, 500],
  ])('maps code %s to status %i', (code, status) => {
    const error = fhirErrorFromPostgrest({ code, message: 'boom' });
    expect(error).toBeInstanceOf(FhirError);
    expect<number>(error.status).toBe(status);
    expect(error.message).toBe('boom');
  });

  test('exposes convenience flags', () => {
    expect(fhirErrorFromPostgrest({ code: 'PT404', message: 'x' }).isNotFound).toBe(true);
    expect(fhirErrorFromPostgrest({ code: 'PT409', message: 'x' }).isConflict).toBe(true);
    expect(fhirErrorFromPostgrest({ code: '42501', message: 'x' }).isForbidden).toBe(true);
  });
});
