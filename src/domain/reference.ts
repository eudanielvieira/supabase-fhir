import type * as r4 from 'fhir/r4';

export interface ParsedReference {
  type: string;
  id: string;
  version?: string;
}

const REFERENCE_PATTERN = /(?:^|\/)([A-Z][A-Za-z]+)\/([A-Za-z0-9\-.]{1,64})(?:\/_history\/([^/]+))?$/;

/**
 * Parses 'Patient/123', 'https://host/fhir/Patient/123' or 'Patient/123/_history/2'.
 * Returns null for urn:uuid, conditional (Type?identifier=...) and logical references.
 */
export function parseReference(reference: string | undefined | null): ParsedReference | null {
  if (!reference || reference.startsWith('urn:') || reference.includes('?')) return null;
  const match = REFERENCE_PATTERN.exec(reference);
  if (!match) return null;
  const [, type, id, version] = match;
  return version ? { type: type!, id: id!, version } : { type: type!, id: id! };
}

export function referenceTo(type: string, id: string): string {
  return `${type}/${id}`;
}

function patientIdFrom(reference: r4.Reference | undefined): string | null {
  const parsed = parseReference(reference?.reference);
  return parsed?.type === 'Patient' ? parsed.id : null;
}

/**
 * The Patient compartment a resource belongs to. Mirrors fhir.compartment_patient_id() in SQL:
 * Patient -> its own id; otherwise subject, patient, beneficiary or the first Patient target.
 */
export function compartmentPatientId(resource: r4.FhirResource): string | null {
  if (resource.resourceType === 'Patient') return resource.id ?? null;
  const candidate = resource as {
    subject?: r4.Reference;
    patient?: r4.Reference;
    beneficiary?: r4.Reference;
    target?: r4.Reference[];
  };
  return (
    patientIdFrom(candidate.subject) ??
    patientIdFrom(candidate.patient) ??
    patientIdFrom(candidate.beneficiary) ??
    candidate.target?.map(patientIdFrom).find((id) => id !== null) ??
    null
  );
}
