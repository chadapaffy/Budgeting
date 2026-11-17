-- ระบบขอเบิกใช้งบประมาณ (ต้นแบบรอบใหม่) — เฟส 1: ล็อกอินและบัญชีผู้ใช้
-- ตารางทั้งหมดขึ้นต้นด้วย v2_ ไม่แตะตารางของระบบรอบแรก (profiles / app_*)
-- รันซ้ำได้ ไม่ลบข้อมูล · วางทั้งไฟล์ใน Supabase → SQL Editor → Run
--
-- หลักความปลอดภัย
--   * ตารางเปิด RLS และ "ไม่มี policy" = เบราว์เซอร์อ่าน/เขียนตารางตรงๆ ไม่ได้เลย ทุกอย่างผ่านฟังก์ชัน v2_* ที่ตรวจสิทธิ์ที่ฝั่งฐานข้อมูล
--   * การสร้างบัญชี / ลิงก์ตั้งรหัสผ่าน / ปิดบัญชี ทำผ่าน Edge Function (supabase/functions/v2-admin-users) ซึ่งถือ service_role ฝั่งเซิร์ฟเวอร์เท่านั้น

-- ---------------------------------------------------------------- ตาราง

create table if not exists public.v2_roles (
  key          text primary key,
  name         text not null,
  description  text not null default '',
  permissions  text[] not null default '{}',
  is_system    boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists public.v2_profiles (
  id                   uuid primary key references auth.users (id) on delete cascade,
  email                text not null,
  name                 text not null default '',
  title                text not null default '',
  department           text not null default '',
  company              text not null default '',
  companies            text[] not null default '{}',   -- บริษัทที่ดูงบ/งานได้ (ผู้คุมงบ / จัดซื้อ) · Admin เห็นทุกบริษัทเสมอ
  role                 text not null references public.v2_roles (key) on update cascade,
  active               boolean not null default true,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  last_login_at        timestamptz,
  reset_requested_at   timestamptz,                    -- ผู้ใช้กด "ลืมรหัสผ่าน"
  reset_at             timestamptz                     -- Admin รีเซ็ตรหัสผ่านล่าสุด
);
create unique index if not exists v2_profiles_email_key on public.v2_profiles (lower(email));

-- เพิ่มทีหลัง (รอบ "เปิดใช้ครั้งแรก"): เวลาที่ผู้ใช้ตั้งรหัสผ่านของตัวเอง · null = ยังไม่เคยตั้ง / ถูก Admin รีเซ็ตแล้ว รอตั้งใหม่
alter table public.v2_profiles add column if not exists password_set_at timestamptz;
update public.v2_profiles set password_set_at = last_login_at where password_set_at is null and last_login_at is not null;

alter table public.v2_roles    enable row level security;
alter table public.v2_profiles enable row level security;
revoke all on public.v2_roles, public.v2_profiles from anon, authenticated;

-- ---------------------------------------------------------------- ตัวช่วยภายใน (เบราว์เซอร์เรียกไม่ได้)

/** สิทธิ์ทั้งหมดของระบบ — ต้องตรงกับ PERMISSIONS ใน js/app.js */
create or replace function public._v2_perm_catalog() returns text[]
language sql immutable set search_path = public as $$
  select array['budget.view_all', 'budget.create', 'request.create', 'budget.verify', 'budget.adjust', 'budget.manage',
               'request.decide', 'cut.record', 'po.record', 'master.manage', 'data.export', 'log.view', 'user.manage']
$$;

-- บทบาทตั้งต้น (ไม่เขียนทับถ้า Admin แก้สิทธิ์ไว้แล้ว)
insert into public.v2_roles (key, name, description, permissions, is_system) values
  ('business',   'Business (ผู้ขอใช้งบ)',     '', array['budget.create', 'request.create'], true),
  ('controller', 'ผู้คุมงบ (บัญชีการเงิน)',    '', array['budget.view_all', 'budget.manage', 'budget.verify', 'budget.adjust', 'request.decide', 'cut.record', 'data.export'], true),
  ('purchasing', 'จัดซื้อ',                    '', array['budget.view_all', 'po.record'], true),
  ('admin',      'ผู้ดูแลระบบ (Admin)',        '', array['budget.view_all', 'master.manage', 'log.view', 'user.manage', 'data.export'], true)
on conflict (key) do nothing;

/** ผู้ใช้ที่ล็อกอินอยู่ (ต้อง active) */
create or replace function public._v2_user() returns public.v2_profiles
language sql stable security definer set search_path = public as $$
  select p.* from public.v2_profiles p where p.id = auth.uid() and p.active
$$;

create or replace function public._v2_perms(p_role text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select r.permissions from public.v2_roles r where r.key = p_role), '{}'::text[])
$$;

