-- Kent Senior Center 打卡系统初始化

-- 员工表
create table if not exists public.employees (
  id bigserial primary key,
  name text not null unique,
  created_at timestamp with time zone default now()
);

-- 打卡记录表
create table if not exists public.punches (
  id bigserial primary key,
  employee_id bigint not null references employees(id) on delete cascade,
  type text not null check (type in ('in', 'out')),
  created_at timestamp with time zone default now(),
  location_lat float,
  location_lng float,
  distance int
);

-- 初始化三个员工
insert into public.employees (name) values ('marco'), ('andy'), ('小e')
on conflict (name) do nothing;

-- 创建索引
create index if not exists idx_punches_employee_date on punches(employee_id, created_at);
create index if not exists idx_punches_date on punches(created_at);

-- RLS 策略
alter table public.employees enable row level security;
alter table public.punches enable row level security;

-- employees: 所有人可读
create policy "Enable read for all" on public.employees for select to anon, authenticated using (true);

-- punches: 所有人可插入(打卡), 只有 owner 可读
drop policy if exists "Enable insert for all" on public.punches;
create policy "Enable insert for all" on public.punches for insert to anon, authenticated with check (true);

drop policy if exists "Enable read for owner" on public.punches;
create policy "Enable read for owner" on public.punches for select to authenticated using (
  (select auth.email()) = 'lolwafer@me.com'
);
