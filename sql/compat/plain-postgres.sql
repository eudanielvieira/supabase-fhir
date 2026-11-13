-- =============================================================================
-- supabase-fhir | compatibility layer for Postgres without Supabase
--
-- The migrations rely on three things Supabase provides out of the box:
--   * the roles anon, authenticated and service_role (plus authenticator for PostgREST)
--   * the auth schema with auth.uid(), auth.jwt() and auth.role(), which read the JWT
--     claims PostgREST publishes as the request.jwt.claims setting
--   * an auth.users table that fhir.patient_access references
--
-- Run this file once, as a superuser, on any Postgres 15+ before the migrations.
-- Then either put PostgREST in front (db-schemas = fhir, db-anon-role = anon,
-- jwt-secret = <your secret>) or set the claims yourself from your backend:
--
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<user uuid>","role":"authenticated"}', true);
--
-- Do not run this on Supabase: everything here already exists there.
-- The seeds in supabase/seeds/ are Supabase specific (demo logins); load data with
-- fhir.import_bundle() instead.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'change-me';
  end if;
end;
$$;

-- PostgREST switches from authenticator to the role named in the JWT.
grant anon, authenticated, service_role to authenticator;
-- The migration owner can impersonate the roles (pgTAP tests do that).
grant anon, authenticated, service_role to current_user;

create schema if not exists auth;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Minimal stand-in for Supabase's auth.users. Map it to your own user table if you prefer:
-- the only hard requirement is a uuid primary key that fhir.patient_access can reference.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  raw_app_meta_data  jsonb not null default '{}'::jsonb,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

create or replace function auth.jwt()
returns jsonb
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb;
$$;

create or replace function auth.role()
returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  );
$$;

grant usage on schema auth, extensions to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