/** ต้องเป็นผู้ใช้ที่ active และบทบาทมีสิทธิ์ p_perm */
create or replace function public._v2_need(p_perm text) returns public.v2_profiles
language plpgsql stable security definer set search_path = public as $$
declare u public.v2_profiles;
begin
  u := public._v2_user();
  if u.id is null then
    raise exception 'ไม่มีสิทธิ์ใช้งาน (ไม่พบบัญชีในระบบ หรือบัญชีถูกปิดการใช้งาน)' using errcode = '42501';
  end if;
  if not (p_perm = any (public._v2_perms(u.role))) then
    raise exception 'ไม่มีสิทธิ์ทำรายการนี้' using errcode = '42501';
  end if;
  return u;
end $$;

/** จำนวนผู้ใช้ active ที่จัดการผู้ใช้/สิทธิ์ได้ ไม่นับผู้ใช้ p_ignore */
create or replace function public._v2_managers(p_ignore uuid) returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.v2_profiles p
  where p.active and (p_ignore is null or p.id <> p_ignore) and 'user.manage' = any (public._v2_perms(p.role))
$$;

create or replace function public._v2_user_json(p public.v2_profiles, p_full boolean) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'title', p.title, 'department', p.department, 'company', p.company,
    'companies', to_jsonb(p.companies), 'role', p.role, 'active', p.active)
    || case when p_full then jsonb_build_object(
      'email', p.email, 'createdAt', p.created_at, 'lastLoginAt', p.last_login_at,
      'resetRequestedAt', p.reset_requested_at, 'resetAt', p.reset_at, 'passwordSetAt', p.password_set_at) else '{}'::jsonb end
$$;

-- ---------------------------------------------------------------- ฟังก์ชันที่เบราว์เซอร์เรียก

/** ข้อมูลของตัวเอง + สิทธิ์ (p_login = true ตอนเพิ่งเข้าสู่ระบบ → บันทึกเวลาเข้าใช้ และล้างคำขอรีเซ็ตรหัสผ่าน) */
create or replace function public.v2_me(p_login boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare u public.v2_profiles;
begin
  u := public._v2_user();
  if u.id is null then return null; end if;
  if p_login then
    update public.v2_profiles set last_login_at = now(), reset_requested_at = null, password_set_at = coalesce(password_set_at, now()) where id = u.id returning * into u;
  end if;
  return public._v2_user_json(u, true) || jsonb_build_object('permissions', to_jsonb(public._v2_perms(u.role)));
end $$;

/** รายชื่อผู้ใช้ที่เปิดใช้งาน (ไม่มีอีเมล) — ไว้เลือก/แท็กงานถึงคน ใช้ได้ทุกคนที่ล็อกอิน */
create or replace function public.v2_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select id from public._v2_user()) is null then
    raise exception 'ไม่มีสิทธิ์ใช้งาน' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(public._v2_user_json(p, false) order by p.name) from public.v2_profiles p where p.active), '[]'::jsonb);
end $$;

/** รายชื่อผู้ใช้ทั้งหมดสำหรับหน้า Admin */
create or replace function public.v2_list_users() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._v2_need('user.manage');
  return coalesce((select jsonb_agg(public._v2_user_json(p, true) order by p.created_at, p.name) from public.v2_profiles p), '[]'::jsonb);
end $$;

