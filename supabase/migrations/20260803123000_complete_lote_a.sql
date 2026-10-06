-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 10+ — Remaining database implementation
-- File: 20260803123000_complete_lote_a.sql
--
-- Dependency order:
-- 1. Remaining tables
-- 2. Fixed catalogs / seeds
-- 3. Internal helper functions
-- 4. Triggers
-- 5. Transactional RPCs
-- 6. Support views
-- 7. RLS policies
-- 8. Grants

begin;

-- ===========================================================================
-- 1. REMAINING TABLES
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1.1. Access status history
-- ---------------------------------------------------------------------------

create table if not exists app.association_user_access_status_history (
  id uuid not null default extensions.gen_random_uuid(),
  association_id uuid not null,
  access_id uuid not null,

  status app.association_access_status not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,

  reason text,
  origin app.record_origin not null default 'MANUAL',

  recorded_at timestamptz not null default now(),
  recorded_by uuid not null,

  closed_at timestamptz,
  closed_by uuid,

  constraint association_user_access_status_history_pkey
    primary key (id),

  constraint association_user_access_status_history_association_id_id_key
    unique (association_id, id),

  constraint association_user_access_status_history_access_fkey
    foreign key (association_id, access_id)
    references app.association_user_access (association_id, id)
    on update restrict
    on delete restrict,

  constraint association_user_access_status_history_recorded_by_fkey
    foreign key (recorded_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_status_history_closed_by_fkey
    foreign key (closed_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_user_access_status_history_period_order_check
    check (ends_at is null or ends_at >= starts_at),

  constraint association_user_access_status_history_reason_check
    check (
      reason is null
      or (
        reason = btrim(reason)
        and char_length(reason) between 1 and 2000
      )
    ),

  constraint association_user_access_status_history_closure_check
    check (
      (
        ends_at is null
        and closed_at is null
        and closed_by is null
        and status in ('ACTIVE', 'SUSPENDED')
      )
      or
      (
        ends_at is not null
        and closed_at is not null
        and closed_by is not null
      )
    ),

  constraint association_user_access_status_history_closed_at_check
    check (closed_at is null or closed_at >= recorded_at),

  constraint association_user_access_status_history_period_excl
    exclude using gist (
      association_id with =,
      access_id with =,
      tstzrange(starts_at, ends_at, '[)') with &&
    )
);

comment on table app.association_user_access_status_history is
  'Append-oriented status timeline for one association access cycle. The open row projects to association_user_access.current_status.';

create unique index if not exists association_user_access_status_history_one_open_uidx
  on app.association_user_access_status_history (association_id, access_id)
  where ends_at is null;

create index if not exists association_user_access_status_history_timeline_idx
  on app.association_user_access_status_history (
    association_id,
    access_id,
    starts_at desc,
    ends_at desc nulls first
  );

alter table app.association_user_access_status_history enable row level security;

-- ---------------------------------------------------------------------------
-- 1.2. Association invitations
-- ---------------------------------------------------------------------------

create table if not exists app.association_invitations (
  id uuid not null default extensions.gen_random_uuid(),
  association_id uuid not null,

  invited_email text not null,
  invited_role app.association_role not null,
  status app.association_invitation_status not null default 'PENDING',

  token_hash text not null,
  expires_at timestamptz not null,

  invited_by uuid not null,
  invitation_message text,

  accepted_at timestamptz,
  accepted_by uuid,
  resulting_access_id uuid,

  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid not null,

  constraint association_invitations_pkey
    primary key (id),

  constraint association_invitations_association_id_id_key
    unique (association_id, id),

  constraint association_invitations_token_hash_key
    unique (token_hash),

  constraint association_invitations_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint association_invitations_invited_by_fkey
    foreign key (invited_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_invitations_accepted_by_fkey
    foreign key (accepted_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_invitations_cancelled_by_fkey
    foreign key (cancelled_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_invitations_updated_by_fkey
    foreign key (updated_by)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint association_invitations_resulting_access_fkey
    foreign key (association_id, resulting_access_id)
    references app.association_user_access (association_id, id)
    on update restrict
    on delete restrict,

  constraint association_invitations_email_check
    check (
      invited_email = lower(btrim(invited_email))
      and char_length(invited_email) between 3 and 320
      and invited_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),

  constraint association_invitations_token_hash_check
    check (token_hash ~ '^[0-9a-f]{64}$'),

  constraint association_invitations_expiration_check
    check (expires_at > created_at),

  constraint association_invitations_message_check
    check (
      invitation_message is null
      or (
        invitation_message = btrim(invitation_message)
        and char_length(invitation_message) between 1 and 2000
      )
    ),

  constraint association_invitations_cancellation_reason_check
    check (
      cancellation_reason is null
      or (
        cancellation_reason = btrim(cancellation_reason)
        and char_length(cancellation_reason) between 1 and 2000
      )
    ),

  constraint association_invitations_status_consistency_check
    check (
      (
        status = 'PENDING'
        and accepted_at is null
        and accepted_by is null
        and resulting_access_id is null
        and cancelled_at is null
        and cancelled_by is null
        and cancellation_reason is null
      )
      or
      (
        status = 'ACCEPTED'
        and accepted_at is not null
        and accepted_by is not null
        and resulting_access_id is not null
        and cancelled_at is null
        and cancelled_by is null
        and cancellation_reason is null
      )
      or
      (
        status = 'CANCELLED'
        and accepted_at is null
        and accepted_by is null
        and resulting_access_id is null
        and cancelled_at is not null
        and cancelled_by is not null
      )
      or
      (
        status = 'EXPIRED'
        and accepted_at is null
        and accepted_by is null
        and resulting_access_id is null
        and cancelled_at is null
        and cancelled_by is null
        and cancellation_reason is null
      )
    ),

  constraint association_invitations_timestamp_order_check
    check (
      updated_at >= created_at
      and (accepted_at is null or accepted_at >= created_at)
      and (cancelled_at is null or cancelled_at >= created_at)
    )
);

comment on table app.association_invitations is
  'Single-use, expiring invitation to grant a platform authorization role in one association. No raw token is stored.';

create unique index if not exists association_invitations_one_pending_email_uidx
  on app.association_invitations (association_id, invited_email)
  where status = 'PENDING';

create index if not exists association_invitations_pending_expiration_idx
  on app.association_invitations (expires_at)
  where status = 'PENDING';

create index if not exists association_invitations_association_status_idx
  on app.association_invitations (association_id, status, created_at desc);

alter table app.association_invitations enable row level security;

-- ---------------------------------------------------------------------------
-- 1.3. Audit events
-- ---------------------------------------------------------------------------

create table if not exists app.audit_events (
  id bigint generated always as identity,

  event_type_id uuid not null,
  association_id uuid,

  actor_type app.audit_actor_type not null,
  actor_profile_id uuid,

  event_origin app.audit_event_origin not null,
  event_result app.audit_event_result not null default 'SUCCESS',

  target_type app.audit_target_type,
  target_id uuid,

  occurred_at timestamptz not null default now(),

  request_id uuid,
  ip_address inet,
  user_agent text,

  old_data jsonb,
  new_data jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint audit_events_pkey
    primary key (id),

  constraint audit_events_event_type_id_fkey
    foreign key (event_type_id)
    references app.audit_event_types (id)
    on update restrict
    on delete restrict,

  constraint audit_events_association_id_fkey
    foreign key (association_id)
    references app.associations (id)
    on update restrict
    on delete restrict,

  constraint audit_events_actor_profile_id_fkey
    foreign key (actor_profile_id)
    references app.profiles (id)
    on update restrict
    on delete restrict,

  constraint audit_events_actor_consistency_check
    check (
      (
        actor_type = 'USER'
        and actor_profile_id is not null
      )
      or
      (
        actor_type in ('SYSTEM', 'SERVICE_ROLE')
        and actor_profile_id is null
      )
    ),

  constraint audit_events_target_consistency_check
    check (
      (target_type is null and target_id is null)
      or
      (target_type is not null and target_id is not null)
    ),

  constraint audit_events_user_agent_check
    check (
      user_agent is null
      or char_length(user_agent) between 1 and 2000
    ),

  constraint audit_events_old_data_object_check
    check (
      old_data is null
      or jsonb_typeof(old_data) = 'object'
    ),

  constraint audit_events_new_data_object_check
    check (
      new_data is null
      or jsonb_typeof(new_data) = 'object'
    ),

  constraint audit_events_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on table app.audit_events is
  'Append-only audit ledger for controlled Lote A operations. Rows are immutable and never physically deleted.';

create index if not exists audit_events_association_occurred_idx
  on app.audit_events (association_id, occurred_at desc, id desc);

create index if not exists audit_events_actor_occurred_idx
  on app.audit_events (actor_profile_id, occurred_at desc, id desc)
  where actor_profile_id is not null;

create index if not exists audit_events_type_occurred_idx
  on app.audit_events (event_type_id, occurred_at desc, id desc);

create index if not exists audit_events_target_idx
  on app.audit_events (association_id, target_type, target_id, occurred_at desc)
  where target_id is not null;

alter table app.audit_events enable row level security;

-- ===========================================================================
-- 2. FIXED CATALOGS / SEEDS
-- ===========================================================================

insert into app.audit_event_types (
  code,
  description,
  category,
  sensitivity,
  is_active
)
values
  ('PROFILE_CREATED', 'Complementary platform profile created.', 'PROFILE', 'NORMAL', true),
  ('PROFILE_UPDATED', 'Complementary platform profile updated.', 'PROFILE', 'NORMAL', true),

  ('ASSOCIATION_CREATED', 'Association tenant and mandatory initial records created atomically.', 'ASSOCIATION', 'SENSITIVE', true),
  ('ASSOCIATION_SETTINGS_UPDATED', 'Association operational settings updated.', 'SETTINGS', 'NORMAL', true),

  ('ASSOCIATION_NAME_CHANGED', 'Current official association name changed transactionally.', 'NAME', 'SENSITIVE', true),

  ('ASSOCIATION_LIFECYCLE_CHANGED', 'Association institutional lifecycle changed transactionally.', 'LIFECYCLE', 'SENSITIVE', true),

  ('ASSOCIATION_ACCESS_GRANTED', 'Association platform access cycle granted.', 'ACCESS', 'SENSITIVE', true),
  ('ASSOCIATION_ACCESS_SUSPENDED', 'Association platform access temporarily suspended.', 'ACCESS', 'SENSITIVE', true),
  ('ASSOCIATION_ACCESS_RESUMED', 'Association platform access resumed.', 'ACCESS', 'SENSITIVE', true),
  ('ASSOCIATION_ACCESS_REVOKED', 'Association platform access cycle revoked.', 'ACCESS', 'RESTRICTED', true),
  ('ASSOCIATION_ACCESS_ROLE_CHANGED', 'Association platform role changed by replacing the access cycle.', 'ACCESS', 'RESTRICTED', true),
  ('ASSOCIATION_PRIMARY_ADMIN_TRANSFERRED', 'Primary association administrator transferred atomically.', 'ACCESS', 'RESTRICTED', true),

  ('ASSOCIATION_INVITATION_CREATED', 'Association access invitation created.', 'INVITATION', 'SENSITIVE', true),
  ('ASSOCIATION_INVITATION_ACCEPTED', 'Association access invitation accepted and converted into an access cycle.', 'INVITATION', 'SENSITIVE', true),
  ('ASSOCIATION_INVITATION_CANCELLED', 'Pending association access invitation cancelled.', 'INVITATION', 'SENSITIVE', true),
  ('ASSOCIATION_INVITATION_EXPIRED', 'Pending association access invitation marked as expired.', 'INVITATION', 'NORMAL', true),

  ('AUDIT_EVENT_DENIED', 'A controlled operation was denied and recorded.', 'SECURITY', 'RESTRICTED', true)
on conflict (code) do update
set
  description = excluded.description,
  category = excluded.category,
  sensitivity = excluded.sensitivity,
  is_active = excluded.is_active,
  updated_at = now();

-- ===========================================================================
-- 3. INTERNAL HELPER FUNCTIONS — app_private
-- ===========================================================================

create or replace function app_private.current_user_id()
returns uuid
language sql
stable
security invoker
set search_path = public, app_private
as $$
  select auth.uid();
$$;

create or replace function app_private.is_service_role()
returns boolean
language sql
stable
security invoker
set search_path = public, app_private
as $$
  select coalesce(auth.role() = 'service_role', false);
$$;

create or replace function app_private.current_user_email()
returns text
language sql
stable
security definer
set search_path = public, app_private
as $$
  select lower(u.email)
  from auth.users u
  where u.id = auth.uid();
$$;

create or replace function app_private.ensure_current_profile()
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_display_name text;
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required.';
  end if;

  select coalesce(
           nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
           nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
           split_part(coalesce(u.email, v_user_id::text), '@', 1)
         )
    into v_display_name
  from auth.users u
  where u.id = v_user_id;

  insert into app.profiles (id, display_name)
  values (v_user_id, left(coalesce(v_display_name, 'Usuário'), 120))
  on conflict (id) do nothing;

  return v_user_id;
end;
$$;

create or replace function app_private.has_active_association_access(
  p_association_id uuid,
  p_profile_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public, app_private
as $$
  select exists (
    select 1
    from app.association_user_access aua
    where aua.association_id = p_association_id
      and aua.profile_id = p_profile_id
      and aua.current_status = 'ACTIVE'
      and aua.ends_at is null
  );
$$;

create or replace function app_private.has_association_role(
  p_association_id uuid,
  p_allowed_roles app.association_role[],
  p_profile_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public, app_private
as $$
  select exists (
    select 1
    from app.association_user_access aua
    where aua.association_id = p_association_id
      and aua.profile_id = p_profile_id
      and aua.role = any(p_allowed_roles)
      and aua.current_status = 'ACTIVE'
      and aua.ends_at is null
  );
$$;

create or replace function app_private.can_administer_association(
  p_association_id uuid,
  p_profile_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public, app_private
as $$
  select app_private.has_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[],
    p_profile_id
  );
$$;

create or replace function app_private.assert_authenticated()
returns uuid
language plpgsql
stable
security invoker
set search_path = public, app_private
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required.';
  end if;
  return v_user_id;
end;
$$;

create or replace function app_private.assert_association_role(
  p_association_id uuid,
  p_allowed_roles app.association_role[]
)
returns uuid
language plpgsql
stable
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication is required.';
  end if;

  if not app_private.has_association_role(
    p_association_id,
    p_allowed_roles,
    v_user_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'The authenticated user does not have the required association role.';
  end if;

  return v_user_id;
end;
$$;

create or replace function app_private.audit_actor_type()
returns app.audit_actor_type
language sql
stable
security invoker
set search_path = public, app_private
as $$
  select case
    when auth.uid() is not null then 'USER'::app.audit_actor_type
    when auth.role() = 'service_role' then 'SERVICE_ROLE'::app.audit_actor_type
    else 'SYSTEM'::app.audit_actor_type
  end;
$$;

create or replace function app_private.record_audit_event(
  p_event_code text,
  p_association_id uuid,
  p_event_origin app.audit_event_origin,
  p_event_result app.audit_event_result default 'SUCCESS',
  p_target_type app.audit_target_type default null,
  p_target_id uuid default null,
  p_old_data jsonb default null,
  p_new_data jsonb default null,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_event_type_id uuid;
  v_audit_id bigint;
  v_actor_type app.audit_actor_type := app_private.audit_actor_type();
  v_actor_profile_id uuid := auth.uid();
begin
  select aet.id
    into v_event_type_id
  from app.audit_event_types aet
  where aet.code = upper(btrim(p_event_code))
    and aet.is_active;

  if v_event_type_id is null then
    raise exception using
      errcode = '22023',
      message = format('Unknown or inactive audit event code: %s', p_event_code);
  end if;

  if (p_target_type is null) <> (p_target_id is null) then
    raise exception using
      errcode = '22023',
      message = 'Audit target type and target id must be supplied together.';
  end if;

  insert into app.audit_events (
    event_type_id,
    association_id,
    actor_type,
    actor_profile_id,
    event_origin,
    event_result,
    target_type,
    target_id,
    request_id,
    ip_address,
    user_agent,
    old_data,
    new_data,
    metadata
  )
  values (
    v_event_type_id,
    p_association_id,
    v_actor_type,
    case when v_actor_type = 'USER' then v_actor_profile_id else null end,
    p_event_origin,
    p_event_result,
    p_target_type,
    p_target_id,
    (
      nullif(current_setting('request.headers', true), '')::jsonb
      ->> 'x-request-id'
    )::uuid,
    nullif(
      split_part(
        nullif(current_setting('request.headers', true), '')::jsonb
        ->> 'x-forwarded-for',
        ',',
        1
      ),
      ''
    )::inet,
    nullif(nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent', ''),
    p_old_data,
    p_new_data,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_audit_id;

  return v_audit_id;
exception
  when invalid_text_representation then
    insert into app.audit_events (
      event_type_id,
      association_id,
      actor_type,
      actor_profile_id,
      event_origin,
      event_result,
      target_type,
      target_id,
      old_data,
      new_data,
      metadata
    )
    values (
      v_event_type_id,
      p_association_id,
      v_actor_type,
      case when v_actor_type = 'USER' then v_actor_profile_id else null end,
      p_event_origin,
      p_event_result,
      p_target_type,
      p_target_id,
      p_old_data,
      p_new_data,
      coalesce(p_metadata, '{}'::jsonb)
    )
    returning id into v_audit_id;

    return v_audit_id;
end;
$$;

create or replace function app_private.hash_invitation_token(p_token text)
returns text
language sql
immutable
strict
security definer
set search_path = public, app_private
as $$
  select encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

create or replace function app_private.generate_invitation_token()
returns text
language sql
volatile
security definer
set search_path = public, app_private
as $$
  select encode(extensions.gen_random_bytes(32), 'hex');
$$;

-- ===========================================================================
-- 4. TRIGGERS
-- ===========================================================================

create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_private.set_updated_at_and_actor()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
begin
  new.updated_at := now();

  if auth.uid() is not null then
    new.updated_by := auth.uid();
  elsif new.updated_by is null then
    new.updated_by := old.updated_by;
  end if;

  return new;
end;
$$;

create or replace function app_private.handle_new_auth_user()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_display_name text;
begin
  v_display_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    split_part(coalesce(new.email, new.id::text), '@', 1)
  );

  insert into app.profiles (id, display_name)
  values (new.id, left(coalesce(v_display_name, 'Usuário'), 120))
  on conflict (id) do nothing;

  return new;
end;
$$;

create or replace function app_private.sync_access_current_status()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
begin
  if new.ends_at is null then
    update app.association_user_access
       set current_status = new.status
     where id = new.access_id
       and association_id = new.association_id;
  end if;

  return new;
end;
$$;

create or replace function app_private.prevent_audit_event_mutation()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'Audit events are append-only and cannot be updated or deleted.';
end;
$$;

create or replace function app_private.prevent_audit_event_code_change()
returns trigger
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
begin
  if new.code is distinct from old.code then
    raise exception using
      errcode = '55000',
      message = 'Audit event type codes are immutable.';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on app.profiles;
create trigger profiles_set_updated_at
before update on app.profiles
for each row execute function app_private.set_updated_at();

drop trigger if exists audit_event_types_set_updated_at on app.audit_event_types;
create trigger audit_event_types_set_updated_at
before update on app.audit_event_types
for each row execute function app_private.set_updated_at();

drop trigger if exists audit_event_types_prevent_code_change on app.audit_event_types;
create trigger audit_event_types_prevent_code_change
before update on app.audit_event_types
for each row execute function app_private.prevent_audit_event_code_change();

drop trigger if exists associations_set_updated_at_actor on app.associations;
create trigger associations_set_updated_at_actor
before update on app.associations
for each row execute function app_private.set_updated_at_and_actor();

drop trigger if exists association_names_set_updated_at_actor on app.association_names;
create trigger association_names_set_updated_at_actor
before update on app.association_names
for each row execute function app_private.set_updated_at_and_actor();

drop trigger if exists association_operational_settings_set_updated_at_actor
  on app.association_operational_settings;
create trigger association_operational_settings_set_updated_at_actor
before update on app.association_operational_settings
for each row execute function app_private.set_updated_at_and_actor();

drop trigger if exists association_invitations_set_updated_at_actor
  on app.association_invitations;
create trigger association_invitations_set_updated_at_actor
before update on app.association_invitations
for each row execute function app_private.set_updated_at_and_actor();

drop trigger if exists association_access_status_sync_projection
  on app.association_user_access_status_history;
create trigger association_access_status_sync_projection
after insert or update of status, ends_at
on app.association_user_access_status_history
for each row execute function app_private.sync_access_current_status();

drop trigger if exists audit_events_prevent_update
  on app.audit_events;
create trigger audit_events_prevent_update
before update on app.audit_events
for each row execute function app_private.prevent_audit_event_mutation();

drop trigger if exists audit_events_prevent_delete
  on app.audit_events;
create trigger audit_events_prevent_delete
before delete on app.audit_events
for each row execute function app_private.prevent_audit_event_mutation();

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function app_private.handle_new_auth_user();

-- ===========================================================================
-- 5. TRANSACTIONAL RPCs — public
-- ===========================================================================

create or replace function public.create_association(
  p_official_name text,
  p_slug text,
  p_effective_from_on date default null,
  p_effective_from_certainty app.date_certainty default 'UNKNOWN',
  p_timezone_name text default 'America/Bahia',
  p_locale_code text default 'pt-BR',
  p_date_format app.date_format default 'DMY'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid;
  v_association_id uuid := extensions.gen_random_uuid();
  v_name_id uuid := extensions.gen_random_uuid();
  v_lifecycle_id uuid := extensions.gen_random_uuid();
  v_access_id uuid := extensions.gen_random_uuid();
  v_now timestamptz := now();
  v_name text := btrim(p_official_name);
  v_slug text := lower(btrim(p_slug));
begin
  v_user_id := app_private.ensure_current_profile();

  if char_length(v_name) not between 2 and 300 then
    raise exception using errcode = '22023', message = 'Official name must contain between 2 and 300 characters.';
  end if;

  if v_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or char_length(v_slug) not between 3 and 80 then
    raise exception using errcode = '22023', message = 'Invalid association slug.';
  end if;

  if (p_effective_from_on is null and p_effective_from_certainty <> 'UNKNOWN')
     or (p_effective_from_on is not null and p_effective_from_certainty = 'UNKNOWN') then
    raise exception using errcode = '22023', message = 'The effective date and its certainty are inconsistent.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_timezone_names t
    where t.name = btrim(p_timezone_name)
  ) then
    raise exception using errcode = '22023', message = 'Unknown IANA time zone.';
  end if;

  insert into app.associations (
    id,
    slug,
    current_official_name,
    current_lifecycle_status,
    platform_status,
    created_at,
    created_by,
    updated_at,
    updated_by
  )
  values (
    v_association_id,
    v_slug,
    v_name,
    'EM_CONSTITUICAO',
    'ACTIVE',
    v_now,
    v_user_id,
    v_now,
    v_user_id
  );

  insert into app.association_names (
    id,
    association_id,
    name_type,
    name_value,
    status,
    is_primary,
    valid_from,
    valid_from_certainty,
    valid_to,
    valid_to_certainty,
    basis,
    origin,
    created_at,
    created_by,
    updated_at,
    updated_by
  )
  values (
    v_name_id,
    v_association_id,
    'OFFICIAL',
    v_name,
    'EFFECTIVE',
    true,
    p_effective_from_on,
    p_effective_from_certainty,
    null,
    'UNKNOWN',
    'Initial official name created with the association tenant.',
    'SYSTEM',
    v_now,
    v_user_id,
    v_now,
    v_user_id
  );

  insert into app.association_lifecycle_history (
    id,
    association_id,
    sequence_number,
    lifecycle_state,
    is_current,
    effective_from_on,
    effective_from_certainty,
    effective_to_on,
    effective_to_certainty,
    basis_text,
    origin,
    recorded_at,
    recorded_by
  )
  values (
    v_lifecycle_id,
    v_association_id,
    1,
    'EM_CONSTITUICAO',
    true,
    p_effective_from_on,
    p_effective_from_certainty,
    null,
    null,
    'Initial lifecycle state created with the association tenant.',
    'SYSTEM',
    v_now,
    v_user_id
  );

  insert into app.association_operational_settings (
    association_id,
    timezone_name,
    locale_code,
    date_format,
    use_24_hour_time,
    week_starts_on,
    created_at,
    created_by,
    updated_at,
    updated_by
  )
  values (
    v_association_id,
    btrim(p_timezone_name),
    p_locale_code,
    p_date_format,
    true,
    1,
    v_now,
    v_user_id,
    v_now,
    v_user_id
  );

  insert into app.association_user_access (
    id,
    association_id,
    profile_id,
    role,
    current_status,
    starts_at,
    granted_by,
    grant_reason,
    origin,
    created_at
  )
  values (
    v_access_id,
    v_association_id,
    v_user_id,
    'ADMIN_PRINCIPAL',
    'ACTIVE',
    v_now,
    v_user_id,
    'Initial primary administrator created with the association tenant.',
    'SYSTEM',
    v_now
  );

  insert into app.association_user_access_status_history (
    association_id,
    access_id,
    status,
    starts_at,
    reason,
    origin,
    recorded_at,
    recorded_by
  )
  values (
    v_association_id,
    v_access_id,
    'ACTIVE',
    v_now,
    'Initial active access status.',
    'SYSTEM',
    v_now,
    v_user_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_CREATED',
    v_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION',
    v_association_id,
    null,
    jsonb_build_object(
      'slug', v_slug,
      'current_official_name', v_name,
      'current_lifecycle_status', 'EM_CONSTITUICAO',
      'primary_admin_profile_id', v_user_id
    ),
    jsonb_build_object(
      'initial_name_id', v_name_id,
      'initial_lifecycle_id', v_lifecycle_id,
      'initial_access_id', v_access_id
    )
  );

  return v_association_id;
end;
$$;

create or replace function public.change_association_official_name(
  p_association_id uuid,
  p_new_official_name text,
  p_effective_from date,
  p_effective_from_certainty app.date_certainty default 'EXACT',
  p_basis text default null,
  p_origin app.record_origin default 'MANUAL'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid;
  v_old_name app.association_names%rowtype;
  v_new_name_id uuid := extensions.gen_random_uuid();
  v_new_name text := btrim(p_new_official_name);
  v_now timestamptz := now();
begin
  v_user_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if char_length(v_new_name) not between 2 and 300 then
    raise exception using errcode = '22023', message = 'Official name must contain between 2 and 300 characters.';
  end if;

  if p_effective_from is null or p_effective_from_certainty = 'UNKNOWN' then
    raise exception using errcode = '22023', message = 'A known effective date is required for an official-name transition.';
  end if;

  perform 1
  from app.associations a
  where a.id = p_association_id
  for update;

  select *
    into v_old_name
  from app.association_names an
  where an.association_id = p_association_id
    and an.name_type = 'OFFICIAL'
    and an.status = 'EFFECTIVE'
    and an.is_primary
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Current official name was not found.';
  end if;

  if v_old_name.name_value = v_new_name then
    raise exception using errcode = '22023', message = 'The new official name is identical to the current one.';
  end if;

  if v_old_name.valid_from is not null and p_effective_from <= v_old_name.valid_from then
    raise exception using errcode = '22023', message = 'The new official name must begin after the current name began.';
  end if;

  update app.association_names
     set status = 'HISTORICAL',
         valid_to = p_effective_from,
         valid_to_certainty = p_effective_from_certainty,
         updated_by = v_user_id
   where id = v_old_name.id;

  insert into app.association_names (
    id,
    association_id,
    name_type,
    name_value,
    status,
    is_primary,
    valid_from,
    valid_from_certainty,
    valid_to,
    valid_to_certainty,
    basis,
    origin,
    created_at,
    created_by,
    updated_at,
    updated_by
  )
  values (
    v_new_name_id,
    p_association_id,
    'OFFICIAL',
    v_new_name,
    'EFFECTIVE',
    true,
    p_effective_from,
    p_effective_from_certainty,
    null,
    'UNKNOWN',
    nullif(btrim(p_basis), ''),
    p_origin,
    v_now,
    v_user_id,
    v_now,
    v_user_id
  );

  update app.associations
     set current_official_name = v_new_name,
         updated_by = v_user_id
   where id = p_association_id;

  perform app_private.record_audit_event(
    'ASSOCIATION_NAME_CHANGED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_NAME',
    v_new_name_id,
    jsonb_build_object(
      'name_id', v_old_name.id,
      'name_value', v_old_name.name_value,
      'status', v_old_name.status,
      'valid_to', v_old_name.valid_to
    ),
    jsonb_build_object(
      'name_id', v_new_name_id,
      'name_value', v_new_name,
      'status', 'EFFECTIVE',
      'valid_from', p_effective_from
    ),
    jsonb_build_object('basis', p_basis, 'origin', p_origin)
  );

  return v_new_name_id;
end;
$$;

create or replace function public.change_association_lifecycle(
  p_association_id uuid,
  p_new_state app.association_lifecycle_state,
  p_effective_from_on date,
  p_effective_from_certainty app.date_certainty default 'EXACT',
  p_basis_text text default null,
  p_origin app.record_origin default 'MANUAL'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid;
  v_current app.association_lifecycle_history%rowtype;
  v_new_id uuid := extensions.gen_random_uuid();
  v_next_sequence bigint;
  v_now timestamptz := now();
begin
  v_user_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if p_effective_from_on is null or p_effective_from_certainty = 'UNKNOWN' then
    raise exception using errcode = '22023', message = 'A known effective date is required for a lifecycle transition.';
  end if;

  perform 1
  from app.associations a
  where a.id = p_association_id
  for update;

  select *
    into v_current
  from app.association_lifecycle_history alh
  where alh.association_id = p_association_id
    and alh.is_current
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Current lifecycle state was not found.';
  end if;

  if v_current.lifecycle_state = p_new_state then
    raise exception using errcode = '22023', message = 'The new lifecycle state is identical to the current state.';
  end if;

  if v_current.lifecycle_state = 'ENCERRADA' and p_origin <> 'ADMINISTRATIVE_CORRECTION' then
    raise exception using errcode = '22023', message = 'ENCERRADA is terminal outside an administrative-correction path.';
  end if;

  if v_current.effective_from_on is not null
     and p_effective_from_on <= v_current.effective_from_on then
    raise exception using errcode = '22023', message = 'The new lifecycle period must begin after the current period began.';
  end if;

  v_next_sequence := v_current.sequence_number + 1;

  update app.association_lifecycle_history
     set is_current = false,
         effective_to_on = p_effective_from_on,
         effective_to_certainty = p_effective_from_certainty,
         closed_at = v_now,
         closed_by = v_user_id
   where id = v_current.id;

  insert into app.association_lifecycle_history (
    id,
    association_id,
    sequence_number,
    lifecycle_state,
    is_current,
    effective_from_on,
    effective_from_certainty,
    effective_to_on,
    effective_to_certainty,
    basis_text,
    origin,
    recorded_at,
    recorded_by
  )
  values (
    v_new_id,
    p_association_id,
    v_next_sequence,
    p_new_state,
    true,
    p_effective_from_on,
    p_effective_from_certainty,
    null,
    null,
    nullif(btrim(p_basis_text), ''),
    p_origin,
    v_now,
    v_user_id
  );

  update app.associations
     set current_lifecycle_status = p_new_state,
         updated_by = v_user_id
   where id = p_association_id;

  perform app_private.record_audit_event(
    'ASSOCIATION_LIFECYCLE_CHANGED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_LIFECYCLE',
    v_new_id,
    jsonb_build_object(
      'lifecycle_id', v_current.id,
      'sequence_number', v_current.sequence_number,
      'state', v_current.lifecycle_state
    ),
    jsonb_build_object(
      'lifecycle_id', v_new_id,
      'sequence_number', v_next_sequence,
      'state', p_new_state,
      'effective_from_on', p_effective_from_on
    ),
    jsonb_build_object('basis', p_basis_text, 'origin', p_origin)
  );

  return v_new_id;
end;
$$;

create or replace function public.update_association_operational_settings(
  p_association_id uuid,
  p_timezone_name text,
  p_locale_code text,
  p_date_format app.date_format,
  p_use_24_hour_time boolean,
  p_week_starts_on smallint
)
returns app.association_operational_settings
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid;
  v_old app.association_operational_settings%rowtype;
  v_new app.association_operational_settings%rowtype;
begin
  v_user_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if not exists (
    select 1 from pg_catalog.pg_timezone_names t
    where t.name = btrim(p_timezone_name)
  ) then
    raise exception using errcode = '22023', message = 'Unknown IANA time zone.';
  end if;

  select *
    into v_old
  from app.association_operational_settings aos
  where aos.association_id = p_association_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Association operational settings were not found.';
  end if;

  update app.association_operational_settings
     set timezone_name = btrim(p_timezone_name),
         locale_code = p_locale_code,
         date_format = p_date_format,
         use_24_hour_time = p_use_24_hour_time,
         week_starts_on = p_week_starts_on,
         updated_by = v_user_id
   where association_id = p_association_id
  returning * into v_new;

  perform app_private.record_audit_event(
    'ASSOCIATION_SETTINGS_UPDATED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_SETTINGS',
    p_association_id,
    to_jsonb(v_old),
    to_jsonb(v_new),
    '{}'::jsonb
  );

  return v_new;
end;
$$;

create or replace function public.grant_association_access(
  p_association_id uuid,
  p_profile_id uuid,
  p_role app.association_role,
  p_reason text default null,
  p_origin app.record_origin default 'MANUAL'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_access_id uuid := extensions.gen_random_uuid();
  v_now timestamptz := now();
begin
  v_actor_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if p_role = 'ADMIN_PRINCIPAL' then
    raise exception using errcode = '22023', message = 'Use transfer_primary_association_admin to assign ADMIN_PRINCIPAL.';
  end if;

  perform 1 from app.profiles p where p.id = p_profile_id;
  if not found then
    raise exception using errcode = '23503', message = 'Target profile does not exist.';
  end if;

  perform 1
  from app.associations a
  where a.id = p_association_id
  for update;

  if exists (
    select 1
    from app.association_user_access aua
    where aua.association_id = p_association_id
      and aua.profile_id = p_profile_id
      and aua.ends_at is null
  ) then
    raise exception using errcode = '23505', message = 'The profile already has an open access cycle for this association.';
  end if;

  insert into app.association_user_access (
    id, association_id, profile_id, role, current_status,
    starts_at, granted_by, grant_reason, origin, created_at
  )
  values (
    v_access_id, p_association_id, p_profile_id, p_role, 'ACTIVE',
    v_now, v_actor_id, nullif(btrim(p_reason), ''), p_origin, v_now
  );

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at,
    reason, origin, recorded_at, recorded_by
  )
  values (
    p_association_id, v_access_id, 'ACTIVE', v_now,
    coalesce(nullif(btrim(p_reason), ''), 'Access granted.'),
    p_origin, v_now, v_actor_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_ACCESS_GRANTED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS',
    v_access_id,
    null,
    jsonb_build_object(
      'profile_id', p_profile_id,
      'role', p_role,
      'status', 'ACTIVE'
    ),
    jsonb_build_object('reason', p_reason, 'origin', p_origin)
  );

  return v_access_id;
end;
$$;

create or replace function public.suspend_association_access(
  p_access_id uuid,
  p_reason text
)
returns void
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_access app.association_user_access%rowtype;
  v_open_status app.association_user_access_status_history%rowtype;
  v_now timestamptz := now();
begin
  select *
    into v_access
  from app.association_user_access
  where id = p_access_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Access cycle was not found.';
  end if;

  v_actor_id := app_private.assert_association_role(
    v_access.association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if v_access.current_status <> 'ACTIVE' or v_access.ends_at is not null then
    raise exception using errcode = '22023', message = 'Only an open ACTIVE access cycle may be suspended.';
  end if;

  if v_access.role = 'ADMIN_PRINCIPAL' then
    raise exception using errcode = '22023', message = 'The active primary administrator cannot be suspended.';
  end if;

  select *
    into v_open_status
  from app.association_user_access_status_history
  where association_id = v_access.association_id
    and access_id = v_access.id
    and ends_at is null
  for update;

  update app.association_user_access_status_history
     set ends_at = v_now,
         closed_at = v_now,
         closed_by = v_actor_id
   where id = v_open_status.id;

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at,
    reason, origin, recorded_at, recorded_by
  )
  values (
    v_access.association_id, v_access.id, 'SUSPENDED', v_now,
    btrim(p_reason), 'MANUAL', v_now, v_actor_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_ACCESS_SUSPENDED',
    v_access.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS_STATUS',
    v_access.id,
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('status', 'SUSPENDED'),
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.resume_association_access(
  p_access_id uuid,
  p_reason text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_access app.association_user_access%rowtype;
  v_open_status app.association_user_access_status_history%rowtype;
  v_now timestamptz := now();
begin
  select *
    into v_access
  from app.association_user_access
  where id = p_access_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Access cycle was not found.';
  end if;

  v_actor_id := app_private.assert_association_role(
    v_access.association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if v_access.current_status <> 'SUSPENDED' or v_access.ends_at is not null then
    raise exception using errcode = '22023', message = 'Only an open SUSPENDED access cycle may be resumed.';
  end if;

  select *
    into v_open_status
  from app.association_user_access_status_history
  where association_id = v_access.association_id
    and access_id = v_access.id
    and ends_at is null
  for update;

  update app.association_user_access_status_history
     set ends_at = v_now,
         closed_at = v_now,
         closed_by = v_actor_id
   where id = v_open_status.id;

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at,
    reason, origin, recorded_at, recorded_by
  )
  values (
    v_access.association_id, v_access.id, 'ACTIVE', v_now,
    coalesce(nullif(btrim(p_reason), ''), 'Access resumed.'),
    'MANUAL', v_now, v_actor_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_ACCESS_RESUMED',
    v_access.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS_STATUS',
    v_access.id,
    jsonb_build_object('status', 'SUSPENDED'),
    jsonb_build_object('status', 'ACTIVE'),
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.revoke_association_access(
  p_access_id uuid,
  p_reason text
)
returns void
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_access app.association_user_access%rowtype;
  v_open_status app.association_user_access_status_history%rowtype;
  v_now timestamptz := now();
begin
  select *
    into v_access
  from app.association_user_access
  where id = p_access_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Access cycle was not found.';
  end if;

  v_actor_id := app_private.assert_association_role(
    v_access.association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if v_access.ends_at is not null then
    raise exception using errcode = '22023', message = 'The access cycle is already closed.';
  end if;

  if v_access.role = 'ADMIN_PRINCIPAL' then
    raise exception using errcode = '22023', message = 'Transfer the primary administrator before revoking this access.';
  end if;

  select *
    into v_open_status
  from app.association_user_access_status_history
  where association_id = v_access.association_id
    and access_id = v_access.id
    and ends_at is null
  for update;

  update app.association_user_access_status_history
     set ends_at = v_now,
         closed_at = v_now,
         closed_by = v_actor_id
   where id = v_open_status.id;

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at, ends_at,
    reason, origin, recorded_at, recorded_by, closed_at, closed_by
  )
  values (
    v_access.association_id, v_access.id, 'REVOKED', v_now, v_now,
    btrim(p_reason), 'MANUAL', v_now, v_actor_id, v_now, v_actor_id
  );

  update app.association_user_access
     set current_status = 'REVOKED',
         ends_at = v_now,
         ended_by = v_actor_id,
         end_reason = btrim(p_reason)
   where id = v_access.id;

  perform app_private.record_audit_event(
    'ASSOCIATION_ACCESS_REVOKED',
    v_access.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS',
    v_access.id,
    jsonb_build_object(
      'profile_id', v_access.profile_id,
      'role', v_access.role,
      'status', v_access.current_status
    ),
    jsonb_build_object(
      'profile_id', v_access.profile_id,
      'role', v_access.role,
      'status', 'REVOKED',
      'ends_at', v_now
    ),
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.change_association_access_role(
  p_access_id uuid,
  p_new_role app.association_role,
  p_reason text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_old app.association_user_access%rowtype;
  v_new_id uuid;
begin
  select *
    into v_old
  from app.association_user_access
  where id = p_access_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Access cycle was not found.';
  end if;

  v_actor_id := app_private.assert_association_role(
    v_old.association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if v_old.role = 'ADMIN_PRINCIPAL' or p_new_role = 'ADMIN_PRINCIPAL' then
    raise exception using errcode = '22023', message = 'Use transfer_primary_association_admin for ADMIN_PRINCIPAL changes.';
  end if;

  if v_old.current_status <> 'ACTIVE' or v_old.ends_at is not null then
    raise exception using errcode = '22023', message = 'Only an open ACTIVE cycle may have its role changed.';
  end if;

  if v_old.role = p_new_role then
    raise exception using errcode = '22023', message = 'The new role is identical to the current role.';
  end if;

  perform public.revoke_association_access(v_old.id, 'Role replaced: ' || btrim(p_reason));

  v_new_id := public.grant_association_access(
    v_old.association_id,
    v_old.profile_id,
    p_new_role,
    btrim(p_reason),
    'MANUAL'
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_ACCESS_ROLE_CHANGED',
    v_old.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS',
    v_new_id,
    jsonb_build_object('old_access_id', v_old.id, 'old_role', v_old.role),
    jsonb_build_object('new_access_id', v_new_id, 'new_role', p_new_role),
    jsonb_build_object('reason', p_reason, 'actor_id', v_actor_id)
  );

  return v_new_id;
end;
$$;

create or replace function public.transfer_primary_association_admin(
  p_association_id uuid,
  p_new_profile_id uuid,
  p_reason text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_old_primary app.association_user_access%rowtype;
  v_existing app.association_user_access%rowtype;
  v_new_access_id uuid := extensions.gen_random_uuid();
  v_replacement_old_id uuid;
  v_now timestamptz := now();
begin
  v_actor_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL']::app.association_role[]
  );

  perform 1
  from app.associations a
  where a.id = p_association_id
  for update;

  select *
    into v_old_primary
  from app.association_user_access
  where association_id = p_association_id
    and role = 'ADMIN_PRINCIPAL'
    and current_status = 'ACTIVE'
    and ends_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Active primary administrator was not found.';
  end if;

  if v_old_primary.profile_id = p_new_profile_id then
    raise exception using errcode = '22023', message = 'The selected profile is already the primary administrator.';
  end if;

  select *
    into v_existing
  from app.association_user_access
  where association_id = p_association_id
    and profile_id = p_new_profile_id
    and ends_at is null
  for update;

  if found then
    if v_existing.current_status <> 'ACTIVE' then
      raise exception using errcode = '22023', message = 'The new primary administrator must have ACTIVE access.';
    end if;
    v_replacement_old_id := v_existing.id;
    perform public.revoke_association_access(v_existing.id, 'Replaced by primary-administrator transfer.');
  else
    perform 1 from app.profiles where id = p_new_profile_id;
    if not found then
      raise exception using errcode = '23503', message = 'New primary-administrator profile does not exist.';
    end if;
  end if;

  -- Close the former primary administrator only after the target profile has
  -- been validated. The association row lock serializes competing transfers.
  update app.association_user_access_status_history
     set ends_at = v_now,
         closed_at = v_now,
         closed_by = v_actor_id
   where association_id = p_association_id
     and access_id = v_old_primary.id
     and ends_at is null;

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at, ends_at,
    reason, origin, recorded_at, recorded_by, closed_at, closed_by
  )
  values (
    p_association_id, v_old_primary.id, 'REVOKED', v_now, v_now,
    'Primary administrator transferred: ' || btrim(p_reason),
    'MANUAL', v_now, v_actor_id, v_now, v_actor_id
  );

  update app.association_user_access
     set current_status = 'REVOKED',
         ends_at = v_now,
         ended_by = v_actor_id,
         end_reason = 'Primary administrator transferred: ' || btrim(p_reason)
   where id = v_old_primary.id;

  insert into app.association_user_access (
    id, association_id, profile_id, role, current_status,
    starts_at, granted_by, grant_reason, origin, created_at
  )
  values (
    v_new_access_id, p_association_id, p_new_profile_id,
    'ADMIN_PRINCIPAL', 'ACTIVE',
    v_now, v_actor_id,
    'Primary administrator transferred: ' || btrim(p_reason),
    'MANUAL', v_now
  );

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at,
    reason, origin, recorded_at, recorded_by
  )
  values (
    p_association_id, v_new_access_id, 'ACTIVE', v_now,
    'Primary administrator access started.',
    'MANUAL', v_now, v_actor_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_PRIMARY_ADMIN_TRANSFERRED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_ACCESS',
    v_new_access_id,
    jsonb_build_object(
      'old_access_id', v_old_primary.id,
      'old_profile_id', v_old_primary.profile_id
    ),
    jsonb_build_object(
      'new_access_id', v_new_access_id,
      'new_profile_id', p_new_profile_id,
      'replaced_target_access_id', v_replacement_old_id
    ),
    jsonb_build_object('reason', p_reason)
  );

  return v_new_access_id;
end;
$$;

create or replace function public.create_association_invitation(
  p_association_id uuid,
  p_invited_email text,
  p_invited_role app.association_role,
  p_expires_in interval default interval '7 days',
  p_message text default null
)
returns table (
  invitation_id uuid,
  invitation_token text,
  expires_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_token text;
  v_token_hash text;
  v_invitation_id uuid := extensions.gen_random_uuid();
  v_expired_invitation_id uuid;
  v_expired_at timestamptz;
  v_email text := lower(btrim(p_invited_email));
  v_expires_at timestamptz := now() + p_expires_in;
begin
  v_actor_id := app_private.assert_association_role(
    p_association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if p_invited_role = 'ADMIN_PRINCIPAL' then
    raise exception using errcode = '22023', message = 'ADMIN_PRINCIPAL cannot be granted by invitation.';
  end if;

  if p_expires_in <= interval '0 seconds'
     or p_expires_in > interval '30 days' then
    raise exception using errcode = '22023', message = 'Invitation validity must be greater than zero and no more than 30 days.';
  end if;

  for v_expired_invitation_id, v_expired_at in
    select ai.id, ai.expires_at
    from app.association_invitations ai
    where ai.association_id = p_association_id
      and ai.invited_email = v_email
      and ai.status = 'PENDING'
      and ai.expires_at <= now()
    for update
  loop
    update app.association_invitations
       set status = 'EXPIRED',
           updated_by = v_actor_id
     where id = v_expired_invitation_id;

    perform app_private.record_audit_event(
      'ASSOCIATION_INVITATION_EXPIRED',
      p_association_id,
      'RPC',
      'SUCCESS',
      'ASSOCIATION_INVITATION',
      v_expired_invitation_id,
      jsonb_build_object('status', 'PENDING'),
      jsonb_build_object('status', 'EXPIRED'),
      jsonb_build_object('expired_at', v_expired_at)
    );
  end loop;

  if exists (
    select 1
    from app.association_invitations ai
    where ai.association_id = p_association_id
      and ai.invited_email = v_email
      and ai.status = 'PENDING'
  ) then
    raise exception using errcode = '23505', message = 'A pending invitation already exists for this email and association.';
  end if;

  v_token := app_private.generate_invitation_token();
  v_token_hash := app_private.hash_invitation_token(v_token);

  insert into app.association_invitations (
    id,
    association_id,
    invited_email,
    invited_role,
    status,
    token_hash,
    expires_at,
    invited_by,
    invitation_message,
    created_at,
    updated_at,
    updated_by
  )
  values (
    v_invitation_id,
    p_association_id,
    v_email,
    p_invited_role,
    'PENDING',
    v_token_hash,
    v_expires_at,
    v_actor_id,
    nullif(btrim(p_message), ''),
    now(),
    now(),
    v_actor_id
  );

  perform app_private.record_audit_event(
    'ASSOCIATION_INVITATION_CREATED',
    p_association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_INVITATION',
    v_invitation_id,
    null,
    jsonb_build_object(
      'invited_email', v_email,
      'invited_role', p_invited_role,
      'expires_at', v_expires_at
    ),
    '{}'::jsonb
  );

  return query select v_invitation_id, v_token, v_expires_at;
end;
$$;

create or replace function public.accept_association_invitation(
  p_invitation_token text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_user_id uuid;
  v_email text;
  v_invitation app.association_invitations%rowtype;
  v_access_id uuid := extensions.gen_random_uuid();
  v_now timestamptz := now();
begin
  v_user_id := app_private.ensure_current_profile();
  v_email := app_private.current_user_email();

  if v_email is null then
    raise exception using errcode = '22023', message = 'The authenticated account has no email address.';
  end if;

  select *
    into v_invitation
  from app.association_invitations ai
  where ai.token_hash = app_private.hash_invitation_token(p_invitation_token)
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Invitation was not found.';
  end if;

  if v_invitation.status <> 'PENDING' then
    raise exception using errcode = '22023', message = 'Invitation is no longer pending.';
  end if;

  if v_invitation.expires_at <= v_now then
    raise exception using
      errcode = '22023',
      message = 'Invitation has expired. The scheduled expiration routine must finalize its status.';
  end if;

  if v_invitation.invited_email <> v_email then
    raise exception using errcode = '42501', message = 'Invitation email does not match the authenticated account.';
  end if;

  perform 1
  from app.associations a
  where a.id = v_invitation.association_id
  for update;

  if exists (
    select 1
    from app.association_user_access aua
    where aua.association_id = v_invitation.association_id
      and aua.profile_id = v_user_id
      and aua.ends_at is null
  ) then
    raise exception using errcode = '23505', message = 'The authenticated profile already has an open access cycle for this association.';
  end if;

  insert into app.association_user_access (
    id, association_id, profile_id, role, current_status,
    starts_at, granted_by, grant_reason, origin, created_at
  )
  values (
    v_access_id,
    v_invitation.association_id,
    v_user_id,
    v_invitation.invited_role,
    'ACTIVE',
    v_now,
    v_invitation.invited_by,
    'Access created by accepted invitation.',
    'INVITATION',
    v_now
  );

  insert into app.association_user_access_status_history (
    association_id, access_id, status, starts_at,
    reason, origin, recorded_at, recorded_by
  )
  values (
    v_invitation.association_id,
    v_access_id,
    'ACTIVE',
    v_now,
    'Initial status created by invitation acceptance.',
    'INVITATION',
    v_now,
    v_user_id
  );

  update app.association_invitations
     set status = 'ACCEPTED',
         accepted_at = v_now,
         accepted_by = v_user_id,
         resulting_access_id = v_access_id,
         updated_by = v_user_id
   where id = v_invitation.id;

  perform app_private.record_audit_event(
    'ASSOCIATION_INVITATION_ACCEPTED',
    v_invitation.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_INVITATION',
    v_invitation.id,
    jsonb_build_object('status', 'PENDING'),
    jsonb_build_object(
      'status', 'ACCEPTED',
      'accepted_by', v_user_id,
      'resulting_access_id', v_access_id
    ),
    '{}'::jsonb
  );

  return v_access_id;
end;
$$;

create or replace function public.cancel_association_invitation(
  p_invitation_id uuid,
  p_reason text
)
returns void
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_actor_id uuid;
  v_invitation app.association_invitations%rowtype;
  v_now timestamptz := now();
begin
  select *
    into v_invitation
  from app.association_invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Invitation was not found.';
  end if;

  v_actor_id := app_private.assert_association_role(
    v_invitation.association_id,
    array['ADMIN_PRINCIPAL', 'ADMIN_ASSOCIACAO']::app.association_role[]
  );

  if v_invitation.status <> 'PENDING' then
    raise exception using errcode = '22023', message = 'Only a pending invitation may be cancelled.';
  end if;

  update app.association_invitations
     set status = 'CANCELLED',
         cancelled_at = v_now,
         cancelled_by = v_actor_id,
         cancellation_reason = btrim(p_reason),
         updated_by = v_actor_id
   where id = p_invitation_id;

  perform app_private.record_audit_event(
    'ASSOCIATION_INVITATION_CANCELLED',
    v_invitation.association_id,
    'RPC',
    'SUCCESS',
    'ASSOCIATION_INVITATION',
    v_invitation.id,
    jsonb_build_object('status', 'PENDING'),
    jsonb_build_object('status', 'CANCELLED'),
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.expire_pending_association_invitations()
returns integer
language plpgsql
volatile
security definer
set search_path = public, app_private
as $$
declare
  v_invitation record;
  v_count integer := 0;
begin
  if not app_private.is_service_role() then
    raise exception using
      errcode = '42501',
      message = 'Only service_role may expire invitations in bulk.';
  end if;

  for v_invitation in
    select ai.id, ai.association_id
    from app.association_invitations ai
    where ai.status = 'PENDING'
      and ai.expires_at <= now()
    for update skip locked
  loop
    update app.association_invitations
       set status = 'EXPIRED',
           updated_at = now()
     where id = v_invitation.id;

    perform app_private.record_audit_event(
      'ASSOCIATION_INVITATION_EXPIRED',
      v_invitation.association_id,
      'SYSTEM_PROCESS',
      'SUCCESS',
      'ASSOCIATION_INVITATION',
      v_invitation.id,
      jsonb_build_object('status', 'PENDING'),
      jsonb_build_object('status', 'EXPIRED'),
      '{}'::jsonb
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ===========================================================================
-- 6. SUPPORT VIEWS
-- ===========================================================================

create or replace view app.v_my_association_access
with (security_invoker = true)
as
select
  aua.id as access_id,
  aua.association_id,
  a.slug,
  a.current_official_name,
  a.current_lifecycle_status,
  a.platform_status,
  aua.profile_id,
  aua.role,
  aua.current_status,
  aua.starts_at,
  aua.ends_at
from app.association_user_access aua
join app.associations a
  on a.id = aua.association_id
where aua.profile_id = auth.uid()
  and aua.ends_at is null;

create or replace view app.v_association_dashboard
with (security_invoker = true)
as
select
  a.id as association_id,
  a.slug,
  a.current_official_name,
  a.current_lifecycle_status,
  a.platform_status,
  aos.timezone_name,
  aos.locale_code,
  aos.date_format,
  count(distinct aua.id) filter (
    where aua.current_status = 'ACTIVE'
      and aua.ends_at is null
  ) as active_user_count,
  count(distinct ai.id) filter (
    where ai.status = 'PENDING'
      and ai.expires_at > now()
  ) as pending_invitation_count
from app.associations a
left join app.association_operational_settings aos
  on aos.association_id = a.id
left join app.association_user_access aua
  on aua.association_id = a.id
left join app.association_invitations ai
  on ai.association_id = a.id
where app_private.can_administer_association(a.id)
group by
  a.id,
  a.slug,
  a.current_official_name,
  a.current_lifecycle_status,
  a.platform_status,
  aos.timezone_name,
  aos.locale_code,
  aos.date_format;

-- ===========================================================================
-- 7. ROW LEVEL SECURITY POLICIES
-- ===========================================================================

-- Profiles ------------------------------------------------------------------

drop policy if exists profiles_select_own on app.profiles;
create policy profiles_select_own
on app.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists profiles_update_own on app.profiles;
create policy profiles_update_own
on app.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Audit event type catalog ---------------------------------------------------

drop policy if exists audit_event_types_select_authenticated
  on app.audit_event_types;
create policy audit_event_types_select_authenticated
on app.audit_event_types
for select
to authenticated
using (is_active);

-- Associations ---------------------------------------------------------------

drop policy if exists associations_select_members on app.associations;
create policy associations_select_members
on app.associations
for select
to authenticated
using (
  app_private.has_active_association_access(id)
);

-- Association names ----------------------------------------------------------

drop policy if exists association_names_select_members on app.association_names;
create policy association_names_select_members
on app.association_names
for select
to authenticated
using (
  app_private.has_active_association_access(association_id)
);

-- Lifecycle history ----------------------------------------------------------

drop policy if exists association_lifecycle_history_select_members
  on app.association_lifecycle_history;
create policy association_lifecycle_history_select_members
on app.association_lifecycle_history
for select
to authenticated
using (
  app_private.has_active_association_access(association_id)
);

-- Operational settings -------------------------------------------------------

drop policy if exists association_operational_settings_select_members
  on app.association_operational_settings;
create policy association_operational_settings_select_members
on app.association_operational_settings
for select
to authenticated
using (
  app_private.has_active_association_access(association_id)
);

-- Access cycles ---------------------------------------------------------------

drop policy if exists association_user_access_select_context
  on app.association_user_access;
create policy association_user_access_select_context
on app.association_user_access
for select
to authenticated
using (
  profile_id = auth.uid()
  or app_private.can_administer_association(association_id)
);

-- Access status history ------------------------------------------------------

drop policy if exists association_user_access_status_history_select_context
  on app.association_user_access_status_history;
create policy association_user_access_status_history_select_context
on app.association_user_access_status_history
for select
to authenticated
using (
  exists (
    select 1
    from app.association_user_access aua
    where aua.id = app.association_user_access_status_history.access_id
      and aua.association_id = app.association_user_access_status_history.association_id
      and (
        aua.profile_id = auth.uid()
        or app_private.can_administer_association(association_id)
      )
  )
);

-- Invitations ----------------------------------------------------------------

drop policy if exists association_invitations_select_admins
  on app.association_invitations;
create policy association_invitations_select_admins
on app.association_invitations
for select
to authenticated
using (
  app_private.can_administer_association(association_id)
);

-- Audit events ---------------------------------------------------------------

drop policy if exists audit_events_select_association_admins
  on app.audit_events;
create policy audit_events_select_association_admins
on app.audit_events
for select
to authenticated
using (
  association_id is not null
  and app_private.can_administer_association(association_id)
  and exists (
    select 1
    from app.audit_event_types aet
    where aet.id = event_type_id
      and (
        aet.sensitivity <> 'RESTRICTED'
        or app_private.has_association_role(
          association_id,
          array['ADMIN_PRINCIPAL']::app.association_role[]
        )
      )
  )
);

-- ===========================================================================
-- 8. GRANTS / PERMISSIONS
-- ===========================================================================

-- Start from an explicit deny posture.
revoke all on schema app from public, anon, authenticated;
revoke all on schema app_private from public, anon, authenticated;
revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;
revoke all on all functions in schema app from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;

-- The Data API may expose app, but app_private must remain unexposed.
grant usage on schema app to authenticated, service_role;
grant usage on schema public to authenticated, service_role;

-- RLS policies execute only these private helpers. app_private must remain
-- absent from the project's exposed-schema list.
grant usage on schema app_private to authenticated;
grant execute on function app_private.current_user_email() to authenticated, service_role;
grant execute on function app_private.has_active_association_access(uuid, uuid) to authenticated, service_role;
grant execute on function app_private.has_association_role(uuid, app.association_role[], uuid) to authenticated, service_role;
grant execute on function app_private.can_administer_association(uuid, uuid) to authenticated, service_role;

-- Authenticated users receive read privileges only where RLS policies exist.
grant select on app.profiles to authenticated;
grant update (display_name, phone, preferred_locale) on app.profiles to authenticated;

grant select on app.audit_event_types to authenticated;
grant select on app.associations to authenticated;
grant select on app.association_names to authenticated;
grant select on app.association_lifecycle_history to authenticated;
grant select on app.association_operational_settings to authenticated;
grant select on app.association_user_access to authenticated;
grant select on app.association_user_access_status_history to authenticated;
grant select (
  id,
  association_id,
  invited_email,
  invited_role,
  status,
  expires_at,
  invited_by,
  invitation_message,
  accepted_at,
  accepted_by,
  resulting_access_id,
  cancelled_at,
  cancelled_by,
  cancellation_reason,
  created_at,
  updated_at,
  updated_by
) on app.association_invitations to authenticated;
grant select on app.audit_events to authenticated;
grant select on app.v_my_association_access to authenticated;
grant select on app.v_association_dashboard to authenticated;

-- Exposed transactional RPCs.
revoke execute on function public.create_association(
  text, text, date, app.date_certainty, text, text, app.date_format
) from public, anon, authenticated;
revoke execute on function public.change_association_official_name(
  uuid, text, date, app.date_certainty, text, app.record_origin
) from public, anon, authenticated;
revoke execute on function public.change_association_lifecycle(
  uuid, app.association_lifecycle_state, date, app.date_certainty, text, app.record_origin
) from public, anon, authenticated;
revoke execute on function public.update_association_operational_settings(
  uuid, text, text, app.date_format, boolean, smallint
) from public, anon, authenticated;
revoke execute on function public.grant_association_access(
  uuid, uuid, app.association_role, text, app.record_origin
) from public, anon, authenticated;
revoke execute on function public.suspend_association_access(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.resume_association_access(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.revoke_association_access(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.change_association_access_role(
  uuid, app.association_role, text
) from public, anon, authenticated;
revoke execute on function public.transfer_primary_association_admin(
  uuid, uuid, text
) from public, anon, authenticated;
revoke execute on function public.create_association_invitation(
  uuid, text, app.association_role, interval, text
) from public, anon, authenticated;
revoke execute on function public.accept_association_invitation(text)
  from public, anon, authenticated;
revoke execute on function public.cancel_association_invitation(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.expire_pending_association_invitations()
  from public, anon, authenticated;

grant execute on function public.create_association(
  text, text, date, app.date_certainty, text, text, app.date_format
) to authenticated, service_role;

grant execute on function public.change_association_official_name(
  uuid, text, date, app.date_certainty, text, app.record_origin
) to authenticated, service_role;

grant execute on function public.change_association_lifecycle(
  uuid, app.association_lifecycle_state, date, app.date_certainty, text, app.record_origin
) to authenticated, service_role;

grant execute on function public.update_association_operational_settings(
  uuid, text, text, app.date_format, boolean, smallint
) to authenticated, service_role;

grant execute on function public.grant_association_access(
  uuid, uuid, app.association_role, text, app.record_origin
) to authenticated, service_role;

grant execute on function public.suspend_association_access(uuid, text)
  to authenticated, service_role;

grant execute on function public.resume_association_access(uuid, text)
  to authenticated, service_role;

grant execute on function public.revoke_association_access(uuid, text)
  to authenticated, service_role;

grant execute on function public.change_association_access_role(
  uuid, app.association_role, text
) to authenticated, service_role;

grant execute on function public.transfer_primary_association_admin(
  uuid, uuid, text
) to authenticated, service_role;

grant execute on function public.create_association_invitation(
  uuid, text, app.association_role, interval, text
) to authenticated, service_role;

grant execute on function public.accept_association_invitation(text)
  to authenticated, service_role;

grant execute on function public.cancel_association_invitation(uuid, text)
  to authenticated, service_role;

grant execute on function public.expire_pending_association_invitations()
  to service_role;

-- service_role retains explicit operational access and bypasses RLS in
-- standard Supabase projects. It is never granted to browser clients.
grant all privileges on all tables in schema app to service_role;
grant all privileges on all sequences in schema app to service_role;
grant execute on all functions in schema app_private to service_role;
grant usage on schema app_private to service_role;

-- Future objects inherit the same deny-by-default posture.
alter default privileges in schema app
  revoke all on tables from public, anon, authenticated;

alter default privileges in schema app
  revoke all on sequences from public, anon, authenticated;

alter default privileges in schema app
  revoke execute on functions from public, anon, authenticated;

alter default privileges in schema app_private
  revoke execute on functions from public, anon, authenticated;

commit;
