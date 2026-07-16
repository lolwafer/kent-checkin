-- v3:只输密码登录(密码认人)、密码唯一性检查、加 wafer 测试账号
select set_config('search_path', 'public, extensions', false);

insert into public.kent_employees (name, must_change, active)
values ('wafer', false, true)
on conflict (name) do nothing;

create or replace function public.kent_login_pw(p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e record; t uuid; cnt int := 0; hit record;
begin
  for e in select * from kent_employees where active and password_hash is not null loop
    if e.password_hash = crypt(p_password, e.password_hash) then
      cnt := cnt + 1; hit := e;
    end if;
  end loop;
  if cnt = 0 then return json_build_object('ok', false, 'err', '密码不对'); end if;
  if cnt > 1 then return json_build_object('ok', false, 'err', '密码冲突,请找管理员'); end if;
  insert into kent_sessions(employee_id) values (hit.id) returning token into t;
  return json_build_object('ok', true, 'token', t, 'name', hit.name);
end $$;

create or replace function public.kent_admin_reset(p_code text, p_name text, p_new text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare eid bigint;
begin
  if not kent_admin_ok(p_code) then return json_build_object('ok', false, 'err', '管理员口令不对'); end if;
  if length(p_new) < 4 then return json_build_object('ok', false, 'err', '密码至少 4 位'); end if;
  select id into eid from kent_employees where name = p_name;
  if not found then return json_build_object('ok', false, 'err', '没有这个员工'); end if;
  if exists(select 1 from kent_employees where id <> eid and password_plain = p_new) then
    return json_build_object('ok', false, 'err', '这个密码已被其他员工使用,换一个');
  end if;
  update kent_employees set password_hash = crypt(p_new, gen_salt('bf')), password_plain = p_new, must_change = false where id = eid;
  delete from kent_sessions where employee_id = eid;
  return json_build_object('ok', true);
end $$;

update public.kent_employees set must_change = false;
