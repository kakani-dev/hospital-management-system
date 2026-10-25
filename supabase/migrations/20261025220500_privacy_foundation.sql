-- cross-schema: approved (privacy calls identity.has_tenant_permission, identity.current_tenant_ids,
-- identity.my_tenant_grant_v1, identity.my_active_context, patient.patient_exists_v1,
-- patient.patient_summary_v1, appointment.patient_has_open_visits_v1, messaging.enqueue,
-- and audit.stamp_audit_columns / audit.system_actor. No table reads outside privacy.
-- Login hms_privacy_login stays out of band. consent_event is append-only and is not
-- partitioned: monthly partitions need pg_partman on hosted Supabase, which this slice
-- does not enable.)
-- DPDP consent ledger, privacy notices, and data-principal requests for the privacy service.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'hms_svc_privacy') then
    create role hms_svc_privacy nologin noinherit;
  end if;
end
$$;

grant anon to hms_svc_privacy;
revoke authenticated from hms_svc_privacy;

comment on role hms_svc_privacy is
  'Privacy service session role (Database:SessionRole). Owns no tables. Reads other services only through published _v1 functions.';

create schema if not exists privacy;
revoke all on schema privacy from public;
grant usage on schema privacy to hms_svc_privacy, anon;

comment on schema privacy is
  'DPDP consent and data-principal requests. Owned by the privacy service. Patient, visit, and bill facts stay in their own services.';

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------- helpers ----
create or replace function privacy.uuid_v7()
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_time bytea;
  v_bytes bytea;
begin
  v_time := substring(pg_catalog.int8send((extract(epoch from pg_catalog.clock_timestamp()) * 1000)::bigint) from 3 for 6);
  v_bytes := v_time || substring(pg_catalog.uuid_send(pg_catalog.gen_random_uuid()) from 7 for 10);
  v_bytes := pg_catalog.set_byte(v_bytes, 6, (pg_catalog.get_byte(v_bytes, 6) & 15) | 112);
  v_bytes := pg_catalog.set_byte(v_bytes, 8, (pg_catalog.get_byte(v_bytes, 8) & 63) | 128);
  return encode(v_bytes, 'hex')::uuid;
end;
$$;

