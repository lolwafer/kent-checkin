-- v5:打卡时间窗口(7:00–17:00)+ 员工看自己记录 + 修改申请审批流
select set_config('search_path', 'public, extensions', false);

alter table public.kent_punches add column if not exists manual boolean not null default false;

create table if not exists public.kent_requests (
  id bigserial primary key,
  employee_id bigint not null references public.kent_employees(id) on delete cascade,
  work_date date not null,
  new_in time not null,
  new_out time not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table public.kent_requests enable row level security;

-- 打卡:加时间窗口(纽约时间 7:00–17:00)
create or replace function public.kent_punch(p_token uuid, p_type text, p_lat float8, p_lng float8, p_dist int)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees; last_type text; z record; d float8; best_d float8; best_r int; nyt time;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'err', '登录已失效,请找管理员重新登录', 'relogin', true); end;
  if p_type not in ('in', 'out') then return json_build_object('ok', false, 'err', 'bad type'); end if;

  nyt := (now() at time zone 'America/New_York')::time;
  if nyt < time '07:00' or nyt >= time '17:01' then
    return json_build_object('ok', false, 'err', '打卡时间为早上 7:00 到下午 5:00,现在不能打卡。如需补记,请在下方申请修改。');
  end if;

  if p_lat is null or p_lng is null then return json_build_object('ok', false, 'err', '没有定位信息,不能打卡'); end if;
  for z in select * from kent_zones loop
    if z.only_names is null or e.name = any(z.only_names) then
      d := kent_dist_m(p_lat, p_lng, z.lat, z.lng);
      if best_d is null or d < best_d then best_d := d; best_r := z.radius_m; end if;
    end if;
  end loop;
  if best_d is null or best_d > best_r then
    return json_build_object('ok', false, 'err',
      '不在打卡范围内(距最近打卡点约 ' || round(best_d * 3.28084) || ' 尺),打卡失败');
  end if;

  select type into last_type from kent_punches
   where employee_id = e.id
     and (created_at at time zone 'America/New_York')::date = (now() at time zone 'America/New_York')::date
   order by created_at desc limit 1;
  if p_type = 'in' and last_type = 'in' then return json_build_object('ok', false, 'err', '你已经打过上班卡了'); end if;
  if p_type = 'out' and (last_type is null or last_type = 'out') then
    return json_build_object('ok', false, 'err', '今天还没打上班卡,不能打下班卡');
  end if;
  insert into kent_punches(employee_id, type, location_lat, location_lng, distance)
  values (e.id, p_type, p_lat, p_lng, round(best_d)::int);
  return json_build_object('ok', true, 'punches', kent_today_list(e.id));
end $$;

-- 员工看自己某月记录 + 自己的修改申请
create or replace function public.kent_my_month(p_token uuid, p_month text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'relogin', true); end;
  if p_month !~ '^\d{4}-\d{2}$' then return json_build_object('ok', false, 'err', 'bad month'); end if;
  return json_build_object('ok', true,
    'punches', (select coalesce(json_agg(json_build_object(
        'type', type, 'manual', manual,
        'd', to_char(created_at at time zone 'America/New_York', 'YYYY-MM-DD'),
        'hhmm', to_char(created_at at time zone 'America/New_York', 'HH24:MI')) order by created_at), '[]'::json)
      from kent_punches
      where employee_id = e.id
        and to_char(created_at at time zone 'America/New_York', 'YYYY-MM') = p_month),
    'requests', (select coalesce(json_agg(json_build_object(
        'd', to_char(work_date, 'YYYY-MM-DD'),
        'in', to_char(new_in, 'HH24:MI'), 'out', to_char(new_out, 'HH24:MI'),
        'reason', reason, 'status', status) order by work_date desc), '[]'::json)
      from kent_requests
      where employee_id = e.id and work_date > (now() at time zone 'America/New_York')::date - 62));
end $$;

