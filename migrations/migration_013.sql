-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_013.sql
-- Integration: maintenance system (hv_*) and CRM tables moved into this
-- project. Generated from the source databases on 2026-09-05.
-- ADDITIVE ONLY. Idempotent.
-- =====================================================================
-- functions reference each other; validate bodies only when called
set check_function_bodies = off;

-- ------------------------- MAINTENANCE SYSTEM -------------------------
create sequence if not exists public.hv_users_id_seq;
create sequence if not exists public.hv_properties_id_seq;
create sequence if not exists public.hv_stores_id_seq;
create sequence if not exists public.hv_task_types_id_seq;
create sequence if not exists public.hv_tasks_id_seq;
create sequence if not exists public.hv_invoices_id_seq;
create sequence if not exists public.hv_attachments_id_seq;
create sequence if not exists public.hv_comments_id_seq;
create sequence if not exists public.hv_meetings_id_seq;

create table if not exists public.hv_attachments (
  id bigint default nextval('hv_attachments_id_seq'::regclass) not null,
  task_id bigint,
  uploaded_by_id bigint,
  uploaded_by_name text,
  file_name text not null,
  storage_path text not null,
  file_type text not null,
  file_size bigint,
  mime_type text,
  duration_seconds integer,
  created_at timestamp with time zone default now(),
  expires_at timestamp with time zone default (now() + '3 mons'::interval)
);
create table if not exists public.hv_comments (
  id bigint default nextval('hv_comments_id_seq'::regclass) not null,
  task_id bigint,
  author_id bigint,
  author_name text,
  author_role text,
  comment_text text not null,
  created_at timestamp with time zone default now()
);
create table if not exists public.hv_invoices (
  id bigint default nextval('hv_invoices_id_seq'::regclass) not null,
  invoice_number text not null,
  property_id bigint,
  invoice_version text default 'preliminary'::text,
  parent_invoice_id bigint,
  client_name text not null,
  client_phone text,
  description text default ''::text,
  items jsonb default '[]'::jsonb,
  total_amount numeric(12,2) default 0,
  discount_amount numeric(12,2) default 0,
  discount_reason text default ''::text,
  final_total numeric(12,2) default 0,
  notes text default ''::text,
  status text default 'draft'::text,
  created_by text,
  audit_trail jsonb default '[]'::jsonb,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now(),
  admin_approved_at timestamp with time zone,
  admin_approved_by text,
  supervisor_approved_at timestamp with time zone,
  supervisor_approved_by text,
  accounting_confirmed boolean default false,
  ceo_approved_at timestamp with time zone,
  ceo_approved_by text
);
create table if not exists public.hv_meetings (
  id bigint default nextval('hv_meetings_id_seq'::regclass) not null,
  title text not null,
  meeting_date date not null,
  meeting_time text default ''::text,
  location text default ''::text,
  agenda text default ''::text,
  attendees jsonb default '[]'::jsonb,
  notes jsonb default '[]'::jsonb,
  created_by text,
  created_by_id bigint,
  audit_trail jsonb default '[]'::jsonb,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);
create table if not exists public.hv_properties (
  id bigint default nextval('hv_properties_id_seq'::regclass) not null,
  name text not null,
  created_at timestamp with time zone default now()
);
create table if not exists public.hv_stores (
  id bigint default nextval('hv_stores_id_seq'::regclass) not null,
  name text not null,
  location text default ''::text,
  created_at timestamp with time zone default now()
);
create table if not exists public.hv_task_types (
  id bigint default nextval('hv_task_types_id_seq'::regclass) not null,
  title text not null,
  subtasks jsonb default '[]'::jsonb,
  created_at timestamp with time zone default now()
);
create table if not exists public.hv_tasks (
  id bigint default nextval('hv_tasks_id_seq'::regclass) not null,
  task_type_id bigint,
  location_type text default 'unit_only'::text not null,
  property_id bigint,
  source_store bigint,
  destination_store bigint,
  assigned_to bigint,
  assigned_to_multi jsonb default '[]'::jsonb,
  task_date date not null,
  admin_notes text default ''::text,
  checked_subtasks jsonb default '[]'::jsonb,
  employee_progress jsonb default '{}'::jsonb,
  employee_notes text default ''::text,
  extra_work text default ''::text,
  final_revision_by_employee boolean default false,
  submitted_at timestamp with time zone,
  admin_revised_at timestamp with time zone,
  admin_revised_by text,
  supervisor_revised_at timestamp with time zone,
  supervisor_revised_by text,
  audit_trail jsonb default '[]'::jsonb,
  recurrence_config jsonb,
  reopened_count integer default 0,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now(),
  start_date date,
  end_date date,
  actual_completion_date timestamp with time zone,
  completed_by text,
  is_range boolean default false,
  custom_subtasks jsonb
);
create table if not exists public.hv_users (
  id bigint default nextval('hv_users_id_seq'::regclass) not null,
  name text not null,
  username text not null,
  password text not null,
  role text not null,
  avatar text not null,
  created_at timestamp with time zone default now(),
  can_reschedule boolean default false
);