create or replace function privacy.sha256_hex(p_text text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_schema text;
  v_hash text;
begin
  select n.nspname into v_schema
  from pg_catalog.pg_extension e
  join pg_catalog.pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';
  if v_schema is null then
    raise exception 'pgcrypto is required' using errcode = '55000';
  end if;
  execute format('select encode(%I.digest(convert_to($1, ''UTF8''), ''sha256''), ''hex'')', v_schema)
    into v_hash using coalesce(p_text, '');
  return v_hash;
end;
$$;

create or replace function privacy.fail(p_code text, p_detail text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%|%', p_code, p_detail using errcode = 'P0001';
end;
$$;

-- plpgsql so 'privacy.consent_notice'::regclass is resolved at call time. A SQL
-- function body is parsed at CREATE, and this helper is declared before the table.
create or replace function privacy.bypass_acl()
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_owner name;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
  from pg_catalog.pg_class c
  where c.oid = 'privacy.consent_notice'::regclass;
  return v_owner = session_user;
end;
$$;

create or replace function privacy.assert_permission(p_tenant_id uuid, p_permission text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if privacy.bypass_acl() then
    return;
  end if;
  if p_tenant_id is null or not identity.has_tenant_permission(p_tenant_id, p_permission) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
end;
$$;

create or replace function privacy.assert_any(p_tenant_id uuid, p_permissions text[])
returns void
language plpgsql
set search_path = ''
as $$
begin
  if privacy.bypass_acl() then
    return;
  end if;
  if p_tenant_id is null or not exists (
    select 1 from pg_catalog.unnest(p_permissions) p(permission)
    where identity.has_tenant_permission(p_tenant_id, p.permission)
  ) then
    raise exception 'permission denied' using errcode = '42501';
  end if;
end;
$$;

create or replace function privacy.actor()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(auth.uid(), audit.system_actor())
$$;

create or replace function privacy.fy_code(p_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when extract(month from (p_at at time zone 'UTC')) >= 4
      then to_char(p_at at time zone 'UTC', 'YYYY')
    else to_char((p_at at time zone 'UTC') - interval '1 year', 'YYYY')
  end
$$;

create or replace function privacy.purpose_ok(p_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_code in ('reminders', 'marketing', 'research', 'abdm_share')
$$;

create or replace function privacy.purpose_label(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_code
    when 'reminders' then 'Appointment and follow-up reminders (WhatsApp/SMS)'
    when 'marketing' then 'Health camps and offers'
    when 'research' then 'Anonymised research'
    when 'abdm_share' then 'Share my health record on ABDM'
    else p_code
  end
$$;

create or replace function privacy.language_ok(p_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_code in ('en', 'hi', 'te', 'ta', 'kn', 'ml', 'mr', 'bn', 'gu', 'pa', 'or', 'as', 'ur')
$$;

create or replace function privacy.reject_client_code(p_body jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_body ? 'code' or p_body ? 'version' or p_body ? 'id'
     or p_body ? 'tenantId' or p_body ? 'tenant_id' then
    perform privacy.fail('invalid_parameter', 'Codes are generated automatically; leave this field empty.');
  end if;
end;
$$;

-- --------------------------------------------------------------------- tables ----
create table privacy.code_seq (
  tenant_id   uuid not null,
  kind        text not null,
  last_value  bigint not null default 0,
  created_on  timestamptz not null default now(),
  created_by  uuid not null,
  updated_on  timestamptz not null default now(),
  updated_by  uuid not null,
  is_deleted  boolean not null default false,
  primary key (tenant_id, kind),
  constraint code_seq_kind check (kind ~ '^[a-z0-9-]{1,40}$'),
  constraint code_seq_non_negative check (last_value >= 0),
  constraint code_seq_never_deleted check (not is_deleted)
);
comment on table privacy.code_seq is
  'Per-hospital counters for notice versions and rights-request numbers. A number is never reused.';

create table privacy.consent_notice (
  id              uuid not null default privacy.uuid_v7(),
  tenant_id       uuid not null,
  version         integer not null,
  language_code   text not null,
  title           text not null,
  body            text not null,
  content_sha256  text not null,
  content_uri     text,
  published_at    timestamptz,
  published_by    uuid,
  created_on      timestamptz not null default now(),
  created_by      uuid not null,
  updated_on      timestamptz not null default now(),
  updated_by      uuid not null,
  is_deleted      boolean not null default false,
  primary key (tenant_id, id),
  constraint consent_notice_version_key unique (tenant_id, version, language_code),
  constraint consent_notice_version_positive check (version > 0),
  constraint consent_notice_language check (language_code ~ '^[a-z]{2}$'),
  constraint consent_notice_title check (char_length(btrim(title)) between 1 and 200),
  constraint consent_notice_body check (char_length(body) between 40 and 20000),
  constraint consent_notice_hash check (content_sha256 ~ '^[0-9a-f]{64}$')
);
comment on table privacy.consent_notice is
  'Versioned privacy notice. A published row never changes. Treatment and billing are legitimate use and are not toggles.';

create table privacy.consent_notice_purpose (
  tenant_id     uuid not null,
  notice_id     uuid not null,
  purpose_code  text not null,
  created_on    timestamptz not null default now(),
  created_by    uuid not null,
  updated_on    timestamptz not null default now(),
  updated_by    uuid not null,
  is_deleted    boolean not null default false,
  primary key (tenant_id, notice_id, purpose_code),
  constraint consent_notice_purpose_notice_fk
    foreign key (tenant_id, notice_id) references privacy.consent_notice (tenant_id, id),
  constraint consent_notice_purpose_code check (purpose_code in ('reminders', 'marketing', 'research', 'abdm_share'))
);

create table privacy.consent_event (
  id                 bigint generated always as identity,
  tenant_id          uuid not null,
  patient_id         uuid not null,
  purpose_code       text not null,
  action             text not null,
  notice_id          uuid not null,
  given_by           text not null,
  related_person_id  uuid,
  guardian_name      text,
  channel            text not null,
  evidence_uri       text,
  occurred_at        timestamptz not null default now(),
  created_on         timestamptz not null default now(),
  created_by         uuid not null,
  updated_on         timestamptz not null default now(),
  updated_by         uuid not null,
  is_deleted         boolean not null default false,
  primary key (tenant_id, id),
  constraint consent_event_notice_fk
    foreign key (tenant_id, notice_id) references privacy.consent_notice (tenant_id, id),
  constraint consent_event_action check (action in ('grant', 'withdraw')),
  constraint consent_event_purpose check (purpose_code in ('reminders', 'marketing', 'research', 'abdm_share')),
  constraint consent_event_given_by check (given_by in ('self', 'guardian', 'staff')),
  constraint consent_event_channel check (channel in ('tablet', 'staff_readout', 'paper', 'link')),
  constraint consent_event_guardian check (given_by <> 'guardian' or guardian_name is not null or related_person_id is not null)
);
comment on table privacy.consent_event is
  'Append-only consent ledger. Rows are never updated. Not partitioned in this slice.';
create index consent_event_latest_idx
  on privacy.consent_event (tenant_id, patient_id, purpose_code, occurred_at desc, id desc);

create table privacy.consent_link (
  id           uuid not null default privacy.uuid_v7(),
  tenant_id    uuid not null,
  patient_id   uuid not null,
  notice_id    uuid not null,
  token_hash   text not null,
  expires_at   timestamptz not null,
  used_at      timestamptz,
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  primary key (tenant_id, id),
  constraint consent_link_token_key unique (tenant_id, token_hash),
  constraint consent_link_notice_fk
    foreign key (tenant_id, notice_id) references privacy.consent_notice (tenant_id, id),
  constraint consent_link_hash check (token_hash ~ '^[0-9a-f]{64}$')
);
create index consent_link_token_idx on privacy.consent_link (tenant_id, token_hash);
comment on table privacy.consent_link is
  'One-time consent link. Only the SHA-256 of the token is stored. The raw token is returned once and is not a patient identifier.';

create table privacy.rights_request (
  id                  uuid not null default privacy.uuid_v7(),
  tenant_id           uuid not null,
  code                text not null,
  patient_id          uuid not null,
  request_type        text not null,
  details             text not null,
  channel             text not null,
  status              text not null default 'received',
  received_at         timestamptz not null default now(),
  due_at              timestamptz not null,
  verified_at         timestamptz,
  verified_by         uuid,
  fulfilled_at        timestamptz,
  fulfilled_by        uuid,
  closed_at           timestamptz,
  closed_by           uuid,
  response_text       text,
  correction          jsonb,
  due_soon_emitted    boolean not null default false,
  created_on          timestamptz not null default now(),
  created_by          uuid not null,
  updated_on          timestamptz not null default now(),
  updated_by          uuid not null,
  is_deleted          boolean not null default false,
  primary key (tenant_id, id),
  constraint rights_request_code_key unique (tenant_id, code),
  constraint rights_request_type check (request_type in ('access', 'correction', 'erasure', 'grievance', 'nomination')),
  constraint rights_request_channel check (channel in ('desk', 'link', 'email', 'whatsapp')),
  constraint rights_request_status check (status in ('received', 'verified', 'fulfilled', 'closed', 'held')),
  constraint rights_request_details check (char_length(btrim(details)) between 1 and 4000),
  constraint rights_request_code_shape check (code ~ '^DPR-[0-9]{4}-[0-9]{5}$')
);
comment on table privacy.rights_request is
  'Data-principal request. Code is DPR-<financial year>-00001. Due 90 days after receipt (DPDP Rules).';
create index rights_request_queue_idx
  on privacy.rights_request (tenant_id, status, due_at);

create table privacy.rights_request_event (
  id           bigint generated always as identity,
  tenant_id    uuid not null,
  request_id   uuid not null,
  action       text not null,
  actor_id     uuid not null,
  note         text,
  occurred_at  timestamptz not null default now(),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  primary key (tenant_id, id),
  constraint rights_request_event_request_fk
    foreign key (tenant_id, request_id) references privacy.rights_request (tenant_id, id),
  constraint rights_request_event_action check (
    action in ('created', 'verified', 'fulfilled', 'closed', 'held', 'erased', 'due_soon', 'approved'))
);
comment on table privacy.rights_request_event is
  'Append-only audit trail for a data-principal request. The generic audit log cannot store a bigint id.';
create index rights_request_event_request_idx
  on privacy.rights_request_event (tenant_id, request_id, occurred_at);

create table privacy.erasure_item (
  tenant_id              uuid not null,
  request_id             uuid not null,
  data_category          text not null,
  action                 text not null,
  retention_policy_code  text,
  reason                 text not null,
  created_on             timestamptz not null default now(),
  created_by             uuid not null,
  updated_on             timestamptz not null default now(),
  updated_by             uuid not null,
  is_deleted             boolean not null default false,
  primary key (tenant_id, request_id, data_category),
  constraint erasure_item_request_fk
    foreign key (tenant_id, request_id) references privacy.rights_request (tenant_id, id),
  constraint erasure_item_action check (action in ('anonymised', 'retained')),
  constraint erasure_item_category check (
    data_category in ('contact_copies', 'consent_ledger', 'clinical_opd', 'billing_gst'))
);

create table privacy.erasure_approval (
  tenant_id    uuid not null,
  request_id   uuid not null,
  approver_id  uuid not null,
  approved_at  timestamptz not null default now(),
  created_on   timestamptz not null default now(),
  created_by   uuid not null,
  updated_on   timestamptz not null default now(),
  updated_by   uuid not null,
  is_deleted   boolean not null default false,
  primary key (tenant_id, request_id, approver_id),
  constraint erasure_approval_request_fk
    foreign key (tenant_id, request_id) references privacy.rights_request (tenant_id, id)
);
comment on table privacy.erasure_approval is
  'One row per person who approved an erasure. Execution needs two different people.';

create table privacy.command_receipt (
  tenant_id        uuid not null,
  idempotency_key  uuid not null,
  command          text not null,
  request_sha256   text not null,
  response         jsonb not null,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  primary key (tenant_id, idempotency_key),
  constraint command_receipt_hash check (request_sha256 ~ '^[0-9a-f]{64}$')
);
comment on table privacy.command_receipt is
  'Idempotency-Key receipts. The same key and body returns the first response. A different body is rejected.';

create table privacy.patient_alias (
  tenant_id        uuid not null,
  from_patient_id  uuid not null,
  to_patient_id    uuid not null,
  created_on       timestamptz not null default now(),
  created_by       uuid not null,
  updated_on       timestamptz not null default now(),
  updated_by       uuid not null,
  is_deleted       boolean not null default false,
  primary key (tenant_id, from_patient_id),
  constraint patient_alias_distinct check (from_patient_id <> to_patient_id)
);
comment on table privacy.patient_alias is
  'Merge map. Consent events stay on the original patient id. Reads follow the map. The patients service does not call this yet.';

-- --------------------------------------------------------------------- triggers ----
create or replace function privacy.stamp_notice_hash()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.content_sha256 := privacy.sha256_hex(new.body);
  return new;
end;
$$;

create or replace function privacy.reject_published_notice_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.published_at is not null then
    perform privacy.fail('published_immutable', 'A published privacy notice cannot be changed.');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function privacy.reject_published_purpose_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_notice uuid;
  v_published timestamptz;
begin
  v_tenant := coalesce(new.tenant_id, old.tenant_id);
  v_notice := coalesce(new.notice_id, old.notice_id);
  select n.published_at into v_published
  from privacy.consent_notice n
  where n.tenant_id = v_tenant and n.id = v_notice;
  if v_published is not null then
    perform privacy.fail('published_immutable', 'A published privacy notice cannot be changed.');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function privacy.reject_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'consent_event is append-only' using errcode = 'P0001';
end;
$$;

create or replace function privacy.reject_request_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'rights_request_event is append-only' using errcode = 'P0001';
end;
$$;

create trigger code_seq_audit_columns before insert or update on privacy.code_seq
  for each row execute function audit.stamp_audit_columns();
create trigger code_seq_tenant_immutable before update on privacy.code_seq
  for each row execute function audit.prevent_tenant_change();

create trigger consent_notice_hash before insert or update on privacy.consent_notice
  for each row execute function privacy.stamp_notice_hash();
create trigger a_consent_notice_immutable before update or delete on privacy.consent_notice
  for each row execute function privacy.reject_published_notice_change();
create trigger consent_notice_audit_columns before insert or update on privacy.consent_notice
  for each row execute function audit.stamp_audit_columns();
create trigger consent_notice_tenant_immutable before update on privacy.consent_notice
  for each row execute function audit.prevent_tenant_change();
create trigger consent_notice_audit_log after insert or update or delete on privacy.consent_notice
  for each row execute function audit.log_row_change();

create trigger a_consent_notice_purpose_lock before insert or update or delete on privacy.consent_notice_purpose
  for each row execute function privacy.reject_published_purpose_change();
create trigger consent_notice_purpose_audit_columns before insert or update on privacy.consent_notice_purpose
  for each row execute function audit.stamp_audit_columns();
create trigger consent_notice_purpose_tenant_immutable before update on privacy.consent_notice_purpose
  for each row execute function audit.prevent_tenant_change();

create trigger consent_event_audit_columns before insert or update on privacy.consent_event
  for each row execute function audit.stamp_audit_columns();
create trigger a_consent_event_immutable before update or delete on privacy.consent_event
  for each row execute function privacy.reject_event_change();
create trigger consent_event_tenant_immutable before update on privacy.consent_event
  for each row execute function audit.prevent_tenant_change();

create trigger consent_link_audit_columns before insert or update on privacy.consent_link
  for each row execute function audit.stamp_audit_columns();
create trigger consent_link_tenant_immutable before update on privacy.consent_link
  for each row execute function audit.prevent_tenant_change();
create trigger consent_link_audit_log after insert or update or delete on privacy.consent_link
  for each row execute function audit.log_row_change();

create trigger rights_request_audit_columns before insert or update on privacy.rights_request
  for each row execute function audit.stamp_audit_columns();
create trigger rights_request_tenant_immutable before update on privacy.rights_request
  for each row execute function audit.prevent_tenant_change();
create trigger rights_request_audit_log after insert or update or delete on privacy.rights_request
  for each row execute function audit.log_row_change();

create trigger rights_request_event_audit_columns before insert or update on privacy.rights_request_event
  for each row execute function audit.stamp_audit_columns();
create trigger a_rights_request_event_immutable before update or delete on privacy.rights_request_event
  for each row execute function privacy.reject_request_event_change();
create trigger rights_request_event_tenant_immutable before update on privacy.rights_request_event
  for each row execute function audit.prevent_tenant_change();

create trigger erasure_item_audit_columns before insert or update on privacy.erasure_item
  for each row execute function audit.stamp_audit_columns();
create trigger erasure_item_tenant_immutable before update on privacy.erasure_item
  for each row execute function audit.prevent_tenant_change();

create trigger erasure_approval_audit_columns before insert or update on privacy.erasure_approval
  for each row execute function audit.stamp_audit_columns();
create trigger erasure_approval_tenant_immutable before update on privacy.erasure_approval
  for each row execute function audit.prevent_tenant_change();

create trigger command_receipt_audit_columns before insert or update on privacy.command_receipt
  for each row execute function audit.stamp_audit_columns();
create trigger command_receipt_tenant_immutable before update on privacy.command_receipt
  for each row execute function audit.prevent_tenant_change();

create trigger patient_alias_audit_columns before insert or update on privacy.patient_alias
  for each row execute function audit.stamp_audit_columns();
create trigger patient_alias_tenant_immutable before update on privacy.patient_alias
  for each row execute function audit.prevent_tenant_change();
create trigger patient_alias_audit_log after insert or update or delete on privacy.patient_alias
  for each row execute function audit.log_row_change();

create view privacy.consent_current
with (security_invoker = true) as
select distinct on (e.tenant_id, e.patient_id, e.purpose_code)
  e.tenant_id, e.patient_id, e.purpose_code, e.action, e.notice_id, e.occurred_at, e.id
from privacy.consent_event e
where not e.is_deleted
order by e.tenant_id, e.patient_id, e.purpose_code, e.occurred_at desc, e.id desc;
comment on view privacy.consent_current is
  'Latest consent event per patient and purpose. security_invoker so RLS applies to direct reads.';

-- --------------------------------------------------------------------- commands ----
create or replace function privacy.next_number(p_tenant_id uuid, p_kind text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n bigint;
begin
  insert into privacy.code_seq (tenant_id, kind, last_value)
  values (p_tenant_id, p_kind, 1)
  on conflict (tenant_id, kind) do update
    set last_value = privacy.code_seq.last_value + 1
  returning last_value into v_n;
  return v_n;
end;
$$;

create or replace function privacy.chart_ids(p_tenant_id uuid, p_patient_id uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  with recursive up as (
    select p_patient_id as id, 0 as n
    union all
    select a.to_patient_id, u.n + 1
    from up u
    join privacy.patient_alias a
      on a.tenant_id = p_tenant_id and a.from_patient_id = u.id and not a.is_deleted
    where u.n < 5
  ),
  survivor as (
    select id from up order by n desc limit 1
  ),
  members as (
    select (select id from survivor) as id
    union
    select a.from_patient_id
    from privacy.patient_alias a
    where a.tenant_id = p_tenant_id
      and a.to_patient_id = (select id from survivor)
      and not a.is_deleted
  )
  select coalesce(array_agg(id), array[p_patient_id]) from members
$$;

create or replace function privacy.replay(p_tenant_id uuid, p_key uuid, p_command text, p_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_response jsonb;
  v_command text;
begin
  if p_key is null then
    perform privacy.fail('invalid_parameter', 'Idempotency-Key must be a UUID.');
  end if;
  select request_sha256, response, command
    into v_hash, v_response, v_command
  from privacy.command_receipt
  where tenant_id = p_tenant_id and idempotency_key = p_key and not is_deleted;
  if not found then
    return null;
  end if;
  if v_command is distinct from p_command or v_hash is distinct from p_hash then
    perform privacy.fail('invalid_parameter', 'This Idempotency-Key was already used for a different request.');
  end if;
  return v_response;
end;
$$;

create or replace function privacy.remember(p_tenant_id uuid, p_key uuid, p_command text, p_hash text, p_response jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into privacy.command_receipt (tenant_id, idempotency_key, command, request_sha256, response)
  values (p_tenant_id, p_key, p_command, p_hash, p_response);
  return p_response;
exception
  when unique_violation then
    perform privacy.fail('invalid_parameter', 'This Idempotency-Key was already used for a different request.');
end;
$$;

create or replace function privacy.require_patient(p_tenant_id uuid, p_patient_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_patient_id is null or not patient.patient_exists_v1(p_tenant_id, p_patient_id) then
    raise exception 'patient not found' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function privacy.notice_json(p_tenant_id uuid, p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'noticeId', n.id,
    'version', n.version,
    'language', n.language_code,
    'title', n.title,
    'body', n.body,
    'uri', n.content_uri,
    'contentSha256', n.content_sha256,
    'publishedAt', n.published_at,
    'purposes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', p.purpose_code,
        'label', privacy.purpose_label(p.purpose_code),
        'required', false
      ) order by p.purpose_code)
      from privacy.consent_notice_purpose p
      where p.tenant_id = n.tenant_id and p.notice_id = n.id and not p.is_deleted
    ), '[]'::jsonb)
  )
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.id = p_id and not n.is_deleted
$$;

create or replace function privacy.current_notice(p_tenant_id uuid, p_language text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_lang text := coalesce(nullif(lower(btrim(p_language)), ''), 'en');
  v_id uuid;
begin
  perform privacy.assert_any(p_tenant_id, array['privacy.view', 'privacy.consent', 'privacy.notice']);
  if not privacy.language_ok(v_lang) then
    perform privacy.fail('invalid_parameter', 'Choose English or an Eighth Schedule language.');
  end if;
  select n.id into v_id
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.language_code = v_lang
    and n.published_at is not null and not n.is_deleted
  order by n.version desc
  limit 1;
  if v_id is null then
    perform privacy.fail('no_published_notice', 'Publish a privacy notice in Admin › Privacy first.');
  end if;
  return privacy.notice_json(p_tenant_id, v_id);
end;
$$;

create or replace function privacy.list_notices(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform privacy.assert_any(p_tenant_id, array['privacy.view', 'privacy.notice']);
  return coalesce((
    select jsonb_agg(privacy.notice_json(n.tenant_id, n.id) order by n.language_code, n.version desc)
    from privacy.consent_notice n
    where n.tenant_id = p_tenant_id and not n.is_deleted
  ), '[]'::jsonb);
end;
$$;

create or replace function privacy.create_notice(p_tenant_id uuid, p_key uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_body::text);
  v_replay jsonb;
  v_lang text := lower(btrim(p_body ->> 'language'));
  v_title text := btrim(p_body ->> 'title');
  v_body text := p_body ->> 'body';
  v_uri text := nullif(btrim(p_body ->> 'contentUri'), '');
  v_version integer;
  v_id uuid;
  v_purpose text;
  v_seen text[] := array[]::text[];
  v_response jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.notice');
  perform privacy.reject_client_code(p_body);
  v_replay := privacy.replay(p_tenant_id, p_key, 'create_notice', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  if not privacy.language_ok(v_lang) then
    perform privacy.fail('invalid_parameter', 'Choose English or an Eighth Schedule language.');
  end if;
  if v_title is null or v_title = '' then
    perform privacy.fail('invalid_parameter', 'Give the notice a title.');
  end if;
  if v_body is null or char_length(v_body) < 40 then
    perform privacy.fail('invalid_parameter', 'Write the notice in plain language. A short sentence is not enough.');
  end if;
  if jsonb_typeof(p_body -> 'purposes') is distinct from 'array'
     or jsonb_array_length(p_body -> 'purposes') = 0 then
    perform privacy.fail('invalid_parameter', 'List the purposes this notice covers.');
  end if;
  v_version := privacy.next_number(p_tenant_id, 'notice-' || v_lang)::integer;
  insert into privacy.consent_notice (tenant_id, version, language_code, title, body, content_sha256, content_uri)
  values (p_tenant_id, v_version, v_lang, v_title, v_body, repeat('0', 64), v_uri)
  returning id into v_id;
  for v_purpose in select jsonb_array_elements_text(p_body -> 'purposes')
  loop
    if not privacy.purpose_ok(v_purpose) then
      perform privacy.fail('invalid_parameter', 'Unknown purpose. Use reminders, marketing, research, or abdm_share.');
    end if;
    if v_purpose = any (v_seen) then
      perform privacy.fail('invalid_parameter', 'Each purpose is listed once.');
    end if;
    v_seen := v_seen || v_purpose;
    insert into privacy.consent_notice_purpose (tenant_id, notice_id, purpose_code)
    values (p_tenant_id, v_id, v_purpose);
  end loop;
  v_response := privacy.notice_json(p_tenant_id, v_id);
  return privacy.remember(p_tenant_id, p_key, 'create_notice', v_hash, v_response);
end;
$$;

create or replace function privacy.publish_notice(p_tenant_id uuid, p_key uuid, p_notice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_notice_id::text);
  v_replay jsonb;
  v_published timestamptz;
  v_response jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.notice');
  v_replay := privacy.replay(p_tenant_id, p_key, 'publish_notice', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  select n.published_at into v_published
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.id = p_notice_id and not n.is_deleted;
  if not found then
    raise exception 'notice not found' using errcode = 'P0002';
  end if;
  if v_published is not null then
    perform privacy.fail('published_immutable', 'A published privacy notice cannot be changed.');
  end if;
  update privacy.consent_notice
     set published_at = pg_catalog.clock_timestamp(),
         published_by = privacy.actor()
   where tenant_id = p_tenant_id and id = p_notice_id;
  v_response := privacy.notice_json(p_tenant_id, p_notice_id);
  return privacy.remember(p_tenant_id, p_key, 'publish_notice', v_hash, v_response);
end;
$$;

create or replace function privacy.latest_granted(p_tenant_id uuid, p_patient_id uuid, p_purpose text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select e.action = 'grant'
    from privacy.consent_event e
    where e.tenant_id = p_tenant_id
      and e.patient_id = any (privacy.chart_ids(p_tenant_id, p_patient_id))
      and e.purpose_code = p_purpose
      and not e.is_deleted
    order by e.occurred_at desc, e.id desc
    limit 1
  ), false)
$$;

-- cross-schema: approved (published v1 purpose gate; messaging and CRM are not granted it yet)
create or replace function privacy.consent_allows_v1(p_tenant_id uuid, p_patient_id uuid, p_purpose text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if not privacy.purpose_ok(p_purpose) then
    return false;
  end if;
  return privacy.latest_granted(p_tenant_id, p_patient_id, p_purpose);
end;
$$;

comment on function privacy.consent_allows_v1(uuid, uuid, text) is
  'v1 (published by privacy): true when the latest consent event for that purpose is a grant. No consent means false. A signed-in caller outside the hospital gets P0002.';

create or replace function privacy.write_consent(
  p_tenant_id uuid, p_patient_id uuid, p_notice_id uuid, p_purpose text, p_granted boolean,
  p_given_by text, p_related uuid, p_guardian text, p_channel text, p_evidence text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action text := case when p_granted then 'grant' else 'withdraw' end;
begin
  insert into privacy.consent_event (
    tenant_id, patient_id, purpose_code, action, notice_id, given_by,
    related_person_id, guardian_name, channel, evidence_uri, occurred_at)
  values (
    p_tenant_id, p_patient_id, p_purpose, v_action, p_notice_id, p_given_by,
    p_related, nullif(btrim(p_guardian), ''), p_channel, nullif(btrim(p_evidence), ''),
    pg_catalog.clock_timestamp());
  perform messaging.enqueue(
    p_tenant_id, 'privacy', p_patient_id,
    case when p_granted then 'consent.granted_v1' else 'consent.withdrawn_v1' end,
    jsonb_build_object(
      'patientId', p_patient_id,
      'purposeCode', p_purpose,
      'occurredAt', pg_catalog.clock_timestamp()));
end;
$$;

create or replace function privacy.record_consents(p_tenant_id uuid, p_key uuid, p_patient_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_patient_id::text || ':' || p_body::text);
  v_replay jsonb;
  v_notice uuid := nullif(p_body ->> 'noticeId', '')::uuid;
  v_channel text := p_body ->> 'channel';
  v_given text := p_body ->> 'givenBy';
  v_minor boolean := coalesce((p_body ->> 'subjectIsMinor')::boolean, false);
  v_related uuid := nullif(p_body ->> 'relatedPersonId', '')::uuid;
  v_guardian text := nullif(btrim(p_body ->> 'guardianName'), '');
  v_evidence text := p_body ->> 'evidenceUri';
  v_notice_lang text;
  v_published timestamptz;
  v_current uuid;
  v_choice record;
  v_purpose text;
  v_granted boolean;
  v_seen text[] := array[]::text[];
  v_count integer := 0;
  v_response jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.consent');
  perform privacy.reject_client_code(p_body);
  if p_body ? 'patientId' and nullif(p_body ->> 'patientId', '') is distinct from p_patient_id::text then
    perform privacy.fail('invalid_parameter', 'The patient is taken from the address, not from the request.');
  end if;
  v_replay := privacy.replay(p_tenant_id, p_key, 'record_consents', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  perform privacy.require_patient(p_tenant_id, p_patient_id);
  if v_channel is null or v_channel not in ('tablet', 'staff_readout', 'paper', 'link') then
    perform privacy.fail('invalid_parameter', 'Say how consent was given: tablet, read out by staff, or paper.');
  end if;
  if v_given is null or v_given not in ('self', 'guardian', 'staff') then
    perform privacy.fail('invalid_parameter', 'Say who gave consent.');
  end if;
  if v_minor and v_given = 'self' then
    perform privacy.fail('guardian_required', 'A parent or guardian must give consent for a child.');
  end if;
  if v_minor and (v_guardian is null and v_related is null) then
    perform privacy.fail('guardian_required', 'Name the parent or guardian who is giving consent.');
  end if;
  if v_channel = 'paper' and nullif(btrim(v_evidence), '') is null then
    perform privacy.fail('invalid_parameter', 'A paper form needs the uploaded form attached.');
  end if;
  select n.language_code, n.published_at into v_notice_lang, v_published
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.id = v_notice and not n.is_deleted;
  if not found or v_published is null then
    perform privacy.fail('notice_not_current', 'This notice is not the current one. Reload and try again.');
  end if;
  select n.id into v_current
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.language_code = v_notice_lang
    and n.published_at is not null and not n.is_deleted
  order by n.version desc
  limit 1;
  if v_current is distinct from v_notice then
    perform privacy.fail('notice_not_current', 'This notice is not the current one. Reload and try again.');
  end if;
  if jsonb_typeof(p_body -> 'choices') is distinct from 'array'
     or jsonb_array_length(p_body -> 'choices') = 0 then
    perform privacy.fail('invalid_parameter', 'Record a choice for each purpose on the notice.');
  end if;
  for v_choice in select * from jsonb_array_elements(p_body -> 'choices') as t(choice)
  loop
    v_purpose := v_choice.choice ->> 'purposeCode';
    v_granted := coalesce((v_choice.choice ->> 'granted')::boolean, false);
    if not privacy.purpose_ok(v_purpose) or v_purpose = any (v_seen) then
      perform privacy.fail('invalid_parameter', 'Each purpose on the notice is chosen once.');
    end if;
    if not exists (
      select 1 from privacy.consent_notice_purpose p
      where p.tenant_id = p_tenant_id and p.notice_id = v_notice
        and p.purpose_code = v_purpose and not p.is_deleted
    ) then
      perform privacy.fail('invalid_parameter', 'That choice is not on this notice.');
    end if;
    v_seen := v_seen || v_purpose;
    perform privacy.write_consent(
      p_tenant_id, p_patient_id, v_notice, v_purpose, v_granted,
      v_given, v_related, v_guardian, v_channel, v_evidence);
    v_count := v_count + 1;
  end loop;
  perform messaging.enqueue(
    p_tenant_id, 'privacy', p_patient_id, 'consent.receipt_requested_v1',
    jsonb_build_object(
      'patientId', p_patient_id,
      'noticeId', v_notice,
      'occurredAt', pg_catalog.clock_timestamp()));
  v_response := jsonb_build_object('events', v_count, 'receiptQueued', true);
  return privacy.remember(p_tenant_id, p_key, 'record_consents', v_hash, v_response);
end;
$$;

create or replace function privacy.list_consents(p_tenant_id uuid, p_patient_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.view');
  perform privacy.require_patient(p_tenant_id, p_patient_id);
  v_ids := privacy.chart_ids(p_tenant_id, p_patient_id);
  return jsonb_build_object(
    'current', coalesce((
      select jsonb_agg(jsonb_build_object(
        'purposeCode', c.purpose_code,
        'label', privacy.purpose_label(c.purpose_code),
        'granted', c.action = 'grant',
        'since', c.occurred_at,
        'noticeVersion', n.version
      ) order by c.purpose_code)
      from privacy.consent_current c
      join privacy.consent_notice n on n.tenant_id = c.tenant_id and n.id = c.notice_id
      where c.tenant_id = p_tenant_id and c.patient_id = any (v_ids)
        and c.occurred_at = (
          select max(c2.occurred_at) from privacy.consent_current c2
          where c2.tenant_id = c.tenant_id and c2.purpose_code = c.purpose_code
            and c2.patient_id = any (v_ids)
        )
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'purposeCode', e.purpose_code,
        'action', e.action,
        'occurredAt', e.occurred_at,
        'noticeVersion', n.version,
        'channel', e.channel,
        'givenBy', e.given_by,
        'patientId', e.patient_id
      ) order by e.occurred_at desc, e.id desc)
      from privacy.consent_event e
      join privacy.consent_notice n on n.tenant_id = e.tenant_id and n.id = e.notice_id
      where e.tenant_id = p_tenant_id and e.patient_id = any (v_ids) and not e.is_deleted
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function privacy.withdraw_consent(
  p_tenant_id uuid, p_key uuid, p_patient_id uuid, p_purpose text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_patient_id::text || ':' || p_purpose || ':' || p_body::text);
  v_replay jsonb;
  v_channel text := coalesce(p_body ->> 'channel', 'tablet');
  v_notice uuid;
  v_response jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.consent');
  perform privacy.reject_client_code(p_body);
  v_replay := privacy.replay(p_tenant_id, p_key, 'withdraw_consent', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  perform privacy.require_patient(p_tenant_id, p_patient_id);
  if not privacy.purpose_ok(p_purpose) then
    perform privacy.fail('invalid_parameter', 'Unknown purpose.');
  end if;
  if v_channel not in ('tablet', 'staff_readout', 'paper', 'link') then
    perform privacy.fail('invalid_parameter', 'Say how the withdrawal was received.');
  end if;
  if not privacy.consent_allows_v1(p_tenant_id, p_patient_id, p_purpose) then
    perform privacy.fail('not_granted', 'That purpose is not currently granted.');
  end if;
  select n.id into v_notice
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.published_at is not null and not n.is_deleted
  order by n.published_at desc
  limit 1;
  if v_notice is null then
    perform privacy.fail('no_published_notice', 'Publish a privacy notice in Admin › Privacy first.');
  end if;
  perform privacy.write_consent(
    p_tenant_id, p_patient_id, v_notice, p_purpose, false,
    'self', null, null, v_channel, null);
  v_response := jsonb_build_object('purposeCode', p_purpose, 'granted', false);
  return privacy.remember(p_tenant_id, p_key, 'withdraw_consent', v_hash, v_response);
end;
$$;

create or replace function privacy.create_consent_link(p_tenant_id uuid, p_patient_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notice uuid;
  v_token text;
  v_hash text;
  v_expires timestamptz := pg_catalog.clock_timestamp() + interval '7 days';
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.consent');
  perform privacy.require_patient(p_tenant_id, p_patient_id);
  select n.id into v_notice
  from privacy.consent_notice n
  where n.tenant_id = p_tenant_id and n.language_code = 'en'
    and n.published_at is not null and not n.is_deleted
  order by n.version desc
  limit 1;
  if v_notice is null then
    perform privacy.fail('no_published_notice', 'Publish a privacy notice in Admin › Privacy first.');
  end if;
  v_token := replace(pg_catalog.gen_random_uuid()::text, '-', '') || replace(pg_catalog.gen_random_uuid()::text, '-', '');
  v_hash := privacy.sha256_hex(v_token);
  insert into privacy.consent_link (tenant_id, patient_id, notice_id, token_hash, expires_at)
  values (p_tenant_id, p_patient_id, v_notice, v_hash, v_expires);
  return jsonb_build_object(
    'expiresAt', v_expires,
    'path', '/privacy/consent/' || v_token);
end;
$$;

create or replace function privacy.link_row(p_token text)
returns privacy.consent_link
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row privacy.consent_link;
  v_hash text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    perform privacy.fail('link_expired', 'This link has expired. Ask the hospital for a new one.');
  end if;
  v_hash := privacy.sha256_hex(p_token);
  select * into v_row
  from privacy.consent_link l
  where l.token_hash = v_hash and not l.is_deleted
  order by l.created_on desc
  limit 1;
  if not found or v_row.used_at is not null or v_row.expires_at <= pg_catalog.clock_timestamp() then
    perform privacy.fail('link_expired', 'This link has expired. Ask the hospital for a new one.');
  end if;
  return v_row;
end;
$$;

create or replace function privacy.public_consent_preview(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_link privacy.consent_link;
  v_notice jsonb;
begin
  v_link := privacy.link_row(p_token);
  v_notice := privacy.notice_json(v_link.tenant_id, v_link.notice_id);
  return v_notice || jsonb_build_object(
    'purposes', (
      select jsonb_agg(jsonb_build_object(
        'code', p.purpose_code,
        'label', privacy.purpose_label(p.purpose_code),
        'required', false,
        'granted', privacy.latest_granted(v_link.tenant_id, v_link.patient_id, p.purpose_code)
      ) order by p.purpose_code)
      from privacy.consent_notice_purpose p
      where p.tenant_id = v_link.tenant_id and p.notice_id = v_link.notice_id and not p.is_deleted
    ));
end;
$$;

create or replace function privacy.submit_public_consent(p_token text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link privacy.consent_link;
  v_choice record;
  v_purpose text;
  v_granted boolean;
  v_seen text[] := array[]::text[];
  v_count integer := 0;
  v_current uuid;
begin
  if p_body ? 'tenantId' or p_body ? 'tenant_id' or p_body ? 'patientId' then
    perform privacy.fail('invalid_parameter', 'The hospital and the patient come from the link, not from the request.');
  end if;
  v_link := privacy.link_row(p_token);
  if jsonb_typeof(p_body -> 'choices') is distinct from 'array'
     or jsonb_array_length(p_body -> 'choices') = 0 then
    perform privacy.fail('invalid_parameter', 'Record a choice for each purpose.');
  end if;
  select n.id into v_current
  from privacy.consent_notice n
  where n.tenant_id = v_link.tenant_id
    and n.language_code = (select language_code from privacy.consent_notice where tenant_id = v_link.tenant_id and id = v_link.notice_id)
    and n.published_at is not null and not n.is_deleted
  order by n.version desc
  limit 1;
  for v_choice in select * from jsonb_array_elements(p_body -> 'choices') as t(choice)
  loop
    v_purpose := v_choice.choice ->> 'purposeCode';
    v_granted := coalesce((v_choice.choice ->> 'granted')::boolean, false);
    if not privacy.purpose_ok(v_purpose) or v_purpose = any (v_seen) then
      perform privacy.fail('invalid_parameter', 'Each purpose is chosen once.');
    end if;
    if v_granted and v_current is distinct from v_link.notice_id then
      perform privacy.fail('notice_not_current', 'This notice is not the current one. Ask the hospital for a new link.');
    end if;
    if not exists (
      select 1 from privacy.consent_notice_purpose p
      where p.tenant_id = v_link.tenant_id and p.notice_id = v_link.notice_id
        and p.purpose_code = v_purpose and not p.is_deleted
    ) then
      perform privacy.fail('invalid_parameter', 'That choice is not on this notice.');
    end if;
    v_seen := v_seen || v_purpose;
    if v_granted or privacy.latest_granted(v_link.tenant_id, v_link.patient_id, v_purpose) then
      perform privacy.write_consent(
        v_link.tenant_id, v_link.patient_id, v_link.notice_id, v_purpose, v_granted,
        'self', null, null, 'link', null);
      v_count := v_count + 1;
    end if;
  end loop;
  update privacy.consent_link set used_at = pg_catalog.clock_timestamp()
   where tenant_id = v_link.tenant_id and id = v_link.id;
  return jsonb_build_object('events', v_count, 'saved', true);
end;
$$;

create or replace function privacy.request_json(p_tenant_id uuid, p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id,
    'code', r.code,
    'patientId', r.patient_id,
    'type', r.request_type,
    'details', r.details,
    'channel', r.channel,
    'status', r.status,
    'receivedAt', r.received_at,
    'dueAt', r.due_at,
    'daysRemaining', ceil(extract(epoch from (r.due_at - pg_catalog.clock_timestamp())) / 86400.0)::integer,
    'response', r.response_text,
    'verifiedAt', r.verified_at,
    'fulfilledAt', r.fulfilled_at,
    'closedAt', r.closed_at,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'action', e.action, 'at', e.occurred_at, 'note', e.note
      ) order by e.occurred_at, e.id)
      from privacy.rights_request_event e
      where e.tenant_id = r.tenant_id and e.request_id = r.id and not e.is_deleted
    ), '[]'::jsonb)
  )
  from privacy.rights_request r
  where r.tenant_id = p_tenant_id and r.id = p_id and not r.is_deleted
$$;

create or replace function privacy.audit_request(p_tenant_id uuid, p_id uuid, p_action text, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into privacy.rights_request_event (tenant_id, request_id, action, actor_id, note, occurred_at)
  values (p_tenant_id, p_id, p_action, privacy.actor(), p_note, pg_catalog.clock_timestamp());
end;
$$;

create or replace function privacy.create_rights_request(p_tenant_id uuid, p_key uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_body::text);
  v_replay jsonb;
  v_patient uuid := nullif(p_body ->> 'patientId', '')::uuid;
  v_type text := p_body ->> 'type';
  v_details text := btrim(p_body ->> 'details');
  v_channel text := coalesce(p_body ->> 'channel', 'desk');
  v_fy text;
  v_code text;
  v_id uuid;
  v_due timestamptz;
  v_response jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.request');
  perform privacy.reject_client_code(p_body);
  v_replay := privacy.replay(p_tenant_id, p_key, 'create_rights_request', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  perform privacy.require_patient(p_tenant_id, v_patient);
  if v_type is null or v_type not in ('access', 'correction', 'erasure', 'grievance', 'nomination') then
    perform privacy.fail('invalid_parameter', 'Choose access, correction, erasure, grievance, or nomination.');
  end if;
  if v_details is null or v_details = '' then
    perform privacy.fail('invalid_parameter', 'Write what the person asked for.');
  end if;
  if v_channel not in ('desk', 'link', 'email', 'whatsapp') then
    perform privacy.fail('invalid_parameter', 'Say how the request arrived.');
  end if;
  v_fy := privacy.fy_code(pg_catalog.clock_timestamp());
  v_code := 'DPR-' || v_fy || '-' || pg_catalog.lpad(privacy.next_number(p_tenant_id, 'rights-' || v_fy)::text, 5, '0');
  v_due := pg_catalog.clock_timestamp() + interval '90 days';
  insert into privacy.rights_request (tenant_id, code, patient_id, request_type, details, channel, received_at, due_at)
  values (p_tenant_id, v_code, v_patient, v_type, v_details, v_channel, pg_catalog.clock_timestamp(), v_due)
  returning id into v_id;
  perform privacy.audit_request(p_tenant_id, v_id, 'created', null);
  perform messaging.enqueue(
    p_tenant_id, 'privacy', v_id, 'rights_request.created_v1',
    jsonb_build_object('requestId', v_id, 'patientId', v_patient, 'type', v_type, 'dueAt', v_due));
  v_response := privacy.request_json(p_tenant_id, v_id);
  return privacy.remember(p_tenant_id, p_key, 'create_rights_request', v_hash, v_response);
end;
$$;

create or replace function privacy.list_rights_requests(p_tenant_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.view');
  if p_status is not null and p_status <> '' and p_status not in ('received', 'verified', 'fulfilled', 'closed', 'held') then
    perform privacy.fail('invalid_parameter', 'Unknown status.');
  end if;
  for v_row in
    select r.id
    from privacy.rights_request r
    where r.tenant_id = p_tenant_id and not r.is_deleted
      and r.status not in ('closed')
      and not r.due_soon_emitted
      and r.due_at > pg_catalog.clock_timestamp()
      and r.due_at <= pg_catalog.clock_timestamp() + interval '10 days'
  loop
    update privacy.rights_request set due_soon_emitted = true
     where tenant_id = p_tenant_id and id = v_row.id;
    perform privacy.audit_request(p_tenant_id, v_row.id, 'due_soon', 'Due within 10 days');
    perform messaging.enqueue(
      p_tenant_id, 'privacy', v_row.id, 'rights_request.due_soon_v1',
      jsonb_build_object('requestId', v_row.id));
  end loop;
  return coalesce((
    select jsonb_agg(privacy.request_json(r.tenant_id, r.id) order by r.due_at, r.received_at)
    from privacy.rights_request r
    where r.tenant_id = p_tenant_id and not r.is_deleted
      and (p_status is null or p_status = '' or r.status = p_status)
  ), '[]'::jsonb);
end;
$$;

create or replace function privacy.get_rights_request(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_json jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.view');
  v_json := privacy.request_json(p_tenant_id, p_id);
  if v_json is null then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  return v_json;
end;
$$;

create or replace function privacy.load_request(p_tenant_id uuid, p_id uuid)
returns privacy.rights_request
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
begin
  select * into v_row from privacy.rights_request r
  where r.tenant_id = p_tenant_id and r.id = p_id and not r.is_deleted;
  if not found then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

create or replace function privacy.verify_rights_request(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.fulfil');
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.status is distinct from 'received' then
    perform privacy.fail('invalid_state', 'Only a new request can be verified.');
  end if;
  update privacy.rights_request
     set status = 'verified', verified_at = pg_catalog.clock_timestamp(), verified_by = privacy.actor()
   where tenant_id = p_tenant_id and id = p_id;
  perform privacy.audit_request(p_tenant_id, p_id, 'verified', null);
  return privacy.request_json(p_tenant_id, p_id);
end;
$$;

create or replace function privacy.fulfil_rights_request(p_tenant_id uuid, p_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
  v_note text := nullif(btrim(p_body ->> 'response'), '');
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.fulfil');
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.status is distinct from 'verified' then
    perform privacy.fail('identity_not_verified', 'Verify who is asking before you fulfil the request.');
  end if;
  if v_row.request_type = 'erasure' then
    perform privacy.fail('invalid_parameter', 'Erasure is a separate step and needs a second approver.');
  end if;
  if v_row.request_type = 'correction' then
    if jsonb_typeof(p_body -> 'correction') is distinct from 'object' then
      perform privacy.fail('invalid_parameter', 'Write the correction to record.');
    end if;
    update privacy.rights_request
       set correction = p_body -> 'correction',
           response_text = coalesce(v_note, 'The correction was recorded for the patient registry.')
     where tenant_id = p_tenant_id and id = p_id;
  elsif v_row.request_type in ('grievance', 'nomination') and v_note is null then
    perform privacy.fail('invalid_parameter', 'Write the response the person will receive.');
  else
    update privacy.rights_request
       set response_text = coalesce(v_note, 'The summary is ready.')
     where tenant_id = p_tenant_id and id = p_id;
  end if;
  update privacy.rights_request
     set status = 'fulfilled', fulfilled_at = pg_catalog.clock_timestamp(), fulfilled_by = privacy.actor()
   where tenant_id = p_tenant_id and id = p_id;
  perform privacy.audit_request(p_tenant_id, p_id, 'fulfilled', v_note);
  return privacy.request_json(p_tenant_id, p_id);
end;
$$;

create or replace function privacy.close_rights_request(p_tenant_id uuid, p_id uuid, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
  v_note text := nullif(btrim(p_body ->> 'response'), '');
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.fulfil');
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.status not in ('fulfilled', 'held') then
    perform privacy.fail('invalid_state', 'Fulfil the request before you close it.');
  end if;
  update privacy.rights_request
     set status = 'closed',
         closed_at = pg_catalog.clock_timestamp(),
         closed_by = privacy.actor(),
         response_text = coalesce(v_note, response_text)
   where tenant_id = p_tenant_id and id = p_id;
  perform privacy.audit_request(p_tenant_id, p_id, 'closed', v_note);
  return privacy.request_json(p_tenant_id, p_id);
end;
$$;

create or replace function privacy.approve_erasure(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
  v_actor uuid := privacy.actor();
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.erase');
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.request_type is distinct from 'erasure' then
    perform privacy.fail('invalid_parameter', 'Only an erasure request is approved this way.');
  end if;
  if v_row.status is distinct from 'verified' then
    perform privacy.fail('identity_not_verified', 'Verify who is asking before you approve erasure.');
  end if;
  insert into privacy.erasure_approval (tenant_id, request_id, approver_id, approved_at)
  values (p_tenant_id, p_id, v_actor, pg_catalog.clock_timestamp())
  on conflict (tenant_id, request_id, approver_id) do nothing;
  perform privacy.audit_request(p_tenant_id, p_id, 'approved', null);
  return privacy.request_json(p_tenant_id, p_id);
end;
$$;

create or replace function privacy.add_erasure_item(
  p_tenant_id uuid, p_id uuid, p_category text, p_action text, p_policy text, p_reason text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into privacy.erasure_item (tenant_id, request_id, data_category, action, retention_policy_code, reason)
  values (p_tenant_id, p_id, p_category, p_action, p_policy, p_reason)
$$;

create or replace function privacy.execute_erasure(p_tenant_id uuid, p_key uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := privacy.sha256_hex(p_id::text);
  v_replay jsonb;
  v_row privacy.rights_request;
  v_actor uuid := privacy.actor();
  v_others integer;
  v_open boolean;
  v_response jsonb;
  v_items jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.erase');
  v_replay := privacy.replay(p_tenant_id, p_key, 'execute_erasure', v_hash);
  if v_replay is not null then
    return v_replay;
  end if;
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.request_type is distinct from 'erasure' then
    perform privacy.fail('invalid_parameter', 'Only an erasure request can be executed.');
  end if;
  if v_row.status is distinct from 'verified' then
    perform privacy.fail('identity_not_verified', 'Verify who is asking before you erase anything.');
  end if;
  select count(*) into v_others
  from privacy.erasure_approval a
  where a.tenant_id = p_tenant_id and a.request_id = p_id and not a.is_deleted
    and a.approver_id is distinct from v_actor;
  if v_others < 1 then
    perform privacy.fail('second_approver_required', 'Erasure needs a second person to approve it first.');
  end if;
  insert into privacy.erasure_approval (tenant_id, request_id, approver_id, approved_at)
  values (p_tenant_id, p_id, v_actor, pg_catalog.clock_timestamp())
  on conflict (tenant_id, request_id, approver_id) do nothing;
  v_open := appointment.patient_has_open_visits_v1(p_tenant_id, v_row.patient_id);
  if v_open then
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'contact_copies', 'retained', 'open_visit',
      'Nothing was erased. This person has an open visit.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'consent_ledger', 'retained', 'consent_proof',
      'The consent record is kept so a withdrawal can be proved.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'clinical_opd', 'retained', 'nmc_opd_3y',
      'OPD records are kept for 3 years under NMC rules.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'billing_gst', 'retained', 'gst_72m',
      'GST records are kept for 72 months.');
    update privacy.rights_request
       set status = 'held',
           response_text = 'This person has an open visit, so nothing was erased. Ask again after the visit is closed. OPD records are kept for 3 years under NMC rules. GST records are kept for 72 months.'
     where tenant_id = p_tenant_id and id = p_id;
    perform privacy.audit_request(p_tenant_id, p_id, 'held', 'Open visit');
  else
    update privacy.rights_request
       set details = '[erased]',
           correction = null,
           response_text = 'Contact copies held on this request were cleared. The consent record is kept. OPD records are kept for 3 years under NMC rules. GST records are kept for 72 months. This service cannot see open bills.'
     where tenant_id = p_tenant_id and id = p_id;
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'contact_copies', 'anonymised', null,
      'Free text on this request was cleared.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'consent_ledger', 'retained', 'consent_proof',
      'The consent record is kept so a withdrawal can be proved.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'clinical_opd', 'retained', 'nmc_opd_3y',
      'OPD records are kept for 3 years under NMC rules.');
    perform privacy.add_erasure_item(p_tenant_id, p_id, 'billing_gst', 'retained', 'gst_72m',
      'GST records are kept for 72 months. Open bills are not visible to this service.');
    update privacy.rights_request
       set status = 'fulfilled', fulfilled_at = pg_catalog.clock_timestamp(), fulfilled_by = v_actor
     where tenant_id = p_tenant_id and id = p_id;
    perform privacy.audit_request(p_tenant_id, p_id, 'erased', null);
    perform messaging.enqueue(
      p_tenant_id, 'privacy', v_row.patient_id, 'patient.erased_v1',
      jsonb_build_object('patientId', v_row.patient_id, 'categories', jsonb_build_array('contact_copies')));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'dataCategory', i.data_category, 'action', i.action, 'reason', i.reason
  ) order by i.data_category), '[]'::jsonb) into v_items
  from privacy.erasure_item i
  where i.tenant_id = p_tenant_id and i.request_id = p_id and not i.is_deleted;
  v_response := privacy.request_json(p_tenant_id, p_id) || jsonb_build_object('items', v_items);
  return privacy.remember(p_tenant_id, p_key, 'execute_erasure', v_hash, v_response);
end;
$$;

create or replace function privacy.access_export(p_tenant_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row privacy.rights_request;
  v_patient jsonb;
begin
  perform privacy.assert_permission(p_tenant_id, 'privacy.fulfil');
  v_row := privacy.load_request(p_tenant_id, p_id);
  if v_row.request_type is distinct from 'access' then
    perform privacy.fail('invalid_parameter', 'Only an access request has a summary.');
  end if;
  if v_row.status not in ('verified', 'fulfilled', 'closed') then
    perform privacy.fail('identity_not_verified', 'Verify who is asking before you prepare the summary.');
  end if;
  select jsonb_build_object('id', s.id, 'mrn', s.mrn, 'firstName', s.first_name, 'lastName', s.last_name)
    into v_patient
  from patient.patient_summary_v1(p_tenant_id, array[v_row.patient_id]) s
  limit 1;
  return jsonb_build_object(
    'generatedAt', pg_catalog.clock_timestamp(),
    'requestCode', v_row.code,
    'patient', v_patient,
    'consents', privacy.list_consents(p_tenant_id, v_row.patient_id),
    'note', 'Phone, email, clinical notes, and bills are not in this summary. Those services have not published a read for them.');
end;
$$;

-- cross-schema: approved (published v1; the patients merge function does not call this yet)
create or replace function privacy.note_patient_merge_v1(p_tenant_id uuid, p_from uuid, p_to uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (auth.uid() is not null or pg_catalog.current_setting('role', true) in ('authenticated', 'anon'))
     and (p_tenant_id is null or p_tenant_id not in (select identity.current_tenant_ids())) then
    raise exception 'tenant not found' using errcode = 'P0002';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    perform privacy.fail('invalid_parameter', 'Name the chart that was merged and the chart that remains.');
  end if;
  perform privacy.require_patient(p_tenant_id, p_to);
  insert into privacy.patient_alias (tenant_id, from_patient_id, to_patient_id)
  values (p_tenant_id, p_from, p_to)
  on conflict (tenant_id, from_patient_id) do nothing;
end;
$$;

comment on function privacy.note_patient_merge_v1(uuid, uuid, uuid) is
  'v1 (published by privacy): point a merged chart at the survivor. Events are not edited. The patients service is not granted this yet.';

-- --------------------------------------------------------------------- outbox ----
alter table messaging.outbox drop constraint outbox_aggregate_type_valid;
alter table messaging.outbox add constraint outbox_aggregate_type_valid
  check (aggregate_type in ('appointment', 'queue_entry', 'tenant', 'email_message', 'patient', 'billing', 'privacy'));

alter table messaging.outbox drop constraint outbox_source_service_valid;
alter table messaging.outbox add constraint outbox_source_service_valid
  check (source_service in ('identity', 'patients', 'scheduling', 'billing', 'privacy'));

create or replace function messaging.set_outbox_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.source_service := case new.aggregate_type
    when 'appointment' then 'scheduling'
    when 'queue_entry' then 'scheduling'
    when 'tenant' then 'identity'
    when 'email_message' then 'identity'
    when 'patient' then 'patients'
    when 'billing' then 'billing'
    when 'privacy' then 'privacy'
  end;
  if new.source_service is null then
    raise exception 'no owning service for aggregate type %', new.aggregate_type using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function messaging.set_outbox_source() from public;

create or replace function messaging.caller_sources()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from pg_catalog.pg_roles r where r.rolname = session_user and r.rolsuper)
      or pg_catalog.pg_has_role(session_user, 'service_role', 'MEMBER')
      then array['identity', 'patients', 'scheduling', 'billing', 'privacy']
    else array_remove(array[
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_identity', 'MEMBER') then 'identity' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_patients', 'MEMBER') then 'patients' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_scheduling', 'MEMBER') then 'scheduling' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_billing', 'MEMBER') then 'billing' end,
      case when pg_catalog.pg_has_role(session_user, 'hms_svc_privacy', 'MEMBER') then 'privacy' end], null)
  end
$$;
revoke all on function messaging.caller_sources() from public, anon, authenticated;
grant execute on function messaging.caller_sources() to hms_dispatcher, hms_mailer, service_role;

-- --------------------------------------------------------------------- grants / RLS ----
alter table privacy.code_seq enable row level security;
alter table privacy.consent_notice enable row level security;
alter table privacy.consent_notice_purpose enable row level security;
alter table privacy.consent_event enable row level security;
alter table privacy.consent_link enable row level security;
alter table privacy.rights_request enable row level security;
alter table privacy.rights_request_event enable row level security;
alter table privacy.erasure_item enable row level security;
alter table privacy.erasure_approval enable row level security;
alter table privacy.command_receipt enable row level security;
alter table privacy.patient_alias enable row level security;

revoke all on all tables in schema privacy from public, anon, authenticated,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing, hms_svc_inventory, hms_api;
revoke all on privacy.code_seq, privacy.command_receipt from hms_svc_privacy;

grant select on
  privacy.consent_notice,
  privacy.consent_notice_purpose,
  privacy.consent_event,
  privacy.consent_link,
  privacy.rights_request,
  privacy.rights_request_event,
  privacy.erasure_item,
  privacy.erasure_approval,
  privacy.patient_alias,
  privacy.consent_current
to hms_svc_privacy;

revoke delete, insert, update on all tables in schema privacy from hms_svc_privacy;

create policy consent_notice_read on privacy.consent_notice
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and (
      identity.has_tenant_permission(tenant_id, 'privacy.view')
      or identity.has_tenant_permission(tenant_id, 'privacy.notice')
      or identity.has_tenant_permission(tenant_id, 'privacy.consent')
    )
  );

create policy consent_notice_purpose_read on privacy.consent_notice_purpose
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

create policy consent_event_read on privacy.consent_event
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

create policy consent_link_read on privacy.consent_link
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.consent')
  );

create policy rights_request_read on privacy.rights_request
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

create policy rights_request_event_read on privacy.rights_request_event
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

create policy erasure_item_read on privacy.erasure_item
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

create policy erasure_approval_read on privacy.erasure_approval
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.erase')
  );

create policy patient_alias_read on privacy.patient_alias
  for select to hms_svc_privacy
  using (
    tenant_id in (select identity.current_tenant_ids())
    and identity.has_tenant_permission(tenant_id, 'privacy.view')
  );

grant usage on schema identity, auth, audit, patient, appointment, messaging to hms_svc_privacy;
grant execute on function auth.uid() to hms_svc_privacy;
grant execute on function auth.jwt() to hms_svc_privacy;
grant execute on function audit.session_actor_id() to hms_svc_privacy;
grant execute on function audit.system_actor() to hms_svc_privacy;
grant execute on function identity.current_tenant_ids() to hms_svc_privacy;
grant execute on function identity.current_branch_ids(uuid) to hms_svc_privacy;
grant execute on function identity.has_tenant_permission(uuid, text) to hms_svc_privacy;
grant execute on function identity.branch_exists_v1(uuid, uuid) to hms_svc_privacy;
grant execute on function identity.my_tenant_grant_v1(uuid) to hms_svc_privacy;
grant execute on function identity.my_active_context() to hms_svc_privacy;
grant execute on function patient.patient_exists_v1(uuid, uuid) to hms_svc_privacy;
grant execute on function patient.patient_summary_v1(uuid, uuid[]) to hms_svc_privacy;
grant execute on function appointment.patient_has_open_visits_v1(uuid, uuid) to hms_svc_privacy;

revoke all on all functions in schema privacy from public, anon, authenticated,
  hms_svc_identity, hms_svc_patients, hms_svc_scheduling, hms_svc_billing, hms_svc_inventory, hms_api;

grant execute on function privacy.current_notice(uuid, text) to hms_svc_privacy, service_role;
grant execute on function privacy.list_notices(uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.create_notice(uuid, uuid, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.publish_notice(uuid, uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.record_consents(uuid, uuid, uuid, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.list_consents(uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.withdraw_consent(uuid, uuid, uuid, text, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.create_consent_link(uuid, uuid) to hms_svc_privacy, service_role;
-- Anonymous consent links run as anon (the unauthenticated session role), the same way a receipt link does.
grant execute on function privacy.public_consent_preview(text) to hms_svc_privacy, service_role, anon;
grant execute on function privacy.submit_public_consent(text, jsonb) to hms_svc_privacy, service_role, anon;
grant execute on function privacy.consent_allows_v1(uuid, uuid, text) to hms_svc_privacy, service_role;
grant execute on function privacy.create_rights_request(uuid, uuid, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.list_rights_requests(uuid, text) to hms_svc_privacy, service_role;
grant execute on function privacy.get_rights_request(uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.verify_rights_request(uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.fulfil_rights_request(uuid, uuid, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.close_rights_request(uuid, uuid, jsonb) to hms_svc_privacy, service_role;
grant execute on function privacy.approve_erasure(uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.execute_erasure(uuid, uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.access_export(uuid, uuid) to hms_svc_privacy, service_role;
grant execute on function privacy.note_patient_merge_v1(uuid, uuid, uuid) to service_role;
