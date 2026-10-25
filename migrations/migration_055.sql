-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_055.sql
-- TASK FILES (Daniel, 2026-10-25): tasks are grouped under a "file"
-- (e.g. "Solymar") or stay in General tasks. A file holds a series of
-- tasks that can be added and removed; each task moves To do -> In
-- progress -> Done; the file shows how complete it is (done / all) and
-- who did each task and how fast (started -> done). When every task is
-- done the file is complete (100%).
--   * hr_task_files            the files (everyone may read)
--   * hr_tasks.file_id / sort  which file a task sits in (null = General)
--   * hr_file_save / hr_file_delete / hr_task_create / hr_task_move
--                              the only ways to write (RLS stays read-only)
--   * hr_files_overview()      files with their progress and who worked
--                              on them, for everybody (counts all tasks,
--                              even those the viewer may not read)
-- Who may create files and tasks: CEO, HR, and managers (for their own
-- team and themselves). Done stays final, as before.
-- ADDITIVE ONLY. Safe to re-run. Run after 054.
-- =====================================================================

create table if not exists public.hr_task_files (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  description     text,
  status          text not null default 'open',
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now(),
  completed_at    timestamptz,
  updated_at      timestamptz not null default now(),
  constraint hr_task_files_name_chk   check (btrim(name) <> ''),
  constraint hr_task_files_status_chk check (status in ('open', 'complete', 'archived'))
);
alter table public.hr_tasks add column if not exists file_id uuid references public.hr_task_files(id);
alter table public.hr_tasks add column if not exists sort int not null default 0;
create index if not exists hr_tasks_file on public.hr_tasks (file_id, status);

alter table public.hr_task_files enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'hr_task_files' and policyname = 'hr_task_files_select') then
    create policy hr_task_files_select on public.hr_task_files for select to authenticated using (true);
  end if;
end $$;
revoke all on table public.hr_task_files from anon;
revoke insert, update, delete, truncate, references, trigger on table public.hr_task_files from authenticated;
grant select on table public.hr_task_files to authenticated;

-- a file is complete when it has tasks and none is still open (cancelled ones do not count)
create or replace function public.hr_file_refresh(p_file uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare v_open int; v_done int;
begin
  if p_file is null then return; end if;
  select count(*) filter (where status in ('todo', 'doing')), count(*) filter (where status = 'done') into v_open, v_done from hr_tasks where file_id = p_file;
  update hr_task_files
     set status = case when status = 'archived' then 'archived' when v_open = 0 and v_done > 0 then 'complete' else 'open' end,
         completed_at = case when v_open = 0 and v_done > 0 then coalesce(completed_at, now()) else null end,
         updated_at = now()
   where id = p_file;
end;
$fn$;
create or replace function public.hr_tasks_file_touch()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  begin
    if tg_op = 'DELETE' then perform public.hr_file_refresh(old.file_id); return old; end if;
    perform public.hr_file_refresh(new.file_id);
    if tg_op = 'UPDATE' and old.file_id is distinct from new.file_id then perform public.hr_file_refresh(old.file_id); end if;
  exception when others then null;
  end;
  return new;
end;
$fn$;
drop trigger if exists trg_hr_tasks_file_touch on public.hr_tasks;
create trigger trg_hr_tasks_file_touch after insert or update of status, file_id or delete on public.hr_tasks
  for each row execute function public.hr_tasks_file_touch();

-- who may organise: CEO, HR, managers (their team + themselves)
create or replace function public.hr_can_give(p_employee uuid)
returns boolean language sql stable security definer set search_path = public as $fn$
  select public.has_role('ceo', 'hr')
      or (public.has_role('manager') and (p_employee = public.my_employee_id()
          or exists (select 1 from employees e where e.id = p_employee and e.manager_id = public.my_employee_id())));
$fn$;

create or replace function public.hr_file_save(p_id uuid, p_name text, p_description text default null)
returns public.hr_task_files language plpgsql volatile security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_f public.hr_task_files; v_name text;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  if not public.has_role('ceo', 'hr', 'manager') then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'NAME_REQUIRED'; end if;
  select coalesce(nullif(a.full_name_en, ''), a.full_name_ar, a.username) into v_name from app_users a where a.id = v_uid;
  if p_id is null then
    insert into hr_task_files (name, description, created_by, created_by_name)
    values (btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''), v_uid, v_name) returning * into v_f;
  else
    update hr_task_files set name = btrim(p_name), description = nullif(btrim(coalesce(p_description, '')), ''), updated_at = now()
     where id = p_id returning * into v_f;
    if v_f.id is null then raise exception 'FILE_NOT_FOUND'; end if;
  end if;
  return v_f;
end;
$fn$;

