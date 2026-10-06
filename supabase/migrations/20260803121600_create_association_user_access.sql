-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 09 — Association user access
-- File: 20260803121600_create_association_user_access.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Association access cycles
-- ---------------------------------------------------------------------------
-- Each row represents one authorization cycle between a global platform
-- profile and one association tenant.
--
-- This table does not represent:
-- - an association member;
-- - a civil person registered by the association;
-- - an institutional office or mandate;
-- - a permanent relationship that may be overwritten.
--
-- A role change closes the current cycle and creates a new one.
-- Suspension and resumption remain inside the same cycle and will be recorded
-- in app.association_user_access_status_history.
--
-- The represented instant period is:
-- [starts_at, ends_at)

create table app.association_user_access (
  id uuid not null default extensions.gen_random_uuid(),
  association_id uuid not null,
  profile_id uuid not null,

  role app.association_role not null,
  current_status app.association_access_status
    not null
    default 'ACTIVE',

  starts_at timestamptz not null default now(),
  ends_at timestamptz,

  granted_by uuid not null,
  grant_reason text,
  origin app.record_origin not null default 'MANUAL',

  ended_by uuid,
  end_reason text,

  created_at timestamptz not null default now(),

  constraint association_user_access_pkey
    primary key (id),

  constraint association_user_access_association_id_id_key
    unique (association_id, id),

  constraint association_user_access_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_profile_id_fkey
    foreign key (profile_id)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_granted_by_fkey
    foreign key (granted_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_ended_by_fkey
    foreign key (ended_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_period_order_check
    check (
      ends_at is null
      or ends_at > starts_at
    ),

  constraint association_user_access_grant_reason_check
    check (
      grant_reason is null
      or (
        grant_reason = btrim(grant_reason)
        and char_length(grant_reason) between 1 and 2000
      )
    ),

  constraint association_user_access_end_reason_check
    check (
      end_reason is null
      or (
        end_reason = btrim(end_reason)
        and char_length(end_reason) between 1 and 2000
      )
    ),

  constraint association_user_access_open_cycle_status_check
    check (
      (
        current_status in ('ACTIVE', 'SUSPENDED')
        and ends_at is null
        and ended_by is null
        and end_reason is null
      )
      or
      (
        current_status = 'REVOKED'
        and ends_at is not null
        and ended_by is not null
      )
      or
      (
        current_status = 'EXPIRED'
        and ends_at is not null
      )
    ),

  constraint association_user_access_period_excl
    exclude using gist (
      association_id with =,
      profile_id with =,
      tstzrange(starts_at, ends_at, '[)') with &&
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.association_user_access is
  'Temporal authorization cycle linking one global platform profile to one association tenant. It does not create association membership or institutional office.';

comment on column app.association_user_access.id is
  'Stable UUID of one authorization cycle.';

comment on column app.association_user_access.association_id is
  'Association tenant to which platform access is granted.';

comment on column app.association_user_access.profile_id is
  'Global platform profile receiving access to the association.';

comment on column app.association_user_access.role is
  'Authorization role fixed for this cycle. Changing the role requires closing this row and creating another cycle.';

comment on column app.association_user_access.current_status is
  'Current status projection rebuilt from app.association_user_access_status_history.';

comment on column app.association_user_access.starts_at is
  'Inclusive instant at which this access cycle begins.';

comment on column app.association_user_access.ends_at is
  'Exclusive instant at which this cycle ends. NULL while the cycle remains open, including while suspended.';

comment on column app.association_user_access.granted_by is
  'Global profile responsible for granting the authorization cycle.';

comment on column app.association_user_access.grant_reason is
  'Optional concise reason or authority supporting the access grant.';

comment on column app.association_user_access.origin is
  'Controlled origin of the access grant, such as manual grant, invitation or system bootstrap.';

comment on column app.association_user_access.ended_by is
  'Global profile responsible for ending the cycle. It is mandatory for revocation and may be NULL for automatic expiration.';

comment on column app.association_user_access.end_reason is
  'Optional concise reason for revocation, expiration or replacement of the cycle.';

comment on column app.association_user_access.created_at is
  'Technical instant at which the access-cycle row was inserted.';

-- ---------------------------------------------------------------------------
-- 3. Critical uniqueness and indexes
-- ---------------------------------------------------------------------------

create unique index association_user_access_one_open_cycle_uidx
  on app.association_user_access (association_id, profile_id)
  where ends_at is null;

create unique index association_user_access_one_active_primary_admin_uidx
  on app.association_user_access (association_id)
  where (
    role = 'ADMIN_PRINCIPAL'
    and current_status = 'ACTIVE'
    and ends_at is null
  );

create index association_user_access_profile_open_idx
  on app.association_user_access (profile_id, association_id)
  where ends_at is null;

create index association_user_access_association_status_role_idx
  on app.association_user_access (
    association_id,
    current_status,
    role
  );

create index association_user_access_association_timeline_idx
  on app.association_user_access (
    association_id,
    starts_at desc,
    ends_at desc nulls first
  );

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- No direct INSERT, role change, revocation or deletion will be exposed.
--
-- Later transactional functions will be responsible for:
-- - grant_association_access;
-- - suspend_association_access;
-- - resume_association_access;
-- - revoke_association_access;
-- - transfer_primary_association_admin;
-- - create_association bootstrap;
-- - invitation acceptance.
--
-- The RLS helper functions that read this table will live in app_private,
-- use SECURITY DEFINER with a fixed search_path and avoid recursive RLS.
--
-- Policies, grants, history creation, projection synchronization and
-- immutable-column enforcement are deferred to their dedicated migrations.

alter table app.association_user_access enable row level security;

commit;
