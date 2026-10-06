-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 05 — Associations
-- File: 20260803114200_create_associations.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Association tenant roots
-- ---------------------------------------------------------------------------
-- Each row is the stable root of one institutional tenant.
--
-- The table intentionally does not store tax identifiers, addresses, contacts,
-- people, memberships, institutional offices, mandates or regularity results.
--
-- current_official_name and current_lifecycle_status are rebuildable
-- projections. Their temporal sources of truth will be app.association_names
-- and app.association_lifecycle_history.

create table app.associations (
  id uuid not null default extensions.gen_random_uuid(),

  slug varchar(80) not null,

  current_official_name text not null,
  current_lifecycle_status app.association_lifecycle_state
    not null
    default 'EM_CONSTITUICAO',

  platform_status app.association_platform_status
    not null
    default 'ACTIVE',

  archived_at timestamptz,

  created_at timestamptz not null default now(),
  created_by uuid not null,

  updated_at timestamptz not null default now(),
  updated_by uuid not null,

  constraint associations_pkey
    primary key (id),

  constraint associations_slug_key
    unique (slug),

  constraint associations_created_by_fkey
    foreign key (created_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint associations_updated_by_fkey
    foreign key (updated_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint associations_slug_format_check
    check (
      slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
      and char_length(slug) between 3 and 80
    ),

  constraint associations_current_official_name_check
    check (
      char_length(btrim(current_official_name)) between 2 and 300
    ),

  constraint associations_archive_consistency_check
    check (
      (
        platform_status = 'ARCHIVED'
        and archived_at is not null
      )
      or
      (
        platform_status <> 'ARCHIVED'
        and archived_at is null
      )
    ),

  constraint associations_timestamp_order_check
    check (
      updated_at >= created_at
      and (
        archived_at is null
        or archived_at >= created_at
      )
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.associations is
  'Stable root of an association tenant. Institutional names and lifecycle periods remain in their historical source tables; this row keeps only current projections and technical platform state.';

comment on column app.associations.id is
  'Stable UUID that identifies the association and serves as the tenant root referenced by institutional tables.';

comment on column app.associations.slug is
  'Globally unique, URL-safe and stable technical identifier. It is not the official institutional name.';

comment on column app.associations.current_official_name is
  'Current official-name projection maintained atomically from app.association_names. It is not the temporal source of truth.';

comment on column app.associations.current_lifecycle_status is
  'Current institutional lifecycle projection maintained atomically from app.association_lifecycle_history. It does not represent regularity, suspension or an active regularization process.';

comment on column app.associations.platform_status is
  'Technical availability state of the tenant inside the platform, independent from the institutional lifecycle.';

comment on column app.associations.archived_at is
  'Instant at which the tenant was technically archived. It is populated only when platform_status is ARCHIVED.';

comment on column app.associations.created_at is
  'Instant at which the tenant root was created.';

comment on column app.associations.created_by is
  'Global profile that initiated the controlled atomic creation of the association. This does not make the user an association member or institutional officeholder.';

comment on column app.associations.updated_at is
  'Instant of the latest permitted update to the tenant root or one of its current projections.';

comment on column app.associations.updated_by is
  'Global profile responsible for the latest permitted update to the tenant root or its projections.';

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

create index associations_platform_status_idx
  on app.associations (platform_status);

create index associations_current_lifecycle_status_idx
  on app.associations (current_lifecycle_status);

create index associations_created_by_idx
  on app.associations (created_by);

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- The bootstrap INSERT will not be exposed directly. A later SECURITY DEFINER
-- transactional function will create the association and all mandatory initial
-- records atomically.
--
-- SELECT policies and all write restrictions are intentionally deferred to
-- the dedicated RLS, grants and transactional-function migrations.

alter table app.associations enable row level security;

commit;
