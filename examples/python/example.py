"""A minimal supabase-fhir client in Python, standard library only.

    SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... python3 examples/python/example.py

Signs in as the demo clinician, lists the patients this user may see, reads one (audited),
searches vital signs and shows how errors carry a FHIR OperationOutcome. Pair it with
`fhir.resources` (pip) to parse resources into typed models.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


class FhirError(Exception):
    """What PostgREST returns for failed requests, with the OperationOutcome when present."""

    def __init__(self, status: int, body: dict[str, Any]):
        self.status = status
        self.code = body.get("code")
        self.message = body.get("message")
        self.outcome: dict[str, Any] | None = None
        details = body.get("details")
        if isinstance(details, str):
            try:
                parsed = json.loads(details)
                if isinstance(parsed, dict) and parsed.get("resourceType") == "OperationOutcome":
                    self.outcome = parsed
            except ValueError:
                pass
        super().__init__(f"{status} {self.code}: {self.message}")


class Client:
    def __init__(self, base_url: str, api_key: str):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.token: str | None = None

    def _request(self, method: str, path: str, body: Any = None) -> Any:
        headers = {"apikey": self.api_key, "Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        headers["Accept-Profile" if method == "GET" else "Content-Profile"] = "fhir"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            try:
                payload = json.loads(error.read() or b"{}")
            except ValueError:
                payload = {}
            raise FhirError(error.code, payload) from None

    def login(self, email: str, password: str) -> None:
        session = self._request("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})
        self.token = session["access_token"]

    def rpc(self, name: str, **args: Any) -> Any:
        """Call a function in the fhir schema: read_resource, create_resource, import_bundle, ..."""
        return self._request("POST", f"/rest/v1/rpc/{name}", args)

    def query(self, table_and_params: str) -> list[dict[str, Any]]:
        """Read a table with PostgREST filters: observation?patient_id=eq.123&select=resource"""
        return self._request("GET", f"/rest/v1/{table_and_params}")


def main() -> int:
    api_key = os.environ.get("SUPABASE_ANON_KEY")
    if not api_key:
        print("SUPABASE_ANON_KEY is required", file=sys.stderr)
        return 1
    client = Client(os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321"), api_key)
    client.login(os.environ.get("FHIR_EMAIL", "clinician@example.com"), os.environ.get("FHIR_PASSWORD", "supabase-fhir"))

    patients = client.query("patient?select=id,family_name,birth_date&order=family_name")
    print(f"{len(patients)} patients visible to this user")
    for patient in patients:
        print(f"  {patient['id']}  {patient['family_name']:<14} born {patient['birth_date']}")
    if not patients:
        return 0

    # Audited read: lands in fhir.audit_log with action = read.
    patient = client.rpc("read_resource", resource_type="Patient", id=patients[0]["id"])
    print(f"\nread Patient/{patient['id']} (version {patient['meta']['versionId']})")

    # Search on generated columns; RLS keeps it inside the compartments this user may see.
    params = (
        f"observation?patient_id=eq.{patients[0]['id']}&category_code=eq.vital-signs"
        "&select=resource&order=effective_at.desc&limit=5"
    )
    print("\nlatest vital signs")
    for row in client.query(params):
        resource = row["resource"]
        label = (resource.get("code", {}).get("coding") or [{}])[0].get("display", "?")
        quantity = resource.get("valueQuantity")
        value = f"{quantity['value']} {quantity.get('unit', '')}" if quantity else ""
        print(f"  {resource.get('effectiveDateTime')}  {label:<40} {value}")

    # Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
    try:
        client.rpc("read_resource", resource_type="Patient", id="does-not-exist")
    except FhirError as error:
        print(f"\nexpected failure: {error}\n  OperationOutcome: {json.dumps(error.outcome)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
