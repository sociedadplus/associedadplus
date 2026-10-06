-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 03 — Profiles
-- File: 20260803113000_create_profiles.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Global platform profiles
-- ---------------------------------------------------------------------------
-- One row per Supabase Auth user.
--
-- This table stores only complementary technical identity data used by the
-- application. It is global, has no association_id and must not be confused
-- with association_people, association membership or institutional office.
--
-- Authentication email remains exclusively in auth.users and is intentionally
-- not duplicated here.

create table app.profiles (
  id uuid not null,

  display_name text not null,
  phone text,
  preferred_locale text not null default 'pt-BR',

  status app.profile_status not null default 'ACTIVE',
  deactivated_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_pkey
    primary key (id),

  constraint profiles_id_fkey
    foreign key (id)
    references auth.users (id)
    on update restrict
    on delete cascade,

  constraint profiles_display_name_length_check
    check (
      char_length(btrim(display_name)) between 2 and 120
    ),

  constraint profiles_phone_check
    check (
      phone is null
      or char_length(btrim(phone)) between 8 and 32
    ),

  constraint profiles_preferred_locale_check
    check (
      preferred_locale ~ '^[a-z]{2,3}(-[A-Z]{2})?$'
    ),

  constraint profiles_deactivation_consistency_check
    check (
      (
        status = 'DEACTIVATED'
        and deactivated_at is not null
      )
      or
      (
        status <> 'DEACTIVATED'
        and deactivated_at is null
      )
    ),

  constraint profiles_timestamp_order_check
    check (
      updated_at >= created_at
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.profiles is
  'Global one-to-one extension of auth.users containing complementary platform profile data. It does not represent a civil person, association member or institutional officeholder.';

comment on column app.profiles.id is
  'Primary key and foreign key to auth.users.id. The profile UUID is exactly the authenticated user UUID.';

comment on column app.profiles.display_name is
  'User-facing display name. It is not a legally qualified civil name and is not globally unique.';

comment on column app.profiles.phone is
  'Optional platform contact phone. It is not an institutional or civil-person contact record.';

comment on column app.profiles.preferred_locale is
  'Preferred interface locale in a restricted BCP 47-like language or language-region format, initially pt-BR.';

comment on column app.profiles.status is
  'Global technical status of the platform profile. Association-specific authorization remains in association_user_access.';

comment on column app.profiles.deactivated_at is
  'Instant at which the profile was technically deactivated; required only while status is DEACTIVATED.';

comment on column app.profiles.created_at is
  'Instant at which the complementary platform profile was created.';

comment on column app.profiles.updated_at is
  'Instant of the latest allowed profile update. A later trigger will maintain this value automatically.';

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

create index profiles_status_idx
  on app.profiles (status);

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- Policies are intentionally created in the dedicated RLS migration.
-- Until then, authenticated and anonymous Data API roles have no row access.

alter table app.profiles enable row level security;

commit;
