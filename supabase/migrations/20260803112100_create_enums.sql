-- ASSOCIEDADPLUS
-- Onda 1 — Lote A
-- Migration 02 — Enums
-- File: 20260803112100_create_enums.sql

begin;

-- ---------------------------------------------------------------------------
-- 1. Global profile status
-- ---------------------------------------------------------------------------

create type app.profile_status as enum (
  'ACTIVE',
  'SUSPENDED',
  'DEACTIVATED'
);

comment on type app.profile_status is
  'Technical status of a platform profile. It does not represent association membership or institutional office.';

-- ---------------------------------------------------------------------------
-- 2. Association platform status
-- ---------------------------------------------------------------------------

create type app.association_platform_status as enum (
  'ACTIVE',
  'SUSPENDED',
  'ARCHIVED'
);

comment on type app.association_platform_status is
  'Technical status of an association tenant within the platform, separate from its institutional lifecycle.';

-- ---------------------------------------------------------------------------
-- 3. Association institutional lifecycle
-- ---------------------------------------------------------------------------

create type app.association_lifecycle_state as enum (
  'EM_CONSTITUICAO',
  'ATIVA',
  'INATIVA',
  'EM_DISSOLUCAO',
  'ENCERRADA'
);

comment on type app.association_lifecycle_state is
  'Institutional lifecycle state of an association. Historical periods are stored in association_lifecycle_history.';

-- ---------------------------------------------------------------------------
-- 4. Association names
-- ---------------------------------------------------------------------------

create type app.association_name_type as enum (
  'OFFICIAL',
  'USAGE',
  'ACRONYM'
);

comment on type app.association_name_type is
  'Kind of institutional name recorded for an association.';

create type app.association_name_status as enum (
  'PROPOSED',
  'EFFECTIVE',
  'HISTORICAL',
  'REJECTED',
  'WITHDRAWN'
);

comment on type app.association_name_status is
  'Status of an institutional name record, including proposed and historical names.';

-- ---------------------------------------------------------------------------
-- 5. Temporal certainty and record origin
-- ---------------------------------------------------------------------------

create type app.date_certainty as enum (
  'EXACT',
  'APPROXIMATE',
  'UNKNOWN'
);

comment on type app.date_certainty is
  'Degree of certainty assigned to a civil date without inventing unavailable historical information.';

create type app.record_origin as enum (
  'MANUAL',
  'DOCUMENT',
  'IMPORT',
  'SYSTEM',
  'INVITATION',
  'ADMINISTRATIVE_CORRECTION'
);

comment on type app.record_origin is
  'Controlled origin of a domain record or historical transition.';

-- ---------------------------------------------------------------------------
-- 6. Operational settings
-- ---------------------------------------------------------------------------

create type app.date_format as enum (
  'DMY',
  'MDY',
  'YMD'
);

comment on type app.date_format is
  'Preferred civil date display order for an association.';

-- ---------------------------------------------------------------------------
-- 7. Association access and invitations
-- ---------------------------------------------------------------------------

create type app.association_role as enum (
  'ADMIN_PRINCIPAL',
  'ADMIN_ASSOCIACAO',
  'OPERADOR',
  'CONSULTA'
);

comment on type app.association_role is
  'Platform authorization role within one association; it does not represent an institutional office.';

create type app.association_access_status as enum (
  'ACTIVE',
  'SUSPENDED',
  'REVOKED',
  'EXPIRED'
);

comment on type app.association_access_status is
  'Current projected status of one association access cycle.';

create type app.association_invitation_status as enum (
  'PENDING',
  'ACCEPTED',
  'CANCELLED',
  'EXPIRED'
);

comment on type app.association_invitation_status is
  'Lifecycle status of a single-use association access invitation.';

-- ---------------------------------------------------------------------------
-- 8. Audit event type classification
-- ---------------------------------------------------------------------------

create type app.audit_event_category as enum (
  'PROFILE',
  'ASSOCIATION',
  'NAME',
  'LIFECYCLE',
  'SETTINGS',
  'ACCESS',
  'INVITATION',
  'SECURITY',
  'AUDIT'
);

comment on type app.audit_event_category is
  'Stable technical category used to group audit event type definitions.';

create type app.audit_sensitivity as enum (
  'NORMAL',
  'SENSITIVE',
  'RESTRICTED'
);

comment on type app.audit_sensitivity is
  'Sensitivity classification that controls exposure of audit event data.';

-- ---------------------------------------------------------------------------
-- 9. Audit event execution context
-- ---------------------------------------------------------------------------

create type app.audit_actor_type as enum (
  'USER',
  'SYSTEM',
  'SERVICE_ROLE'
);

comment on type app.audit_actor_type is
  'Technical kind of actor responsible for an audit event.';

create type app.audit_event_origin as enum (
  'WEB_APP',
  'RPC',
  'DATABASE_TRIGGER',
  'SYSTEM_PROCESS',
  'ADMINISTRATIVE_CORRECTION'
);

comment on type app.audit_event_origin is
  'Technical execution channel from which an audit event originated.';

create type app.audit_event_result as enum (
  'SUCCESS',
  'FAILURE',
  'DENIED'
);

comment on type app.audit_event_result is
  'Technical result of the audited operation.';

-- ---------------------------------------------------------------------------
-- 10. Controlled audit targets for Lote A
-- ---------------------------------------------------------------------------

create type app.audit_target_type as enum (
  'ASSOCIATION',
  'ASSOCIATION_NAME',
  'ASSOCIATION_LIFECYCLE',
  'ASSOCIATION_SETTINGS',
  'ASSOCIATION_ACCESS',
  'ASSOCIATION_ACCESS_STATUS',
  'ASSOCIATION_INVITATION'
);

comment on type app.audit_target_type is
  'Closed list of Lote A target types accepted by the controlled audit recording function.';

commit;