do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_attachments_pkey' and conrelid = 'public.hv_attachments'::regclass) then
  alter table public.hv_attachments add constraint hv_attachments_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_attachments_file_type_check' and conrelid = 'public.hv_attachments'::regclass) then
  alter table public.hv_attachments add constraint hv_attachments_file_type_check CHECK ((file_type = ANY (ARRAY['image'::text, 'video'::text, 'voice'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_comments_pkey' and conrelid = 'public.hv_comments'::regclass) then
  alter table public.hv_comments add constraint hv_comments_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_invoices_invoice_number_key' and conrelid = 'public.hv_invoices'::regclass) then
  alter table public.hv_invoices add constraint hv_invoices_invoice_number_key UNIQUE (invoice_number);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_invoices_pkey' and conrelid = 'public.hv_invoices'::regclass) then
  alter table public.hv_invoices add constraint hv_invoices_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_invoices_invoice_version_check' and conrelid = 'public.hv_invoices'::regclass) then
  alter table public.hv_invoices add constraint hv_invoices_invoice_version_check CHECK ((invoice_version = ANY (ARRAY['preliminary'::text, 'final'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_meetings_pkey' and conrelid = 'public.hv_meetings'::regclass) then
  alter table public.hv_meetings add constraint hv_meetings_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_properties_pkey' and conrelid = 'public.hv_properties'::regclass) then
  alter table public.hv_properties add constraint hv_properties_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_stores_pkey' and conrelid = 'public.hv_stores'::regclass) then
  alter table public.hv_stores add constraint hv_stores_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_task_types_pkey' and conrelid = 'public.hv_task_types'::regclass) then
  alter table public.hv_task_types add constraint hv_task_types_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_pkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_users_username_key' and conrelid = 'public.hv_users'::regclass) then
  alter table public.hv_users add constraint hv_users_username_key UNIQUE (username);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_users_pkey' and conrelid = 'public.hv_users'::regclass) then
  alter table public.hv_users add constraint hv_users_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_users_role_check' and conrelid = 'public.hv_users'::regclass) then
  alter table public.hv_users add constraint hv_users_role_check CHECK ((role = ANY (ARRAY['employee'::text, 'admin'::text, 'admin_supervisor'::text, 'ceo'::text, 'accountant'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_attachments_uploaded_by_id_fkey' and conrelid = 'public.hv_attachments'::regclass) then
  alter table public.hv_attachments add constraint hv_attachments_uploaded_by_id_fkey FOREIGN KEY (uploaded_by_id) REFERENCES hv_users(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_attachments_task_id_fkey' and conrelid = 'public.hv_attachments'::regclass) then
  alter table public.hv_attachments add constraint hv_attachments_task_id_fkey FOREIGN KEY (task_id) REFERENCES hv_tasks(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_comments_task_id_fkey' and conrelid = 'public.hv_comments'::regclass) then
  alter table public.hv_comments add constraint hv_comments_task_id_fkey FOREIGN KEY (task_id) REFERENCES hv_tasks(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_comments_author_id_fkey' and conrelid = 'public.hv_comments'::regclass) then
  alter table public.hv_comments add constraint hv_comments_author_id_fkey FOREIGN KEY (author_id) REFERENCES hv_users(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_invoices_property_id_fkey' and conrelid = 'public.hv_invoices'::regclass) then
  alter table public.hv_invoices add constraint hv_invoices_property_id_fkey FOREIGN KEY (property_id) REFERENCES hv_properties(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_invoices_parent_invoice_id_fkey' and conrelid = 'public.hv_invoices'::regclass) then
  alter table public.hv_invoices add constraint hv_invoices_parent_invoice_id_fkey FOREIGN KEY (parent_invoice_id) REFERENCES hv_invoices(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_meetings_created_by_id_fkey' and conrelid = 'public.hv_meetings'::regclass) then
  alter table public.hv_meetings add constraint hv_meetings_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES hv_users(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_assigned_to_fkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES hv_users(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_task_type_id_fkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_task_type_id_fkey FOREIGN KEY (task_type_id) REFERENCES hv_task_types(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_property_id_fkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_property_id_fkey FOREIGN KEY (property_id) REFERENCES hv_properties(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_source_store_fkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_source_store_fkey FOREIGN KEY (source_store) REFERENCES hv_stores(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'hv_tasks_destination_store_fkey' and conrelid = 'public.hv_tasks'::regclass) then
  alter table public.hv_tasks add constraint hv_tasks_destination_store_fkey FOREIGN KEY (destination_store) REFERENCES hv_stores(id) ON DELETE SET NULL;
end if; end $c$;

CREATE INDEX IF NOT EXISTS idx_attachments_task ON public.hv_attachments USING btree (task_id);
CREATE INDEX IF NOT EXISTS idx_attachments_expires ON public.hv_attachments USING btree (expires_at);
CREATE INDEX IF NOT EXISTS idx_comments_task ON public.hv_comments USING btree (task_id);
CREATE INDEX IF NOT EXISTS idx_invoices_property ON public.hv_invoices USING btree (property_id);
CREATE UNIQUE INDEX IF NOT EXISTS hv_invoices_invoice_number_key ON public.hv_invoices USING btree (invoice_number);
CREATE INDEX IF NOT EXISTS idx_meetings_date ON public.hv_meetings USING btree (meeting_date);
CREATE INDEX IF NOT EXISTS idx_tasks_date ON public.hv_tasks USING btree (task_date);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON public.hv_tasks USING btree (assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_range ON public.hv_tasks USING btree (start_date, end_date);
CREATE UNIQUE INDEX IF NOT EXISTS hv_users_username_key ON public.hv_users USING btree (username);

CREATE OR REPLACE FUNCTION public.cleanup_old_attachments()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id, storage_path FROM hv_attachments WHERE expires_at < NOW() LOOP
    DELETE FROM storage.objects WHERE bucket_id = 'hv-attachments' AND name = r.storage_path;
    DELETE FROM hv_attachments WHERE id = r.id;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_recurring_tasks()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  source_task RECORD;
  next_date DATE;
  config JSONB;
  occurrences INT;
BEGIN
  FOR source_task IN 
    SELECT * FROM hv_tasks 
    WHERE recurrence_config IS NOT NULL AND submitted_at IS NOT NULL
  LOOP
    config := source_task.recurrence_config;
    occurrences := COALESCE((config->>'occurrences_left')::INT, 999);
    IF config->>'repeat_mode' = 'once' AND occurrences <= 0 THEN CONTINUE; END IF;
    next_date := source_task.task_date::DATE + ((config->>'interval_days')::INT);
    IF EXISTS (SELECT 1 FROM hv_tasks WHERE recurrence_config->>'parent_task_id' = source_task.id::TEXT AND task_date = next_date) THEN CONTINUE; END IF;
    INSERT INTO hv_tasks (
      task_type_id, location_type, property_id, assigned_to, assigned_to_multi,
      task_date, admin_notes, source_store, destination_store,
      checked_subtasks, employee_progress, audit_trail, recurrence_config
    ) VALUES (
      source_task.task_type_id, source_task.location_type, source_task.property_id,
      source_task.assigned_to, source_task.assigned_to_multi,
      next_date, source_task.admin_notes, source_task.source_store, source_task.destination_store,
      '[]'::jsonb, '{}'::jsonb,
      jsonb_build_array(jsonb_build_object('action','تم إنشاء المهمة تلقائياً (تكرار)','by','النظام','timestamp',NOW())),
      jsonb_set(
        jsonb_set(config, '{parent_task_id}', to_jsonb(source_task.id)),
        '{occurrences_left}',
        to_jsonb(CASE WHEN config->>'repeat_mode' = 'once' THEN 0 ELSE occurrences - 1 END)
      )
    );
  END LOOP;
END;
$function$;


alter table public.hv_attachments enable row level security;
alter table public.hv_comments enable row level security;
alter table public.hv_invoices enable row level security;
alter table public.hv_meetings enable row level security;
alter table public.hv_properties enable row level security;
alter table public.hv_stores enable row level security;
alter table public.hv_task_types enable row level security;
alter table public.hv_tasks enable row level security;
alter table public.hv_users enable row level security;
drop policy if exists allow_all_attachments on public.hv_attachments;
create policy allow_all_attachments on public.hv_attachments for all to authenticated using (true) with check (true);
drop policy if exists allow_all_comments on public.hv_comments;
create policy allow_all_comments on public.hv_comments for all to authenticated using (true) with check (true);
drop policy if exists allow_all_invoices on public.hv_invoices;
create policy allow_all_invoices on public.hv_invoices for all to authenticated using (true) with check (true);
drop policy if exists allow_all_meetings on public.hv_meetings;
create policy allow_all_meetings on public.hv_meetings for all to authenticated using (true) with check (true);
drop policy if exists allow_all_properties on public.hv_properties;
create policy allow_all_properties on public.hv_properties for all to authenticated using (true) with check (true);
drop policy if exists allow_all_stores on public.hv_stores;
create policy allow_all_stores on public.hv_stores for all to authenticated using (true) with check (true);
drop policy if exists allow_all_task_types on public.hv_task_types;
create policy allow_all_task_types on public.hv_task_types for all to authenticated using (true) with check (true);
drop policy if exists allow_all_tasks on public.hv_tasks;
create policy allow_all_tasks on public.hv_tasks for all to authenticated using (true) with check (true);
drop policy if exists allow_all_users on public.hv_users;
create policy allow_all_users on public.hv_users for all to authenticated using (true) with check (true);

do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_attachments') then
  alter publication supabase_realtime add table public.hv_attachments;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_comments') then
  alter publication supabase_realtime add table public.hv_comments;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_invoices') then
  alter publication supabase_realtime add table public.hv_invoices;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_meetings') then
  alter publication supabase_realtime add table public.hv_meetings;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_properties') then
  alter publication supabase_realtime add table public.hv_properties;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_stores') then
  alter publication supabase_realtime add table public.hv_stores;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_task_types') then
  alter publication supabase_realtime add table public.hv_task_types;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_tasks') then
  alter publication supabase_realtime add table public.hv_tasks;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hv_users') then
  alter publication supabase_realtime add table public.hv_users;
end if; end $p$;

-- ------------------------- CRM -------------------------

create table if not exists public.activity (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  kind text,
  description text,
  at timestamp with time zone default now()
);
create table if not exists public.bookings (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  guest_name text,
  start_date date not null,
  end_date date not null,
  amount numeric default 0,
  status text default 'booked'::text,
  note text,
  created_at timestamp with time zone default now(),
  channel text default 'direct'::text,
  guest_phone text,
  paid boolean default false,
  paid_amount numeric default 0,
  currency text default 'EGP'::text,
  broker_name text,
  broker_comm_type text default 'pct'::text,
  broker_comm_value numeric,
  broker_comm_currency text default 'EGP'::text
);
create table if not exists public.collections (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  title text not null,
  amount numeric default 0,
  due_date date,
  status text default 'pending'::text,
  collected_at timestamp with time zone,
  note text,
  created_at timestamp with time zone default now(),
  currency text default 'EGP'::text
);
create table if not exists public.contracts (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  ctype text not null,
  city text,
  exclusive boolean default false,
  data jsonb default '{}'::jsonb,
  body text,
  created_at timestamp with time zone default now(),
  file_url text,
  source text default 'generated'::text
);
create table if not exists public.furniture_items (
  id uuid default gen_random_uuid() not null,
  name_ar text not null,
  name_en text,
  price numeric default 0,
  created_at timestamp with time zone default now()
);
create table if not exists public.invoices (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  report_id uuid,
  invoice_no text,
  owner_name text,
  invoice_date date default now(),
  items jsonb default '[]'::jsonb,
  notes text,
  created_at timestamp with time zone default now()
);
create table if not exists public.payouts (
  id uuid default gen_random_uuid() not null,
  owner_name text not null,
  upto_date date not null,
  from_date date,
  totals jsonb default '{}'::jsonb,
  note text,
  created_by text,
  created_at timestamp with time zone default now()
);
create table if not exists public.profiles (
  id uuid not null,
  username text not null,
  name text not null,
  role text default 'staff'::text not null,
  permissions jsonb default '[]'::jsonb not null,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.properties (
  id uuid default gen_random_uuid() not null,
  name text not null,
  owner_name text,
  owner_phone text,
  owner_mobile text,
  owner_email text,
  owner_passport text,
  owner_nationality text,
  owner_address text,
  owner_residence text,
  project text,
  city text default 'Hurghada'::text,
  building_no text,
  unit_no text,
  floor_no text,
  plot_no text,
  division text,
  area text,
  contract_type text,
  bank_account_name text,
  bank_account_no text,
  bank_iban text,
  bank_name text,
  bank_address text,
  bank_swift text,
  images jsonb default '[]'::jsonb,
  notes text,
  created_at timestamp with time zone default now(),
  rental_type text default 'short'::text,
  commission_pct numeric
);
create table if not exists public.property_furniture (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  item_id uuid,
  qty integer default 1,
  created_at timestamp with time zone default now()
);
create table if not exists public.reports (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  title text not null,
  report_date date default now(),
  situation text,
  images jsonb default '[]'::jsonb,
  created_at timestamp with time zone default now()
);
create table if not exists public.reviews (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  guest_name text,
  source text default 'direct'::text,
  rating integer default 5,
  comment text,
  status text default 'published'::text,
  reply text,
  created_at timestamp with time zone default now()
);
create table if not exists public.tasks (
  id uuid default gen_random_uuid() not null,
  property_id uuid,
  title text not null,
  task_type text default 'other'::text,
  start_date date,
  end_date date,
  is_range boolean default false,
  priority text default 'normal'::text,
  status text default 'pending'::text,
  done_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone default now()
);

do $c$ begin if not exists (select 1 from pg_constraint where conname = 'activity_pkey' and conrelid = 'public.activity'::regclass) then
  alter table public.activity add constraint activity_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'bookings_pkey' and conrelid = 'public.bookings'::regclass) then
  alter table public.bookings add constraint bookings_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'bookings_status_check' and conrelid = 'public.bookings'::regclass) then
  alter table public.bookings add constraint bookings_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'blocked'::text, 'confirmed'::text, 'checked_in'::text, 'checked_out'::text, 'cancelled'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'collections_pkey' and conrelid = 'public.collections'::regclass) then
  alter table public.collections add constraint collections_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'collections_status_check' and conrelid = 'public.collections'::regclass) then
  alter table public.collections add constraint collections_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'collected'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'contracts_pkey' and conrelid = 'public.contracts'::regclass) then
  alter table public.contracts add constraint contracts_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'furniture_items_pkey' and conrelid = 'public.furniture_items'::regclass) then
  alter table public.furniture_items add constraint furniture_items_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'invoices_pkey' and conrelid = 'public.invoices'::regclass) then
  alter table public.invoices add constraint invoices_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'payouts_pkey' and conrelid = 'public.payouts'::regclass) then
  alter table public.payouts add constraint payouts_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_username_key' and conrelid = 'public.profiles'::regclass) then
  alter table public.profiles add constraint profiles_username_key UNIQUE (username);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_pkey' and conrelid = 'public.profiles'::regclass) then
  alter table public.profiles add constraint profiles_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_role_check' and conrelid = 'public.profiles'::regclass) then
  alter table public.profiles add constraint profiles_role_check CHECK ((role = ANY (ARRAY['ceo'::text, 'manager'::text, 'accountant'::text, 'admin'::text, 'staff'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'properties_pkey' and conrelid = 'public.properties'::regclass) then
  alter table public.properties add constraint properties_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'property_furniture_pkey' and conrelid = 'public.property_furniture'::regclass) then
  alter table public.property_furniture add constraint property_furniture_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'reports_pkey' and conrelid = 'public.reports'::regclass) then
  alter table public.reports add constraint reports_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'reviews_pkey' and conrelid = 'public.reviews'::regclass) then
  alter table public.reviews add constraint reviews_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'reviews_status_check' and conrelid = 'public.reviews'::regclass) then
  alter table public.reviews add constraint reviews_status_check CHECK ((status = ANY (ARRAY['published'::text, 'pending'::text, 'flagged'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'tasks_pkey' and conrelid = 'public.tasks'::regclass) then
  alter table public.tasks add constraint tasks_pkey PRIMARY KEY (id);
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'tasks_status_check' and conrelid = 'public.tasks'::regclass) then
  alter table public.tasks add constraint tasks_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'done'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'tasks_priority_check' and conrelid = 'public.tasks'::regclass) then
  alter table public.tasks add constraint tasks_priority_check CHECK ((priority = ANY (ARRAY['normal'::text, 'high'::text, 'urgent'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'tasks_task_type_check' and conrelid = 'public.tasks'::regclass) then
  alter table public.tasks add constraint tasks_task_type_check CHECK ((task_type = ANY (ARRAY['cleaning'::text, 'maintenance'::text, 'inspection'::text, 'collection'::text, 'other'::text])));
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'activity_property_id_fkey' and conrelid = 'public.activity'::regclass) then
  alter table public.activity add constraint activity_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'bookings_property_id_fkey' and conrelid = 'public.bookings'::regclass) then
  alter table public.bookings add constraint bookings_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'collections_property_id_fkey' and conrelid = 'public.collections'::regclass) then
  alter table public.collections add constraint collections_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'contracts_property_id_fkey' and conrelid = 'public.contracts'::regclass) then
  alter table public.contracts add constraint contracts_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'invoices_report_id_fkey' and conrelid = 'public.invoices'::regclass) then
  alter table public.invoices add constraint invoices_report_id_fkey FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE SET NULL;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'invoices_property_id_fkey' and conrelid = 'public.invoices'::regclass) then
  alter table public.invoices add constraint invoices_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_id_fkey' and conrelid = 'public.profiles'::regclass) then
  alter table public.profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'property_furniture_property_id_fkey' and conrelid = 'public.property_furniture'::regclass) then
  alter table public.property_furniture add constraint property_furniture_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'property_furniture_item_id_fkey' and conrelid = 'public.property_furniture'::regclass) then
  alter table public.property_furniture add constraint property_furniture_item_id_fkey FOREIGN KEY (item_id) REFERENCES furniture_items(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'reports_property_id_fkey' and conrelid = 'public.reports'::regclass) then
  alter table public.reports add constraint reports_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'reviews_property_id_fkey' and conrelid = 'public.reviews'::regclass) then
  alter table public.reviews add constraint reviews_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;
do $c$ begin if not exists (select 1 from pg_constraint where conname = 'tasks_property_id_fkey' and conrelid = 'public.tasks'::regclass) then
  alter table public.tasks add constraint tasks_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE;
end if; end $c$;

CREATE INDEX IF NOT EXISTS bookings_prop_dates_idx ON public.bookings USING btree (property_id, start_date, end_date);
CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_key ON public.profiles USING btree (username);
CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_lower_idx ON public.profiles USING btree (lower(username));

CREATE OR REPLACE FUNCTION public.hv_authed()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select auth.uid() is not null
$function$;

CREATE OR REPLACE FUNCTION public.hv_bookings_guard_fin_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.hv_is_data() then
    return new;                     -- data roles may edit the whole booking
  end if;

  -- reaching here means the row passed RLS via bookings_update_fin only
  if new.id            is distinct from old.id
     or new.property_id is distinct from old.property_id
     or new.guest_name  is distinct from old.guest_name
     or new.guest_phone is distinct from old.guest_phone
     or new.start_date  is distinct from old.start_date
     or new.end_date    is distinct from old.end_date
     or new.amount      is distinct from old.amount
     or new.currency    is distinct from old.currency
     or new.status      is distinct from old.status
     or new.channel     is distinct from old.channel
     or new.note        is distinct from old.note
  then
    raise exception
      'أدوار الماليات يمكنها تعديل بيانات الدفع فقط | finance roles may only change payment fields on a booking'
      using errcode = '42501';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.hv_bookings_guard_paid()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.hv_is_fin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if coalesce(new.paid, false) is true or coalesce(new.paid_amount, 0) <> 0 then
      raise exception
        'ليس لديك صلاحية تسجيل الدفع على الحجز | setting booking payment fields requires a finance role'
        using errcode = '42501';
    end if;
  else
    if coalesce(new.paid, false)      is distinct from coalesce(old.paid, false)
       or coalesce(new.paid_amount,0) is distinct from coalesce(old.paid_amount,0)
    then
      raise exception
        'ليس لديك صلاحية تعديل بيانات الدفع على الحجز | changing booking payment fields requires a finance role'
        using errcode = '42501';
    end if;
  end if;

  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.hv_bookings_no_overlap()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  clash record;
begin
  if new.status = 'cancelled' or new.property_id is null then
    return new;
  end if;
  if new.start_date is null or new.end_date is null then
    return new;
  end if;
  -- malformed range: leave it to the app's own validation rather than
  -- crashing with an opaque daterange error / نطاق غير صالح: نتركه للواجهة
  if new.end_date < new.start_date then
    return new;
  end if;

  select b.id, b.guest_name, b.start_date, b.end_date, b.status
    into clash
  from public.bookings b
  where b.property_id = new.property_id
    and b.id is distinct from new.id
    and b.status <> 'cancelled'
    and daterange(b.start_date,   b.end_date,   '[)')
     && daterange(new.start_date, new.end_date, '[)')
  limit 1;

  if found then
    raise exception
      'يوجد حجز متعارض في نفس الفترة (% → %) — لا يمكن الحجز المزدوج | overlapping booking exists',
      to_char(clash.start_date, 'DD/MM/YYYY'), to_char(clash.end_date, 'DD/MM/YYYY')
      using errcode = '23P01';
  end if;

  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.hv_has_perm(perm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(public.hv_perms() ? perm, false)
$function$;

CREATE OR REPLACE FUNCTION public.hv_is_boss()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.hv_role() in ('ceo','manager')
$function$;

CREATE OR REPLACE FUNCTION public.hv_is_ceo()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.hv_role() = 'ceo'
$function$;

CREATE OR REPLACE FUNCTION public.hv_is_data()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.hv_role() in ('ceo','manager','admin')
      or public.hv_has_perm('tab:calendar')
$function$;

CREATE OR REPLACE FUNCTION public.hv_is_fin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.hv_role() in ('ceo','manager','accountant')
      or public.hv_has_perm('tab:collections')
$function$;

CREATE OR REPLACE FUNCTION public.hv_perms()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(p.permissions, '[]'::jsonb)
  from public.profiles p where p.id = auth.uid()
$function$;

CREATE OR REPLACE FUNCTION public.hv_profiles_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.hv_is_ceo() then
    return new;                     -- CEO may change anything
  end if;
  if new.id is distinct from old.id
     or new.username    is distinct from old.username
     or new.role        is distinct from old.role
     or new.permissions is distinct from old.permissions
  then
    raise exception
      'غير مسموح بتغيير الدور أو الصلاحيات | changing role/permissions/username requires CEO'
      using errcode = '42501';
  end if;
  return new;                       -- name-only edits are allowed
end $function$;

CREATE OR REPLACE FUNCTION public.hv_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p.role from public.profiles p where p.id = auth.uid()
$function$;

drop trigger if exists hv_bookings_guard_fin_scope_trg on public.bookings;
CREATE TRIGGER hv_bookings_guard_fin_scope_trg BEFORE UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION hv_bookings_guard_fin_scope();
drop trigger if exists hv_bookings_guard_paid_trg on public.bookings;
CREATE TRIGGER hv_bookings_guard_paid_trg BEFORE INSERT OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION hv_bookings_guard_paid();
drop trigger if exists hv_bookings_no_overlap_trg on public.bookings;
CREATE TRIGGER hv_bookings_no_overlap_trg BEFORE INSERT OR UPDATE OF property_id, start_date, end_date, status ON public.bookings FOR EACH ROW EXECUTE FUNCTION hv_bookings_no_overlap();
drop trigger if exists hv_profiles_guard_trg on public.profiles;
CREATE TRIGGER hv_profiles_guard_trg BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION hv_profiles_guard();

alter table public.activity enable row level security;
alter table public.bookings enable row level security;
alter table public.collections enable row level security;
alter table public.contracts enable row level security;
alter table public.furniture_items enable row level security;
alter table public.invoices enable row level security;
alter table public.payouts enable row level security;
alter table public.profiles enable row level security;
alter table public.properties enable row level security;
alter table public.property_furniture enable row level security;
alter table public.reports enable row level security;
alter table public.reviews enable row level security;
alter table public.tasks enable row level security;
drop policy if exists activity_delete on public.activity;
create policy activity_delete on public.activity for delete to authenticated using ((hv_authed() AND hv_is_ceo()));
drop policy if exists activity_insert on public.activity;
create policy activity_insert on public.activity for insert to authenticated with check (hv_authed());
drop policy if exists activity_select on public.activity;
create policy activity_select on public.activity for select to authenticated using (hv_authed());
drop policy if exists bookings_delete on public.bookings;
create policy bookings_delete on public.bookings for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists bookings_insert on public.bookings;
create policy bookings_insert on public.bookings for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists bookings_select on public.bookings;
create policy bookings_select on public.bookings for select to authenticated using (hv_authed());
drop policy if exists bookings_update on public.bookings;
create policy bookings_update on public.bookings for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists bookings_update_fin on public.bookings;
create policy bookings_update_fin on public.bookings for update to authenticated using ((hv_authed() AND hv_is_fin())) with check ((hv_authed() AND hv_is_fin()));
drop policy if exists collections_delete on public.collections;
create policy collections_delete on public.collections for delete to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists collections_insert on public.collections;
create policy collections_insert on public.collections for insert to authenticated with check ((hv_authed() AND hv_is_fin()));
drop policy if exists collections_select on public.collections;
create policy collections_select on public.collections for select to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists collections_update on public.collections;
create policy collections_update on public.collections for update to authenticated using ((hv_authed() AND hv_is_fin())) with check ((hv_authed() AND hv_is_fin()));
drop policy if exists contracts_delete on public.contracts;
create policy contracts_delete on public.contracts for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists contracts_insert on public.contracts;
create policy contracts_insert on public.contracts for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists contracts_select on public.contracts;
create policy contracts_select on public.contracts for select to authenticated using (hv_authed());
drop policy if exists contracts_update on public.contracts;
create policy contracts_update on public.contracts for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists furniture_items_delete on public.furniture_items;
create policy furniture_items_delete on public.furniture_items for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists furniture_items_insert on public.furniture_items;
create policy furniture_items_insert on public.furniture_items for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists furniture_items_select on public.furniture_items;
create policy furniture_items_select on public.furniture_items for select to authenticated using (hv_authed());
drop policy if exists furniture_items_update on public.furniture_items;
create policy furniture_items_update on public.furniture_items for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists invoices_delete on public.invoices;
create policy invoices_delete on public.invoices for delete to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists invoices_insert on public.invoices;
create policy invoices_insert on public.invoices for insert to authenticated with check ((hv_authed() AND hv_is_fin()));
drop policy if exists invoices_select on public.invoices;
create policy invoices_select on public.invoices for select to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists invoices_update on public.invoices;
create policy invoices_update on public.invoices for update to authenticated using ((hv_authed() AND hv_is_fin())) with check ((hv_authed() AND hv_is_fin()));
drop policy if exists payouts_delete on public.payouts;
create policy payouts_delete on public.payouts for delete to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists payouts_insert on public.payouts;
create policy payouts_insert on public.payouts for insert to authenticated with check ((hv_authed() AND hv_is_fin()));
drop policy if exists payouts_select on public.payouts;
create policy payouts_select on public.payouts for select to authenticated using ((hv_authed() AND hv_is_fin()));
drop policy if exists payouts_update on public.payouts;
create policy payouts_update on public.payouts for update to authenticated using ((hv_authed() AND hv_is_fin())) with check ((hv_authed() AND hv_is_fin()));
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated using ((hv_authed() AND hv_is_ceo() AND (id <> auth.uid())));
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated with check ((hv_authed() AND hv_is_ceo()));
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using ((hv_authed() AND ((id = auth.uid()) OR hv_is_ceo())));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using ((hv_authed() AND ((id = auth.uid()) OR hv_is_ceo()))) with check ((hv_authed() AND ((id = auth.uid()) OR hv_is_ceo())));
drop policy if exists properties_delete on public.properties;
create policy properties_delete on public.properties for delete to authenticated using ((hv_authed() AND hv_is_boss()));
drop policy if exists properties_insert on public.properties;
create policy properties_insert on public.properties for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists properties_select on public.properties;
create policy properties_select on public.properties for select to authenticated using (hv_authed());
drop policy if exists properties_update on public.properties;
create policy properties_update on public.properties for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists property_furniture_delete on public.property_furniture;
create policy property_furniture_delete on public.property_furniture for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists property_furniture_insert on public.property_furniture;
create policy property_furniture_insert on public.property_furniture for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists property_furniture_select on public.property_furniture;
create policy property_furniture_select on public.property_furniture for select to authenticated using (hv_authed());
drop policy if exists property_furniture_update on public.property_furniture;
create policy property_furniture_update on public.property_furniture for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated using (hv_authed());
drop policy if exists reports_update on public.reports;
create policy reports_update on public.reports for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists reviews_delete on public.reviews;
create policy reviews_delete on public.reviews for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews for select to authenticated using (hv_authed());
drop policy if exists reviews_update on public.reviews;
create policy reviews_update on public.reviews for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated using ((hv_authed() AND hv_is_data()));
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check ((hv_authed() AND hv_is_data()));
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using (hv_authed());
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated using ((hv_authed() AND hv_is_data())) with check ((hv_authed() AND hv_is_data()));

do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='activity') then
  alter publication supabase_realtime add table public.activity;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='bookings') then
  alter publication supabase_realtime add table public.bookings;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='collections') then
  alter publication supabase_realtime add table public.collections;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='contracts') then
  alter publication supabase_realtime add table public.contracts;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='furniture_items') then
  alter publication supabase_realtime add table public.furniture_items;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='invoices') then
  alter publication supabase_realtime add table public.invoices;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='payouts') then
  alter publication supabase_realtime add table public.payouts;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='profiles') then
  alter publication supabase_realtime add table public.profiles;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='properties') then
  alter publication supabase_realtime add table public.properties;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='property_furniture') then
  alter publication supabase_realtime add table public.property_furniture;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reports') then
  alter publication supabase_realtime add table public.reports;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reviews') then
  alter publication supabase_realtime add table public.reviews;
end if; end $p$;
do $p$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='tasks') then
  alter publication supabase_realtime add table public.tasks;
end if; end $p$;

-- ------------------------- storage buckets -------------------------
insert into storage.buckets (id, name, public) values ('hv-attachments','hv-attachments', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('property-files','property-files', false) on conflict (id) do nothing;

-- ------------------------- cross-system links -------------------------
alter table public.hv_users add column if not exists auth_user_id uuid references auth.users(id);
alter table public.hv_users add column if not exists email text;
alter table public.hv_users add column if not exists employee_id uuid references public.employees(id);
alter table public.hv_users add column if not exists is_active boolean not null default true;
alter table public.profiles add column if not exists employee_id uuid references public.employees(id);
create unique index if not exists uq_hv_users_auth on public.hv_users(auth_user_id) where auth_user_id is not null;