/** แก้ข้อมูลบัญชี (ไม่รวมเปิด/ปิดใช้งานและอีเมล — ทำผ่าน Edge Function) */
create or replace function public.v2_update_user(p_id uuid, p_name text, p_title text, p_department text, p_company text, p_companies text[], p_role text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare target public.v2_profiles; r public.v2_roles;
begin
  perform public._v2_need('user.manage');
  select * into target from public.v2_profiles where id = p_id;
  if target.id is null then raise exception 'ไม่พบบัญชี'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'กรุณาระบุชื่อ'; end if;
  select * into r from public.v2_roles where key = p_role;
  if r.key is null then raise exception 'ไม่พบบทบาท'; end if;
  if target.active and 'user.manage' = any (public._v2_perms(target.role)) and not ('user.manage' = any (r.permissions))
     and public._v2_managers(target.id) = 0 then
    raise exception 'ต้องมีผู้ดูแลระบบที่เปิดใช้งานอย่างน้อย 1 คน' using errcode = '42501';
  end if;
  update public.v2_profiles set
    name = btrim(p_name), title = btrim(coalesce(p_title, '')), department = btrim(coalesce(p_department, '')),
    company = btrim(coalesce(p_company, '')), companies = coalesce(p_companies, '{}'), role = p_role
  where id = p_id returning * into target;
  return public._v2_user_json(target, true);
end $$;

/** ผู้ใช้กด "ลืมรหัสผ่าน" (ยังไม่ล็อกอิน) — ทำเครื่องหมายให้ Admin เห็น ตอบเหมือนกันไม่ว่ามีอีเมลนี้หรือไม่ */
create or replace function public.v2_request_reset(p_email text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  update public.v2_profiles set reset_requested_at = now() where lower(email) = lower(btrim(coalesce(p_email, ''))) and active;
  return true;
end $$;

/**
 * "เปิดใช้ครั้งแรก": ผู้ใช้กรอกอีเมลตัวเองที่หน้าล็อกอิน (ยังไม่ล็อกอิน) → ระบบตอบว่า Admin เพิ่มอีเมลนี้แล้วหรือยัง และตั้งรหัสผ่านแล้วหรือยัง
 *   not_found = ไม่มีอีเมลนี้ · inactive = ถูกปิดการใช้งาน · ready = เพิ่มแล้ว ยังไม่เคยตั้งรหัสผ่าน (ตั้งได้) · has_password = ตั้งแล้ว
 * (การตั้งรหัสผ่านจริงทำใน Edge Function ที่ตรวจสถานะนี้ซ้ำอีกครั้ง)
 */
create or replace function public.v2_activation_status(p_email text) returns text
language plpgsql stable security definer set search_path = public as $$
declare p public.v2_profiles;
begin
  select * into p from public.v2_profiles where lower(email) = lower(btrim(coalesce(p_email, '')));
  if p.id is null then return 'not_found'; end if;
  if not p.active then return 'inactive'; end if;
  if p.password_set_at is null then return 'ready'; end if;
  return 'has_password';
end $$;

create or replace function public.v2_list_roles() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if (select id from public._v2_user()) is null then
    raise exception 'ไม่มีสิทธิ์ใช้งาน' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'catalog', to_jsonb(public._v2_perm_catalog()),
    'roles', coalesce((select jsonb_agg(jsonb_build_object('key', r.key, 'name', r.name, 'description', r.description,
        'permissions', to_jsonb(r.permissions), 'isSystem', r.is_system) order by r.is_system desc, r.created_at, r.key) from public.v2_roles r), '[]'::jsonb));
end $$;

create or replace function public.v2_save_role(p_key text, p_name text, p_description text, p_permissions text[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare perms text[]; r public.v2_roles;
begin
  perform public._v2_need('user.manage');
  if p_key !~ '^[a-z][a-z0-9_]{1,30}$' then raise exception 'รหัสบทบาทต้องเป็นตัวอักษรอังกฤษพิมพ์เล็ก/ตัวเลข/_ ยาว 2-31 ตัว'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'กรุณาระบุชื่อบทบาท'; end if;
  perms := array(select k from unnest(public._v2_perm_catalog()) k where k = any (coalesce(p_permissions, '{}')));
  if p_key = 'admin' and not ('user.manage' = any (perms)) then
    raise exception 'บทบาท Admin ต้องมีสิทธิ์จัดการผู้ใช้เสมอ';
  end if;
  if exists (select 1 from public.v2_roles where key = p_key) and not ('user.manage' = any (perms))
     and 'user.manage' = any (public._v2_perms(p_key))
     and not exists (select 1 from public.v2_profiles p where p.active and p.role <> p_key and 'user.manage' = any (public._v2_perms(p.role))) then
    raise exception 'ต้องมีผู้ดูแลระบบที่เปิดใช้งานอย่างน้อย 1 คน' using errcode = '42501';
  end if;
  insert into public.v2_roles (key, name, description, permissions) values (p_key, btrim(p_name), coalesce(p_description, ''), perms)
  on conflict (key) do update set name = excluded.name, description = excluded.description, permissions = excluded.permissions
  returning * into r;
  return jsonb_build_object('key', r.key, 'name', r.name, 'description', r.description, 'permissions', to_jsonb(r.permissions), 'isSystem', r.is_system);
end $$;

create or replace function public.v2_delete_role(p_key text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare r public.v2_roles;
begin
  perform public._v2_need('user.manage');
  select * into r from public.v2_roles where key = p_key;
  if r.key is null then raise exception 'ไม่พบบทบาท'; end if;
  if r.is_system then raise exception 'ลบบทบาทตั้งต้นไม่ได้'; end if;
  if exists (select 1 from public.v2_profiles where role = p_key) then raise exception 'ยังมีผู้ใช้ใช้บทบาทนี้อยู่ ย้ายผู้ใช้ไปบทบาทอื่นก่อน'; end if;
  delete from public.v2_roles where key = p_key;
end $$;

-- ---------------------------------------------------------------- สิทธิ์เรียกฟังก์ชัน

revoke all on function public._v2_user(), public._v2_perms(text), public._v2_need(text), public._v2_managers(uuid),
  public._v2_user_json(public.v2_profiles, boolean), public._v2_perm_catalog() from public, anon, authenticated;

revoke all on function public.v2_me(boolean), public.v2_directory(), public.v2_list_users(),
  public.v2_update_user(uuid, text, text, text, text, text[], text), public.v2_request_reset(text),
  public.v2_list_roles(), public.v2_save_role(text, text, text, text[]), public.v2_delete_role(text) from public, anon, authenticated;

grant execute on function public.v2_me(boolean), public.v2_directory(), public.v2_list_users(),
  public.v2_update_user(uuid, text, text, text, text, text[], text),
  public.v2_list_roles(), public.v2_save_role(text, text, text, text[]), public.v2_delete_role(text) to authenticated;
grant execute on function public.v2_request_reset(text) to anon, authenticated;
revoke all on function public.v2_activation_status(text) from public, anon, authenticated;
grant execute on function public.v2_activation_status(text) to anon, authenticated;
