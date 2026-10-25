-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_056.sql
-- TASK FILES IN THE MAINTENANCE SYSTEM (Daniel, 2026-10-25): the same
-- idea as HR's files (migration_055) — a file like "Solymar" groups a
-- series of maintenance tasks; the file shows how far it is (done / all)
-- and who did each task and how fast. The tasks themselves stay normal
-- hv_tasks rows, so they still appear in My Day and All tasks; only the
-- file view lives in its own page "الملفات".
--   hv_task_files      the files (maintenance keeps its allow-all style)
--   hv_tasks.file_id   which file a task belongs to (null = none)
-- ADDITIVE ONLY. Safe to re-run. Run after 055.
-- =====================================================================

create table if not exists public.hv_task_files (
  id              bigserial primary key,
  name            text not null,
  description     text,
  status          text not null default 'open',
  created_by      bigint,                -- hv_users.id
  created_by_name text,
  created_at      timestamptz not null default now(),
  completed_at    timestamptz,
  updated_at      timestamptz not null default now(),
  constraint hv_task_files_name_chk   check (btrim(name) <> ''),
  constraint hv_task_files_status_chk check (status in ('open', 'complete', 'archived'))
);
alter table public.hv_tasks add column if not exists file_id bigint references public.hv_task_files(id) on delete set null;
create index if not exists hv_tasks_file on public.hv_tasks (file_id);

alter table public.hv_task_files enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'hv_task_files' and policyname = 'allow_all_task_files') then
    create policy allow_all_task_files on public.hv_task_files for all to authenticated using (true) with check (true);
  end if;
end $$;
revoke all on table public.hv_task_files from anon;
grant select, insert, update, delete on table public.hv_task_files to authenticated;
grant usage, select on sequence public.hv_task_files_id_seq to authenticated;

-- a maintenance task is "done" for the file when it was finished (mission complete) or passed a review
create or replace function public.hv_file_refresh(p_file bigint)
returns void language plpgsql security definer set search_path = public as $fn$
declare v_open int; v_done int;
begin
  if p_file is null then return; end if;
  select count(*) filter (where t.actual_completion_date is null and t.admin_revised_at is null and t.supervisor_revised_at is null),
         count(*) filter (where t.actual_completion_date is not null or t.admin_revised_at is not null or t.supervisor_revised_at is not null)
    into v_open, v_done from hv_tasks t where t.file_id = p_file;
  update hv_task_files
     set status = case when status = 'archived' then 'archived' when v_open = 0 and v_done > 0 then 'complete' else 'open' end,
         completed_at = case when v_open = 0 and v_done > 0 then coalesce(completed_at, now()) else null end,
         updated_at = now()
   where id = p_file;
end;
$fn$;
create or replace function public.hv_tasks_file_touch()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  begin
    if tg_op = 'DELETE' then perform public.hv_file_refresh(old.file_id); return old; end if;
    perform public.hv_file_refresh(new.file_id);
    if tg_op = 'UPDATE' and old.file_id is distinct from new.file_id then perform public.hv_file_refresh(old.file_id); end if;
  exception when others then null;
  end;
  return new;
end;
$fn$;
drop trigger if exists trg_hv_tasks_file_touch on public.hv_tasks;
create trigger trg_hv_tasks_file_touch after insert or update of file_id, actual_completion_date, admin_revised_at, supervisor_revised_at or delete on public.hv_tasks
  for each row execute function public.hv_tasks_file_touch();
notify pgrst, 'reload schema';
