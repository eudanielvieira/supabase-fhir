import { describe, expect, test } from 'bun:test';
import { compartmentPatientId, parseReference, referenceTo } from '../../src/domain/reference';

describe('parseReference', () => {
  test('parses relative references', () => {
    expect(parseReference('Patient/abc-1')).toEqual({ type: 'Patient', id: 'abc-1' });
  });

  test('parses absolute and versioned references', () => {
    expect(parseReference('https://fhir.example.org/r4/Encounter/e1/_history/3')).toEqual({
      type: 'Encounter',
      id: 'e1',
      version: '3',
    });
  });

  test('returns null for urn, conditional and empty references', () => {
    expect(parseReference('urn:uuid:7f6a1c4e-0000-4000-8000-000000000000')).toBeNull();
    expect(parseReference('Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|123')).toBeNull();
    expect(parseReference(undefined)).toBeNull();
    expect(parseReference('')).toBeNull();
  });

  test('referenceTo builds Type/id', () => {
    expect(referenceTo('Patient', 'p1')).toBe('Patient/p1');
  });
});

describe('compartmentPatientId', () => {
  test('a Patient is its own compartment', () => {
    expect(compartmentPatientId({ resourceType: 'Patient', id: 'p1' })).toBe('p1');
  });

  test('uses subject, patient or beneficiary', () => {
    expect(compartmentPatientId({ resourceType: 'Observation', status: 'final', code: {}, subject: { reference: 'Patient/p2' } })).toBe('p2');
    expect(compartmentPatientId({ resourceType: 'AllergyIntolerance', patient: { reference: 'Patient/p3' } })).toBe('p3');
    expect(compartmentPatientId({ resourceType: 'Coverage', status: 'active', beneficiary: { reference: 'Patient/p4' }, payor: [] })).toBe('p4');
  });

  test('uses the first Patient target for Provenance', () => {
    expect(
      compartmentPatientId({
        resourceType: 'Provenance',
        target: [{ reference: 'Encounter/e1' }, { reference: 'Patient/p5' }],
        recorded: '2024-01-01T00:00:00Z',
        agent: [],
      }),
    ).toBe('p5');
  });

  test('returns null when the subject is not a Patient', () => {
    expect(compartmentPatientId({ resourceType: 'Observation', status: 'final', code: {}, subject: { reference: 'Group/g1' } })).toBeNull();
    expect(compartmentPatientId({ resourceType: 'Organization' })).toBeNull();
  });
});