-- 员工提交修改申请(同一天旧的待审申请会被新的覆盖)
create or replace function public.kent_request_fix(p_token uuid, p_date date, p_in time, p_out time, p_reason text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees; today date;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'err', '登录已失效,请找管理员重新登录', 'relogin', true); end;
  today := (now() at time zone 'America/New_York')::date;
  if p_date is null or p_in is null or p_out is null then return json_build_object('ok', false, 'err', '请把日期和上下班时间填完整'); end if;
  if p_date > today then return json_build_object('ok', false, 'err', '不能申请未来的日期'); end if;
  if p_date < today - 62 then return json_build_object('ok', false, 'err', '只能修改最近两个月内的记录'); end if;
  if p_in >= p_out then return json_build_object('ok', false, 'err', '下班时间要晚于上班时间'); end if;
  if p_in < time '07:00' or p_out > time '17:00' then
    return json_build_object('ok', false, 'err', '时间必须在早上 7:00 到下午 5:00 之间');
  end if;
  delete from kent_requests where employee_id = e.id and work_date = p_date and status = 'pending';
  insert into kent_requests(employee_id, work_date, new_in, new_out, reason)
  values (e.id, p_date, p_in, p_out, coalesce(p_reason, ''));
  return json_build_object('ok', true);
end $$;

-- 管理报表:加 manual 标记 + 待审批申请列表
create or replace function public.kent_admin_report(p_code text, p_month text)
returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  if p_month !~ '^\d{4}-\d{2}$' then return json_build_object('ok', false, 'err', 'bad month'); end if;
  return json_build_object('ok', true,
    'punches', (select coalesce(json_agg(json_build_object(
        'name', e.name, 'type', p.type, 'manual', p.manual,
        'd', to_char(p.created_at at time zone 'America/New_York', 'YYYY-MM-DD'),
        'hhmm', to_char(p.created_at at time zone 'America/New_York', 'HH24:MI'),
        'dist', p.distance) order by p.created_at), '[]'::json)
      from kent_punches p join kent_employees e on e.id = p.employee_id
      where to_char(p.created_at at time zone 'America/New_York', 'YYYY-MM') = p_month),
    'employees', (select coalesce(json_agg(json_build_object(
        'name', name, 'rate', hourly_rate, 'active', active,
        'has_pw', password_hash is not null, 'must_change', must_change,
        'pw', password_plain) order by id), '[]'::json)
      from kent_employees),
    'requests', (select coalesce(json_agg(json_build_object(
        'id', r.id, 'name', e.name,
        'd', to_char(r.work_date, 'YYYY-MM-DD'),
        'in', to_char(r.new_in, 'HH24:MI'), 'out', to_char(r.new_out, 'HH24:MI'),
        'reason', r.reason,
        'at', to_char(r.created_at at time zone 'America/New_York', 'MM-DD HH24:MI')) order by r.created_at), '[]'::json)
      from kent_requests r join kent_employees e on e.id = r.employee_id
      where r.status = 'pending'));
end $$;

-- 管理员批准/拒绝:批准 = 当天记录替换为申请的一对上下班卡(manual 标记)
create or replace function public.kent_admin_decide(p_code text, p_req_id bigint, p_approve boolean)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  select * into r from kent_requests where id = p_req_id and status = 'pending';
  if not found then return json_build_object('ok', false, 'err', '这条申请不存在或已处理过'); end if;
  if p_approve then
    delete from kent_punches
     where employee_id = r.employee_id
       and (created_at at time zone 'America/New_York')::date = r.work_date;
    insert into kent_punches(employee_id, type, created_at, manual)
    values (r.employee_id, 'in',  (r.work_date || ' ' || r.new_in)::timestamp at time zone 'America/New_York', true),
           (r.employee_id, 'out', (r.work_date || ' ' || r.new_out)::timestamp at time zone 'America/New_York', true);
    update kent_requests set status = 'approved', decided_at = now() where id = r.id;
  else
    update kent_requests set status = 'rejected', decided_at = now() where id = r.id;
  end if;
  return json_build_object('ok', true);
end $$;
