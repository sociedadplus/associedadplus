-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 06 — Association names
-- File: 20260803115300_create_association_names.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Institutional names
-- ---------------------------------------------------------------------------
-- Stores official names, usage names and acronyms in proposed, effective,
-- historical, rejected or withdrawn states.
--
-- The temporal source of truth for the current official name is this table.
-- app.associations.current_official_name is only a rebuildable projection.
--
-- valid_to is an exclusive civil-date bound:
-- [valid_from, valid_to)
--
-- Unknown dates remain NULL and are qualified by app.date_certainty. The
-- database must not invent a date merely to complete a historical period.

create table app.association_names (
  id uuid not null default extensions.gen_random_uuid(),
  association_id uuid not null,

  name_type app.association_name_type not null,
  name_value text not null,

  status app.association_name_status not null default 'PROPOSED',
  is_primary boolean not null default false,

  valid_from date,
  valid_from_certainty app.date_certainty not null default 'UNKNOWN',

  valid_to date,
  valid_to_certainty app.date_certainty not null default 'UNKNOWN',

  basis text,
  origin app.record_origin not null,

  created_at timestamptz not null default now(),
  created_by uuid not null,

  updated_at timestamptz not null default now(),
  updated_by uuid not null,

  constraint association_names_pkey
    primary key (id),

  -- Required so later institutional children may use tenant-safe composite FKs.
  constraint association_names_association_id_id_key
    unique (association_id, id),

  constraint association_names_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint association_names_created_by_fkey
    foreign key (created_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_names_updated_by_fkey
    foreign key (updated_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_names_name_value_check
    check (
      name_value = btrim(name_value)
      and (
        (
          name_type in ('OFFICIAL', 'USAGE')
          and char_length(name_value) between 2 and 300
        )
        or
        (
          name_type = 'ACRONYM'
          and char_length(name_value) between 2 and 40
        )
      )
    ),

  constraint association_names_basis_check
    check (
      basis is null
      or char_length(btrim(basis)) between 1 and 2000
    ),

  constraint association_names_period_order_check
    check (
      valid_from is null
      or valid_to is null
      or valid_to > valid_from
    ),

  constraint association_names_valid_from_certainty_check
    check (
      (
        valid_from is null
        and valid_from_certainty = 'UNKNOWN'
      )
      or
      (
        valid_from is not null
        and valid_from_certainty <> 'UNKNOWN'
      )
    ),

  constraint association_names_valid_to_certainty_check
    check (
      (
        valid_to is null
        and valid_to_certainty = 'UNKNOWN'
      )
      or
      (
        valid_to is not null
        and valid_to_certainty <> 'UNKNOWN'
      )
    ),

  constraint association_names_status_period_check
    check (
      (
        status = 'PROPOSED'
        and valid_from is null
        and valid_to is null
      )
      or
      (
        status = 'EFFECTIVE'
        and valid_to is null
      )
      or
      (
        status = 'HISTORICAL'
      )
      or
      (
        status in ('REJECTED', 'WITHDRAWN')
        and valid_from is null
        and valid_to is null
      )
    ),

  constraint association_names_primary_status_check
    check (
      not is_primary
      or status in ('EFFECTIVE', 'HISTORICAL')
    ),

  constraint association_names_effective_official_primary_check
    check (
      name_type <> 'OFFICIAL'
      or status <> 'EFFECTIVE'
      or is_primary
    ),

  constraint association_names_timestamp_order_check
    check (
      updated_at >= created_at
    ),

  -- Prevents incompatible known periods for primary names of the same type.
  -- Records with unknown temporal limits remain representable and must be
  -- reconciled by the controlled domain function instead of receiving an
  -- invented date.
  constraint association_names_known_primary_period_excl
    exclude using gist (
      association_id with =,
      name_type with =,
      daterange(valid_from, valid_to, '[)') with &&
    )
    where (
      is_primary
      and (
        (
          status = 'EFFECTIVE'
          and valid_from is not null
        )
        or
        (
          status = 'HISTORICAL'
          and valid_from is not null
          and valid_to is not null
        )
      )
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.association_names is
  'Temporal institutional-name source containing official names, usage names and acronyms in proposed, effective and historical states.';

comment on column app.association_names.id is
  'Stable UUID of the institutional-name record.';

comment on column app.association_names.association_id is
  'Tenant root to which the institutional name belongs.';

comment on column app.association_names.name_type is
  'Classifies the value as official name, usage name or acronym.';

comment on column app.association_names.name_value is
  'Institutional name exactly as adopted or proposed, with outer whitespace prohibited.';

comment on column app.association_names.status is
  'Domain state of the name record: proposed, effective, historical, rejected or withdrawn.';

comment on column app.association_names.is_primary is
  'Indicates that the name was or is the principal value of its type during its represented period.';

comment on column app.association_names.valid_from is
  'Inclusive first civil date on which the name was institutionally valid; NULL when unknown or not yet effective.';

comment on column app.association_names.valid_from_certainty is
  'Certainty assigned to valid_from. UNKNOWN is mandatory when the date itself is NULL.';

comment on column app.association_names.valid_to is
  'Exclusive civil date from which the name was no longer institutionally valid; NULL for an effective name or an unknown historical limit.';

comment on column app.association_names.valid_to_certainty is
  'Certainty assigned to valid_to. UNKNOWN is mandatory when the date itself is NULL.';

comment on column app.association_names.basis is
  'Optional concise institutional, documentary or administrative basis for the name record or transition.';

comment on column app.association_names.origin is
  'Controlled origin through which the name information entered the platform.';

comment on column app.association_names.created_at is
  'Instant at which the institutional-name record was created in the platform.';

comment on column app.association_names.created_by is
  'Global profile responsible for creating the institutional-name record.';

comment on column app.association_names.updated_at is
  'Instant of the latest controlled update to the proposal, status or temporal limits.';

comment on column app.association_names.updated_by is
  'Global profile responsible for the latest controlled update.';

-- ---------------------------------------------------------------------------
-- 3. Uniqueness and indexes
-- ---------------------------------------------------------------------------

-- At most one effective primary name of each type may exist per association.
-- Because every effective OFFICIAL name must be primary, this also guarantees
-- at most one current official denomination.
create unique index association_names_one_effective_primary_per_type_uidx
  on app.association_names (association_id, name_type)
  where is_primary and status = 'EFFECTIVE';

create index association_names_association_status_idx
  on app.association_names (association_id, status);

create index association_names_timeline_idx
  on app.association_names (
    association_id,
    name_type,
    valid_from desc nulls last,
    valid_to desc nulls last
  );

create index association_names_value_lookup_idx
  on app.association_names (
    association_id,
    name_type,
    lower(name_value)
  );

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- Direct INSERT/UPDATE/DELETE will be restricted later. Creation of the initial
-- name and all real name transitions will occur through controlled
-- transactional functions that also:
--
-- 1. close the prior effective official name when applicable;
-- 2. create or activate the new name;
-- 3. update associations.current_official_name atomically;
-- 4. write the corresponding audit event.
--
-- Until the dedicated RLS and grants migrations, Data API roles have no access.

alter table app.association_names enable row level security;

commit;
