import { describe, expect, test } from 'bun:test';
import { RESOURCE_TYPES, TABLE_NAMES, isResourceType, tableNameFor, toTableName } from '../../src/domain/resource-types';

describe('resource types', () => {
  test('ships 26 resource types', () => {
    expect(RESOURCE_TYPES).toHaveLength(26);
  });

  test('tableNameFor returns the snake_case table', () => {
    expect(tableNameFor('Patient')).toBe('patient');
    expect(tableNameFor('MedicationRequest')).toBe('medication_request');
    expect(tableNameFor('ExplanationOfBenefit')).toBe('explanation_of_benefit');
  });

  test('every table name follows the SQL fhir.table_name() rule', () => {
    for (const type of RESOURCE_TYPES) {
      expect<string>(TABLE_NAMES[type]).toBe(toTableName(type));
    }
  });

  test('toTableName mirrors fhir.table_name() for custom types', () => {
    expect(toTableName('Specimen')).toBe('specimen');
    expect(toTableName('RiskAssessment')).toBe('risk_assessment');
    expect(toTableName('MedicinalProductIngredient')).toBe('medicinal_product_ingredient');
  });

  test('isResourceType narrows strings', () => {
    expect(isResourceType('Observation')).toBe(true);
    expect(isResourceType('Specimen')).toBe(false);
    expect(isResourceType('toString')).toBe(false);
  });
});
