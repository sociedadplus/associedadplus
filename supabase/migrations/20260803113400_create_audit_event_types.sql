-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 04 — Audit event types
-- File: 20260803113400_create_audit_event_types.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Global audit event type catalog
-- ---------------------------------------------------------------------------
-- This is a global technical catalog and therefore has no association_id.
--
-- The table defines the stable codes accepted by audit_events. It does not
-- store audit occurrences; those will be recorded later in app.audit_events.
--
-- Technical seed records are intentionally deferred to the dedicated seeds
-- migration, in accordance with the consolidated migration order.

create table app.audit_event_types (
  id uuid not null default extensions.gen_random_uuid(),

  code varchar(80) not null,
  description text not null,

  category app.audit_event_category not null,
  sensitivity app.audit_sensitivity not null default 'NORMAL',

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint audit_event_types_pkey
    primary key (id),

  constraint audit_event_types_code_key
    unique (code),

  constraint audit_event_types_code_format_check
    check (
      code ~ '^[A-Z][A-Z0-9_]{2,79}$'
    ),

  constraint audit_event_types_description_check
    check (
      char_length(btrim(description)) > 0
    ),

  constraint audit_event_types_timestamp_order_check
    check (
      updated_at >= created_at
    )
);

-- ---------------------------------------------------------------------------
-- 2. Documentation
-- ---------------------------------------------------------------------------

comment on table app.audit_event_types is
  'Global technical catalog of audit event definitions. It classifies audit occurrences but does not store the occurrences themselves.';

comment on column app.audit_event_types.id is
  'Surrogate UUID primary key of the audit event type definition.';

comment on column app.audit_event_types.code is
  'Stable machine-readable event code. The value is unique and must become immutable after insertion.';

comment on column app.audit_event_types.description is
  'Human-readable description of the technical event represented by the code.';

comment on column app.audit_event_types.category is
  'Stable technical category used to group related audit event definitions.';

comment on column app.audit_event_types.sensitivity is
  'Sensitivity classification used by later audit query and exposure rules.';

comment on column app.audit_event_types.is_active is
  'Indicates whether new audit occurrences may use this event type. Deactivation preserves historical references.';

comment on column app.audit_event_types.created_at is
  'Instant at which the audit event type definition was created.';

comment on column app.audit_event_types.updated_at is
  'Instant of the latest permitted administrative update to the event type definition.';

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

create index audit_event_types_active_category_idx
  on app.audit_event_types (is_active, category);

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- SELECT policy, administrative write restrictions, immutable-code enforcement
-- and updated_at maintenance are intentionally created in their dedicated
-- migrations. Until then, Data API roles have no row access.

alter table app.audit_event_types enable row level security;

commit;
