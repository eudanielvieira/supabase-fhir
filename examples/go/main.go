// A minimal supabase-fhir client in Go, standard library only.
//
//	SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... go run .
//
// Signs in as the demo clinician, lists the patients this user may see, reads one
// (audited), searches vital signs and shows how errors carry a FHIR OperationOutcome.
// Pair it with a FHIR model library (for example github.com/samply/golang-fhir-models)
// to unmarshal resources into typed structs.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
)

// Client talks to PostgREST and GoTrue with the fhir schema selected.
type Client struct {
	BaseURL string
	APIKey  string
	Token   string
	HTTP    *http.Client
}

// Error is what PostgREST returns for failed requests; Outcome holds the FHIR OperationOutcome
// when the database attached one (not found, conflict, forbidden, invalid input).
type Error struct {
	Status  int
	Code    string          `json:"code"`
	Message string          `json:"message"`
	Details string          `json:"details"`
	Outcome json.RawMessage `json:"-"`
}

func (e *Error) Error() string {
	return fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message)
}

func (c *Client) do(method, path string, body, out any) error {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		payload = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, c.BaseURL+path, payload)
	if err != nil {
		return err
	}
	req.Header.Set("apikey", c.APIKey)
	req.Header.Set("Content-Type", "application/json")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	if method == http.MethodGet {
		req.Header.Set("Accept-Profile", "fhir")
	} else {
		req.Header.Set("Content-Profile", "fhir")
	}

	res, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}
	if res.StatusCode >= 400 {
		apiErr := &Error{Status: res.StatusCode}
		_ = json.Unmarshal(raw, apiErr)
		if json.Valid([]byte(apiErr.Details)) {
			apiErr.Outcome = json.RawMessage(apiErr.Details)
		}
		return apiErr
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

// Login exchanges email and password for a JWT (Supabase Auth password grant).
func (c *Client) Login(email, password string) error {
	var session struct {
		AccessToken string `json:"access_token"`
	}
	err := c.do(http.MethodPost, "/auth/v1/token?grant_type=password",
		map[string]string{"email": email, "password": password}, &session)
	if err != nil {
		return err
	}
	c.Token = session.AccessToken
	return nil
}

// RPC calls a function in the fhir schema: read_resource, create_resource, import_bundle, ...
func (c *Client) RPC(name string, args, out any) error {
	return c.do(http.MethodPost, "/rest/v1/rpc/"+name, args, out)
}

// Query reads a table with PostgREST filters, for example
// "observation?patient_id=eq.123&code=eq.8302-2&select=resource".
func (c *Client) Query(tableAndParams string, out any) error {
	return c.do(http.MethodGet, "/rest/v1/"+tableAndParams, nil, out)
}

type patientRow struct {
	ID        string `json:"id"`
	Family    string `json:"family_name"`
	BirthDate string `json:"birth_date"`
}

type observation struct {
	Code struct {
		Coding []struct {
			Code    string `json:"code"`
			Display string `json:"display"`
		} `json:"coding"`
	} `json:"code"`
	EffectiveDateTime string `json:"effectiveDateTime"`
	ValueQuantity     *struct {
		Value float64 `json:"value"`
		Unit  string  `json:"unit"`
	} `json:"valueQuantity"`
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	client := &Client{
		BaseURL: env("SUPABASE_URL", "http://127.0.0.1:54321"),
		APIKey:  os.Getenv("SUPABASE_ANON_KEY"),
		HTTP:    http.DefaultClient,
	}
	if client.APIKey == "" {
		fmt.Fprintln(os.Stderr, "SUPABASE_ANON_KEY is required")
		os.Exit(1)
	}

	if err := client.Login(env("FHIR_EMAIL", "clinician@example.com"), env("FHIR_PASSWORD", "supabase-fhir")); err != nil {
		fmt.Fprintln(os.Stderr, "login failed:", err)
		os.Exit(1)
	}

	var patients []patientRow
	if err := client.Query("patient?select=id,family_name,birth_date&order=family_name", &patients); err != nil {
		fmt.Fprintln(os.Stderr, "list patients:", err)
		os.Exit(1)
	}
	fmt.Printf("%d patients visible to this user\n", len(patients))
	for _, p := range patients {
		fmt.Printf("  %s  %-14s born %s\n", p.ID, p.Family, p.BirthDate)
	}
	if len(patients) == 0 {
		return
	}

	// Audited read through the RPC; the row lands in fhir.audit_log with action = read.
	var patient map[string]any
	if err := client.RPC("read_resource", map[string]string{"resource_type": "Patient", "id": patients[0].ID}, &patient); err != nil {
		fmt.Fprintln(os.Stderr, "read patient:", err)
		os.Exit(1)
	}
	fmt.Printf("\nread Patient/%s (version %v)\n", patient["id"], patient["meta"].(map[string]any)["versionId"])

	// Search on generated columns; RLS keeps it inside the compartments this user may see.
	var vitals []struct {
		Resource observation `json:"resource"`
	}
	params := "observation?patient_id=eq." + patients[0].ID + "&category_code=eq.vital-signs&select=resource&order=effective_at.desc&limit=5"
	if err := client.Query(params, &vitals); err != nil {
		fmt.Fprintln(os.Stderr, "search observations:", err)
		os.Exit(1)
	}
	fmt.Printf("\nlatest vital signs\n")
	for _, v := range vitals {
		o := v.Resource
		label := "?"
		if len(o.Code.Coding) > 0 {
			label = o.Code.Coding[0].Display
		}
		if o.ValueQuantity != nil {
			fmt.Printf("  %s  %-40s %.1f %s\n", o.EffectiveDateTime, label, o.ValueQuantity.Value, o.ValueQuantity.Unit)
		} else {
			fmt.Printf("  %s  %s\n", o.EffectiveDateTime, label)
		}
	}

	// Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
	var missing map[string]any
	err := client.RPC("read_resource", map[string]string{"resource_type": "Patient", "id": "does-not-exist"}, &missing)
	var apiErr *Error
	if errors.As(err, &apiErr) {
		fmt.Printf("\nexpected failure: %v\n  OperationOutcome: %s\n", apiErr, apiErr.Outcome)
	}
}
