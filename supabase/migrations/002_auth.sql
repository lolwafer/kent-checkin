-- Kent 打卡 v2:每人账号密码 + 管理员口令
select set_config('search_path', 'public, extensions', false);
create extension if not exists pgcrypto with schema extensions;

-- 员工表加字段
alter table public.kent_employees
  add column if not exists password_hash text,
  add column if not exists must_change boolean not null default true,
  add column if not exists hourly_rate numeric not null default 0,
  add column if not exists active boolean not null default true;

-- 登录会话表
create table if not exists public.kent_sessions (
  token uuid primary key default gen_random_uuid(),
  employee_id bigint not null references public.kent_employees(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
alter table public.kent_sessions enable row level security;

-- 配置表(存管理员口令哈希)
create table if not exists public.kent_config (key text primary key, value text not null);
alter table public.kent_config enable row level security;

insert into public.kent_config(key, value)
values ('admin_hash', crypt('BB45BD13', gen_salt('bf')))
on conflict (key) do update set value = excluded.value;

-- 收紧旧的匿名直读/直写策略,全部改走下面的函数
drop policy if exists "kent_read_emp" on public.kent_employees;
drop policy if exists "kent_insert_punch" on public.kent_punches;
drop policy if exists "kent_read_punch" on public.kent_punches;

-- ===== 函数 =====

create or replace function public.kent_names()
returns table(id bigint, name text)
language sql security definer set search_path = public, extensions as $$
  select id, name from kent_employees where active order by id;
$$;

create or replace function public.kent_auth(p_token uuid)
returns public.kent_employees
language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees;
begin
  select emp.* into e from kent_sessions s join kent_employees emp on emp.id = s.employee_id
   where s.token = p_token and emp.active;
  if not found then raise exception 'invalid-session'; end if;
  update kent_sessions set last_seen = now() where token = p_token;
  return e;
end $$;
revoke execute on function public.kent_auth(uuid) from public, anon, authenticated;

create or replace function public.kent_login(p_name text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e record; t uuid;
begin
  select * into e from kent_employees where name = p_name and active;
  if not found then return json_build_object('ok', false, 'err', '名字或密码不对'); end if;
  if e.password_hash is null then return json_build_object('ok', false, 'err', '还没设初始密码,请找管理员'); end if;
  if e.password_hash <> crypt(p_password, e.password_hash) then
    return json_build_object('ok', false, 'err', '名字或密码不对');
  end if;
  insert into kent_sessions(employee_id) values (e.id) returning token into t;
  return json_build_object('ok', true, 'token', t, 'name', e.name, 'must_change', e.must_change);
end $$;

create or replace function public.kent_change_password(p_token uuid, p_old text, p_new text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'err', '登录已失效,请重新登录', 'relogin', true); end;
  if e.password_hash <> crypt(p_old, e.password_hash) then
    return json_build_object('ok', false, 'err', '旧密码不对');
  end if;
  if length(p_new) < 4 then return json_build_object('ok', false, 'err', '新密码至少 4 位'); end if;
  update kent_employees set password_hash = crypt(p_new, gen_salt('bf')), must_change = false where id = e.id;
  delete from kent_sessions where employee_id = e.id and token <> p_token; -- 踢掉其他设备
  return json_build_object('ok', true);
end $$;

create or replace function public.kent_today_list(p_emp bigint)
returns json language sql security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('type', type,
           'hhmm', to_char(created_at at time zone 'America/New_York', 'HH24:MI')) order by created_at), '[]'::json)
  from kent_punches
  where employee_id = p_emp
    and (created_at at time zone 'America/New_York')::date = (now() at time zone 'America/New_York')::date;
$$;
revoke execute on function public.kent_today_list(bigint) from public, anon, authenticated;

create or replace function public.kent_my_today(p_token uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'relogin', true); end;
  return json_build_object('ok', true, 'name', e.name, 'must_change', e.must_change, 'punches', kent_today_list(e.id));
end $$;

create or replace function public.kent_punch(p_token uuid, p_type text, p_lat float8, p_lng float8, p_dist int)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees; last_type text;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'err', '登录已失效,请重新登录', 'relogin', true); end;
  if e.must_change then return json_build_object('ok', false, 'err', '请先修改密码'); end if;
  if p_type not in ('in', 'out') then return json_build_object('ok', false, 'err', 'bad type'); end if;
  select type into last_type from kent_punches
   where employee_id = e.id
     and (created_at at time zone 'America/New_York')::date = (now() at time zone 'America/New_York')::date
   order by created_at desc limit 1;
  if p_type = 'in' and last_type = 'in' then return json_build_object('ok', false, 'err', '你已经打过上班卡了'); end if;
  if p_type = 'out' and (last_type is null or last_type = 'out') then
    return json_build_object('ok', false, 'err', '今天还没打上班卡,不能打下班卡');
  end if;
  insert into kent_punches(employee_id, type, location_lat, location_lng, distance)
  values (e.id, p_type, p_lat, p_lng, p_dist);
  return json_build_object('ok', true, 'punches', kent_today_list(e.id));
end $$;

create or replace function public.kent_logout(p_token uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from kent_sessions where token = p_token;
  return json_build_object('ok', true);
end $$;

create or replace function public.kent_admin_ok(p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from kent_config where key = 'admin_hash';
  return h is not null and h = crypt(p_code, h);
end $$;
revoke execute on function public.kent_admin_ok(text) from public, anon, authenticated;

create or replace function public.kent_admin_report(p_code text, p_month text)
returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  if p_month !~ '^\d{4}-\d{2}$' then return json_build_object('ok', false, 'err', 'bad month'); end if;
  return json_build_object('ok', true,
    'punches', (select coalesce(json_agg(json_build_object(
        'name', e.name, 'type', p.type,
        'd', to_char(p.created_at at time zone 'America/New_York', 'YYYY-MM-DD'),
        'hhmm', to_char(p.created_at at time zone 'America/New_York', 'HH24:MI'),
        'dist', p.distance) order by p.created_at), '[]'::json)
      from kent_punches p join kent_employees e on e.id = p.employee_id
      where to_char(p.created_at at time zone 'America/New_York', 'YYYY-MM') = p_month),
    'employees', (select coalesce(json_agg(json_build_object(
        'name', name, 'rate', hourly_rate, 'active', active,
        'has_pw', password_hash is not null, 'must_change', must_change) order by id), '[]'::json)
      from kent_employees));
end $$;

create or replace function public.kent_admin_reset(p_code text, p_name text, p_new text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare eid bigint;
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  if length(p_new) < 4 then return json_build_object('ok', false, 'err', '密码至少 4 位'); end if;
  select id into eid from kent_employees where name = p_name;
  if not found then return json_build_object('ok', false, 'err', '没有这个员工'); end if;
  update kent_employees set password_hash = crypt(p_new, gen_salt('bf')), must_change = true where id = eid;
  delete from kent_sessions where employee_id = eid; -- 踢掉该员工所有设备
  return json_build_object('ok', true);
end $$;

create or replace function public.kent_admin_set_rate(p_code text, p_name text, p_rate numeric)
returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  update kent_employees set hourly_rate = p_rate where name = p_name;
  if not found then return json_build_object('ok', false, 'err', '没有这个员工'); end if;
  return json_build_object('ok', true);
end $$;
