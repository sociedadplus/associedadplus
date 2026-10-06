-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 08 — Association operational settings
-- File: 20260803120800_create_association_operational_settings.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Association operational settings
-- ---------------------------------------------------------------------------
-- Exactly one settings row per association.
--
-- This table stores only presentation and operational preferences of the
-- tenant. It must not store statutory rules, mandates, quorum, notice periods,
-- holidays, registry requirements or legal-compliance conclusions.
--
-- Time zone validation against pg_timezone_names will be enforced later by a
-- controlled function/trigger, because PostgreSQL CHECK constraints cannot
-- safely depend on a mutable system catalog query.

create table app.association_operational_settings (
  association_id uuid not null,

  timezone_name text not null default 'America/Bahia',
  locale_code text not null default 'pt-BR',
  date_format app.date_format not null default 'DMY',

  use_24_hour_time boolean not null default true,
  week_starts_on smallint not null default 1,

  created_at timestamptz not null default now(),
  created_by uuid not null,

  updated_at timestamptz not null default now(),
  updated_by uuid not null,

  constraint association_operational_settings_pkey
    primary key (association_id),

  constraint association_operational_settings_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint association_operational_settings_created_by_fkey
    foreign key (created_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_operational_settings_updated_by_fkey
    foreign key (updated_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_operational_settings_timezone_name_check
    check (
      timezone_name = btrim(timezone_name)
      and char_length(timezone_name) between 1 and 100
      and timezone_name ~ '^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*$'
    ),

  constraint association_operational_settings_locale_code_check
    check (
      locale_code ~ '^[a-z]{2,3}(-[A-Z]{2})?$'
    ),

  constraint association_operational_settings_week_starts_on_check
    check (
      week_starts_on between 0 and 6
    ),

  constraint association_operational_settings_timestamp_order_check
    check (
      updated_at >= created_at
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.association_operational_settings is
  'One-to-one tenant settings row containing only operational and presentation preferences. Statutory rules and legal-compliance parameters belong to their own domain structures.';

comment on column app.association_operational_settings.association_id is
  'Association tenant whose operational preferences are represented. It is also the primary key, enforcing exactly one settings row per association.';

comment on column app.association_operational_settings.timezone_name is
  'IANA time-zone name used for tenant-local display and scheduling. The initial default is America/Bahia.';

comment on column app.association_operational_settings.locale_code is
  'Preferred tenant locale in a restricted BCP 47-like language or language-region format.';

comment on column app.association_operational_settings.date_format is
  'Preferred civil-date display order. It does not change how dates are stored in PostgreSQL.';

comment on column app.association_operational_settings.use_24_hour_time is
  'Whether user-facing times should use the 24-hour clock.';

comment on column app.association_operational_settings.week_starts_on is
  'First day of the displayed week, using 0 for Sunday through 6 for Saturday.';

comment on column app.association_operational_settings.created_at is
  'Instant at which the tenant settings row was created.';

comment on column app.association_operational_settings.created_by is
  'Global profile responsible for creating the tenant settings row.';

comment on column app.association_operational_settings.updated_at is
  'Instant of the latest controlled update to tenant operational preferences.';

comment on column app.association_operational_settings.updated_by is
  'Global profile responsible for the latest controlled update.';

-- ---------------------------------------------------------------------------
-- 3. Row Level Security
-- ---------------------------------------------------------------------------
-- The initial row will be created atomically by the later create_association
-- function. Direct client-side INSERT will not be required.
--
-- SELECT and UPDATE policies, grants, updated_at maintenance and strict IANA
-- time-zone validation are intentionally deferred to dedicated migrations.

alter table app.association_operational_settings enable row level security;

commit;
