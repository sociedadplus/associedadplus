-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 01 — Extensions and schemas
-- File: 20260803111500_create_extensions_and_schemas.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Infrastructure schema used by PostgreSQL/Supabase extensions
-- ---------------------------------------------------------------------------

create schema if not exists extensions;

-- UUID generation and cryptographic primitives.
create extension if not exists pgcrypto
  with schema extensions;

-- Required for exclusion constraints that combine scalar keys with ranges.
create extension if not exists btree_gist
  with schema extensions;

-- ---------------------------------------------------------------------------
-- 2. Application schemas
-- ---------------------------------------------------------------------------

-- Exposable application schema:
-- tables, enums, views and ordinary application functions.
create schema if not exists app;

comment on schema app is
  'AssociedadPlus application schema: domain types, tables, views and exposed application functions.';

-- Non-exposed application schema:
-- SECURITY DEFINER helpers, internal authorization functions and private
-- transactional implementation details.
create schema if not exists app_private;

comment on schema app_private is
  'AssociedadPlus private schema: internal helpers and SECURITY DEFINER functions; must not be exposed through the Data API.';

commit;
