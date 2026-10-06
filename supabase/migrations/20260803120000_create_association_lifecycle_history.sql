-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 07 — Association lifecycle history
-- File: 20260803120000_create_association_lifecycle_history.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Association institutional lifecycle history
-- ---------------------------------------------------------------------------
-- This table is the temporal source of truth for the institutional lifecycle.
--
-- It does not represent:
-- - the technical platform status of the tenant;
-- - documentary or registry regularity;
-- - an active regularization process;
-- - operational suspension, restrictions or pending issues.
--
-- app.associations.current_lifecycle_status is only a rebuildable projection.
--
-- Civil periods use an exclusive upper bound:
-- [effective_from_on, effective_to_on)
--
-- Unknown historical dates remain NULL and are qualified by app.date_certainty.
-- For a current open period, effective_to_certainty remains NULL because the
-- absence of an end date means "still current", not "unknown historical end".

create table app.association_lifecycle_history (
  id uuid not null default extensions.gen_random_uuid(),
  association_id uuid not null,

  sequence_number bigint not null,
  lifecycle_state app.association_lifecycle_state not null,
  is_current boolean not null default true,

  effective_from_on date,
  effective_from_certainty app.date_certainty
    not null
    default 'UNKNOWN',

  effective_to_on date,
  effective_to_certainty app.date_certainty,

  basis_text text,
  origin app.record_origin not null default 'MANUAL',

  recorded_at timestamptz not null default now(),
  recorded_by uuid not null,

  closed_at timestamptz,
  closed_by uuid,

  constraint association_lifecycle_history_pkey
    primary key (id),

  -- Supports later tenant-safe composite foreign keys.
  constraint association_lifecycle_history_association_id_id_key
    unique (association_id, id),

  constraint association_lifecycle_history_association_sequence_key
    unique (association_id, sequence_number),

  constraint association_lifecycle_history_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint association_lifecycle_history_recorded_by_fkey
    foreign key (recorded_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_lifecycle_history_closed_by_fkey
    foreign key (closed_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_lifecycle_history_sequence_number_check
    check (
      sequence_number > 0
    ),

  constraint association_lifecycle_history_basis_text_check
    check (
      basis_text is null
      or (
        basis_text = btrim(basis_text)
        and char_length(basis_text) between 1 and 2000
      )
    ),

  constraint association_lifecycle_history_period_order_check
    check (
      effective_from_on is null
      or effective_to_on is null
      or effective_to_on > effective_from_on
    ),

  constraint association_lifecycle_history_effective_from_certainty_check
    check (
      (
        effective_from_on is null
        and effective_from_certainty = 'UNKNOWN'
      )
      or
      (
        effective_from_on is not null
        and effective_from_certainty <> 'UNKNOWN'
      )
    ),

  constraint association_lifecycle_history_effective_to_certainty_check
    check (
      (
        is_current
        and effective_to_on is null
        and effective_to_certainty is null
      )
      or
      (
        not is_current
        and (
          (
            effective_to_on is null
            and effective_to_certainty = 'UNKNOWN'
          )
          or
          (
            effective_to_on is not null
            and effective_to_certainty is not null
            and effective_to_certainty <> 'UNKNOWN'
          )
        )
      )
    ),

  constraint association_lifecycle_history_closure_check
    check (
      (
        is_current
        and closed_at is null
        and closed_by is null
      )
      or
      (
        not is_current
        and closed_at is not null
        and closed_by is not null
      )
    ),

  constraint association_lifecycle_history_closed_at_check
    check (
      closed_at is null
      or closed_at >= recorded_at
    ),

  -- Prevents overlap when the represented temporal limits are sufficiently
  -- known. A closed historical record with an unknown end is excluded from
  -- this constraint because NULL means "unknown", not positive infinity.
  constraint association_lifecycle_history_known_period_excl
    exclude using gist (
      association_id with =,
      daterange(effective_from_on, effective_to_on, '[)') with &&
    )
    where (
      effective_from_on is not null
      and (
        is_current
        or effective_to_on is not null
      )
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.association_lifecycle_history is
  'Append-oriented temporal source of the association institutional lifecycle. It is distinct from platform status, regularity, operational restrictions and regularization processes.';

comment on column app.association_lifecycle_history.id is
  'Stable UUID of one institutional lifecycle period.';

comment on column app.association_lifecycle_history.association_id is
  'Tenant root whose institutional lifecycle is represented.';

comment on column app.association_lifecycle_history.sequence_number is
  'Monotonic sequence within the association, allocated transactionally under association-level locking.';

comment on column app.association_lifecycle_history.lifecycle_state is
  'Institutional lifecycle state represented by the period.';

comment on column app.association_lifecycle_history.is_current is
  'Projection identifying the single open lifecycle record of the association.';

comment on column app.association_lifecycle_history.effective_from_on is
  'Inclusive civil date on which the lifecycle state began; NULL when historically unknown.';

comment on column app.association_lifecycle_history.effective_from_certainty is
  'Certainty assigned to effective_from_on. UNKNOWN is mandatory when the date is NULL.';

comment on column app.association_lifecycle_history.effective_to_on is
  'Exclusive civil date from which the lifecycle state ceased; NULL while current or when a closed historical end is unknown.';

comment on column app.association_lifecycle_history.effective_to_certainty is
  'Certainty assigned to a closed period end. NULL means the period is still current; UNKNOWN means a closed historical end exists but its date is unavailable.';

comment on column app.association_lifecycle_history.basis_text is
  'Optional concise institutional, documentary or administrative basis for the lifecycle state or transition.';

comment on column app.association_lifecycle_history.origin is
  'Controlled origin through which the lifecycle information entered the platform.';

comment on column app.association_lifecycle_history.recorded_at is
  'Instant at which the lifecycle record was written to the platform.';

comment on column app.association_lifecycle_history.recorded_by is
  'Global profile responsible for recording the lifecycle state.';

comment on column app.association_lifecycle_history.closed_at is
  'Technical instant at which the record ceased to be current in the platform.';

comment on column app.association_lifecycle_history.closed_by is
  'Global profile responsible for closing the formerly current lifecycle record.';

-- ---------------------------------------------------------------------------
-- 3. Uniqueness and indexes
-- ---------------------------------------------------------------------------

-- At most one lifecycle record may be current for each association.
create unique index association_lifecycle_history_one_current_uidx
  on app.association_lifecycle_history (association_id)
  where is_current;

create index association_lifecycle_history_state_idx
  on app.association_lifecycle_history (
    association_id,
    lifecycle_state
  );

create index association_lifecycle_history_effective_timeline_idx
  on app.association_lifecycle_history (
    association_id,
    effective_from_on desc nulls last,
    effective_to_on desc nulls last
  );

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- Direct INSERT and DELETE will remain unavailable.
--
-- The later app_private.change_association_lifecycle transactional function
-- will:
-- 1. lock the association and its current lifecycle row;
-- 2. validate the permitted transition;
-- 3. close the current row without inventing an unavailable civil date;
-- 4. insert the next sequenced lifecycle row;
-- 5. update associations.current_lifecycle_status atomically;
-- 6. record the corresponding audit event.
--
-- The permitted transition matrix, including the controlled possibility of a
-- return from INATIVA to ATIVA, will be implemented in that function rather
-- than through direct table updates.
--
-- Policies, grants, immutable-column enforcement and transactional functions
-- are intentionally deferred to their dedicated migrations.

alter table app.association_lifecycle_history enable row level security;

commit;
