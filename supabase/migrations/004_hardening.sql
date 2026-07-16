-- v4 加固:服务器端围栏 + 登录限速 + 一次性密码(登录即换)
select set_config('search_path', 'public, extensions', false);

-- 打卡点表(服务器端围栏)
create table if not exists public.kent_zones (
  id bigserial primary key,
  name text not null,
  lat float8 not null,
  lng float8 not null,
  radius_m int not null,
  only_names text[]  -- null = 所有人可用
);
alter table public.kent_zones enable row level security;

delete from public.kent_zones;
insert into public.kent_zones(name, lat, lng, radius_m, only_names) values
 ('Kent 中心', 40.7638555, -73.8196091, 50, null),
 ('Great Neck', 40.7994795, -73.7449667, 50, array['wafer']);

-- 登录失败记录(限速用)
create table if not exists public.kent_login_fails (
  id bigserial primary key,
  ip text,
  ts timestamptz not null default now()
);
alter table public.kent_login_fails enable row level security;
create index if not exists idx_kent_login_fails_ts on kent_login_fails(ts);

-- 球面距离(米)
create or replace function public.kent_dist_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)));
$$;

-- 登录:限速 + 成功后自动换新密码(一次性密码)
create or replace function public.kent_login_pw(p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_ip text; v_fails int; e record; cnt int := 0; hit record; t uuid; newpw text;
begin
  begin
    v_ip := coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', 'unknown');
  exception when others then v_ip := 'unknown'; end;
  perform pg_sleep(0.25);  -- 拖慢暴力尝试
  delete from kent_login_fails where ts < now() - interval '1 day';
  select count(*) into v_fails from kent_login_fails f
   where f.ip = v_ip and f.ts > now() - interval '10 minutes';
  if v_fails >= 6 then
    return json_build_object('ok', false, 'err', '尝试次数太多,请 10 分钟后再试');
  end if;

  for e in select * from kent_employees where active and password_hash is not null loop
    if e.password_hash = crypt(p_password, e.password_hash) then
      cnt := cnt + 1; hit := e;
    end if;
  end loop;
  if cnt <> 1 then
    insert into kent_login_fails(ip) values (v_ip);
    return json_build_object('ok', false, 'err', '密码不对');
  end if;

  -- 登录成功:生成新的一次性密码(旧密码立即作废)
  loop
    newpw := lpad(floor(random() * 1000000)::int::text, 6, '0');
    exit when not exists(select 1 from kent_employees where password_plain = newpw);
  end loop;
  update kent_employees
     set password_plain = newpw, password_hash = crypt(newpw, gen_salt('bf'))
   where id = hit.id;

  insert into kent_sessions(employee_id) values (hit.id) returning token into t;
  return json_build_object('ok', true, 'token', t, 'name', hit.name);
end $$;

-- 打卡:服务器端也校验围栏
create or replace function public.kent_punch(p_token uuid, p_type text, p_lat float8, p_lng float8, p_dist int)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e public.kent_employees; last_type text; z record; d float8; best_d float8; best_r int;
begin
  begin e := kent_auth(p_token);
  exception when others then return json_build_object('ok', false, 'err', '登录已失效,请找管理员重新登录', 'relogin', true); end;
  if p_type not in ('in', 'out') then return json_build_object('ok', false, 'err', 'bad type'); end if;
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
