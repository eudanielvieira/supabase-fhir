#!/usr/bin/env ruby
# frozen_string_literal: true

# A minimal supabase-fhir client in Ruby, standard library only (net/http + json).
#
#   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... ruby examples/ruby/example.rb
#
# Signs in as the demo clinician, lists the patients this user may see, reads one (audited),
# searches vital signs and shows how errors carry a FHIR OperationOutcome. In Rails the Client
# becomes a service object; for typed resources use the fhir_models gem.

require "json"
require "net/http"
require "uri"

# What PostgREST returns for failed requests, with the OperationOutcome when present.
class FhirError < StandardError
  attr_reader :status, :code, :outcome

  def initialize(status, body)
    @status = status
    @code = body["code"]
    details = body["details"]
    parsed = details.is_a?(String) ? (JSON.parse(details) rescue nil) : nil
    @outcome = parsed if parsed.is_a?(Hash) && parsed["resourceType"] == "OperationOutcome"
    super("#{status} #{@code}: #{body['message']}")
  end
end

class Client
  def initialize(base_url, api_key)
    @base_url = base_url.chomp("/")
    @api_key = api_key
    @token = nil
  end

  # Exchanges email and password for a JWT (Supabase Auth password grant).
  def login(email, password)
    session = request(:post, "/auth/v1/token?grant_type=password", { email: email, password: password })
    @token = session["access_token"]
  end

  # Calls a function in the fhir schema: read_resource, create_resource, import_bundle, ...
  def rpc(name, args = {})
    request(:post, "/rest/v1/rpc/#{name}", args)
  end

  # Reads a table with PostgREST filters: observation?patient_id=eq.123&select=resource
  def query(table_and_params)
    request(:get, "/rest/v1/#{table_and_params}") || []
  end

  private

  def request(method, path, body = nil)
    uri = URI("#{@base_url}#{path}")
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
    req["apikey"] = @api_key
    req["Content-Type"] = "application/json"
    req[method == :get ? "Accept-Profile" : "Content-Profile"] = "fhir"
    req["Authorization"] = "Bearer #{@token}" if @token
    req.body = JSON.generate(body) if body

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    data = res.body.to_s.empty? ? nil : JSON.parse(res.body)
    raise FhirError.new(res.code.to_i, data || {}) if res.code.to_i >= 400

    data
  end
end

api_key = ENV.fetch("SUPABASE_ANON_KEY", "")
if api_key.empty?
  warn "SUPABASE_ANON_KEY is required"
  exit 1
end

client = Client.new(ENV.fetch("SUPABASE_URL", "http://127.0.0.1:54321"), api_key)
client.login(ENV.fetch("FHIR_EMAIL", "clinician@example.com"), ENV.fetch("FHIR_PASSWORD", "supabase-fhir"))

patients = client.query("patient?select=id,family_name,birth_date&order=family_name")
puts "#{patients.size} patients visible to this user"
patients.each { |p| puts format("  %s  %-14s born %s", p["id"], p["family_name"], p["birth_date"]) }
exit 0 if patients.empty?
first = patients[0]["id"]

# Audited read: lands in fhir.audit_log with action = read.
patient = client.rpc("read_resource", resource_type: "Patient", id: first)
puts "\nread Patient/#{patient['id']} (version #{patient.dig('meta', 'versionId')})"

# Search on generated columns; RLS keeps it inside the compartments this user may see.
puts "\nlatest vital signs"
client.query("observation?patient_id=eq.#{first}&category_code=eq.vital-signs&select=resource&order=effective_at.desc&limit=5").each do |row|
  observation = row["resource"]
  label = observation.dig("code", "coding", 0, "display") || "?"
  quantity = observation["valueQuantity"]
  value = quantity ? "#{quantity['value']} #{quantity['unit']}" : ""
  puts format("  %s  %-40s %s", observation["effectiveDateTime"], label, value)
end

# Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
begin
  client.rpc("read_resource", resource_type: "Patient", id: "does-not-exist")
rescue FhirError => e
  puts "\nexpected failure: #{e.message}\n  OperationOutcome: #{JSON.generate(e.outcome)}"
end