-- delete a file: its open tasks go back to General; done ones keep the file name in their note history (file_id cleared)
create or replace function public.hr_file_delete(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $fn$
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  if not public.has_role('ceo', 'hr') then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  update hr_tasks set file_id = null, updated_at = now() where file_id = p_id;
  delete from hr_task_files where id = p_id;
end;
$fn$;

create or replace function public.hr_task_create(p_task jsonb)
returns public.hr_tasks language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid(); v_emp uuid; v_t public.hr_tasks; v_name text; v_file uuid; v_sort int;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  v_emp := nullif(p_task->>'employee_id', '')::uuid;
  if v_emp is null then raise exception 'EMPLOYEE_REQUIRED'; end if;
  if not public.hr_can_give(v_emp) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if btrim(coalesce(p_task->>'title', '')) = '' then raise exception 'TITLE_REQUIRED'; end if;
  v_file := nullif(p_task->>'file_id', '')::uuid;
  if v_file is not null and not exists (select 1 from hr_task_files where id = v_file) then raise exception 'FILE_NOT_FOUND'; end if;
  select coalesce(nullif(a.full_name_en, ''), a.full_name_ar, a.username) into v_name from app_users a where a.id = v_uid;
  select coalesce(max(sort), 0) + 1 into v_sort from hr_tasks where file_id is not distinct from v_file;
  insert into hr_tasks (title, description, employee_id, assigned_to, priority, due_date, status, source, created_by, created_by_name, file_id, sort)
  select btrim(p_task->>'title'), nullif(btrim(coalesce(p_task->>'description', '')), ''), v_emp, e.user_id,
         case when p_task->>'priority' in ('low', 'normal', 'high', 'urgent') then p_task->>'priority' else 'normal' end,
         nullif(p_task->>'due_date', '')::date, 'todo', 'hr', v_uid, v_name, v_file, v_sort
    from employees e where e.id = v_emp
  returning * into v_t;
  return v_t;
end;
$fn$;

create or replace function public.hr_task_move(p_id uuid, p_file uuid)
returns public.hr_tasks language plpgsql volatile security definer set search_path = public as $fn$
declare v_t public.hr_tasks;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  select * into v_t from hr_tasks where id = p_id;
  if v_t.id is null then raise exception 'TASK_NOT_FOUND'; end if;
  if not (public.has_role('ceo', 'hr') or v_t.created_by = auth.uid()) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if p_file is not null and not exists (select 1 from hr_task_files where id = p_file) then raise exception 'FILE_NOT_FOUND'; end if;
  update hr_tasks set file_id = p_file, updated_at = now() where id = p_id returning * into v_t;
  return v_t;
end;
$fn$;

-- the files with their progress and the people who worked on them (everyone sees the same numbers)
create or replace function public.hr_files_overview()
returns table (id uuid, name text, description text, status text, created_by_name text, created_at timestamptz, completed_at timestamptz,
               total int, todo int, doing int, done int, cancelled int, pct int, workers jsonb)
language sql stable security definer set search_path = public as $fn$
  with s as (
    select t.file_id,
           count(*) filter (where t.status <> 'cancelled') total,
           count(*) filter (where t.status = 'todo') todo,
           count(*) filter (where t.status = 'doing') doing,
           count(*) filter (where t.status = 'done') done,
           count(*) filter (where t.status = 'cancelled') cancelled
      from hr_tasks t group by t.file_id
  ), w as (
    select t.file_id, t.employee_id,
           count(*) filter (where t.status = 'done') done,
           count(*) filter (where t.status in ('todo', 'doing')) open,
           avg(extract(epoch from (t.completed_at - coalesce(t.started_at, t.created_at)))) filter (where t.status = 'done') avg_secs,
           sum(extract(epoch from (t.completed_at - coalesce(t.started_at, t.created_at)))) filter (where t.status = 'done') total_secs,
           count(*) filter (where t.status = 'done' and t.due_date is not null and t.completed_at::date > t.due_date) late
      from hr_tasks t group by t.file_id, t.employee_id
  )
  select f.id, f.name, f.description, f.status, f.created_by_name, f.created_at, f.completed_at,
         coalesce(s.total, 0)::int, coalesce(s.todo, 0)::int, coalesce(s.doing, 0)::int, coalesce(s.done, 0)::int, coalesce(s.cancelled, 0)::int,
         case when coalesce(s.total, 0) = 0 then 0 else round(100.0 * s.done / s.total)::int end,
         coalesce((select jsonb_agg(jsonb_build_object('employee_id', w.employee_id, 'done', w.done, 'open', w.open, 'avg_secs', round(coalesce(w.avg_secs, 0)), 'total_secs', round(coalesce(w.total_secs, 0)), 'late', w.late) order by w.done desc, w.avg_secs)
                   from w where w.file_id = f.id), '[]'::jsonb)
    from hr_task_files f left join s on s.file_id = f.id
   where f.status <> 'archived'
   order by (f.status = 'complete'), f.created_at desc;
$fn$;

revoke all on function public.hr_file_refresh(uuid), public.hr_can_give(uuid) from public, anon, authenticated;
revoke all on function public.hr_file_save(uuid, text, text), public.hr_file_delete(uuid), public.hr_task_create(jsonb), public.hr_task_move(uuid, uuid), public.hr_files_overview() from public, anon;
grant execute on function public.hr_file_save(uuid, text, text), public.hr_file_delete(uuid), public.hr_task_create(jsonb), public.hr_task_move(uuid, uuid), public.hr_files_overview() to authenticated;
notify pgrst, 'reload schema';
