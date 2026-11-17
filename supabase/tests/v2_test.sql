-- ทดสอบ schema_v2.sql กับ Postgres ในเครื่อง (ต้องรัน shim.sql ก่อน) — ล้มเหลวเมื่อมี exception หลุด
--   psql -v ON_ERROR_STOP=1 -d sp -f shim.sql -f ../schema_v2.sql -f v2_test.sql
\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'admin@example.com'),
  ('00000000-0000-0000-0000-000000000002', 'ctrl@example.com'),
  ('00000000-0000-0000-0000-000000000003', 'biz@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'admin2@example.com');
insert into public.v2_profiles (id, email, name, role, companies) values
  ('00000000-0000-0000-0000-000000000001', 'admin@example.com', 'Admin', 'admin', '{}'),
  ('00000000-0000-0000-0000-000000000002', 'ctrl@example.com', 'Ctrl', 'controller', '{PBI}'),
  ('00000000-0000-0000-0000-000000000003', 'biz@example.com', 'Biz', 'business', '{}');
grant usage on schema public to anon, authenticated;

create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice 'PASS: % (%)', label, sqlerrm; return; end;
  raise exception 'FAIL: % ควรถูกปฏิเสธ', label;
end $$;
grant execute on function pg_temp.expect_fail(text, text) to public;

-- ผู้ใช้ทั่วไปเรียกตารางตรงๆ ไม่ได้
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
select pg_temp.expect_fail($$select * from public.v2_profiles$$, 'อ่านตารางตรงไม่ได้');
select pg_temp.expect_fail($$select public._v2_need('user.manage')$$, 'เรียกฟังก์ชันภายในไม่ได้');
select pg_temp.expect_fail($$select public.v2_list_users()$$, 'business ดูรายชื่อ Admin ไม่ได้');
select pg_temp.expect_fail($$select public.v2_save_role('x1', 'X', '', '{}')$$, 'business สร้างบทบาทไม่ได้');

-- directory: ใช้ได้ทุกคนที่ล็อกอิน และไม่มีอีเมล
do $$ declare d jsonb; begin
  d := public.v2_directory();
  if jsonb_array_length(d) <> 3 then raise exception 'FAIL directory count %', d; end if;
  if d::text like '%@example.com%' then raise exception 'FAIL directory ไม่ควรมีอีเมล'; end if;
  raise notice 'PASS: directory';
end $$;

-- ผู้ใช้ที่ไม่มี profile
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
select pg_temp.expect_fail($$select public.v2_directory()$$, 'ไม่มี profile เข้าไม่ได้');
do $$ begin if public.v2_me() is not null then raise exception 'FAIL v2_me ควรเป็น null'; end if; raise notice 'PASS: v2_me null เมื่อไม่มี profile'; end $$;

-- anon ขอรีเซ็ตได้ เรียกอย่างอื่นไม่ได้
reset role; set role anon;
select public.v2_request_reset(' CTRL@example.com ');
select public.v2_request_reset('nobody@example.com');
select pg_temp.expect_fail($$select public.v2_directory()$$, 'anon ดู directory ไม่ได้');

reset role;
do $$ begin
  if (select reset_requested_at from public.v2_profiles where email = 'ctrl@example.com') is null then raise exception 'FAIL reset_requested_at'; end if;
  raise notice 'PASS: ขอรีเซ็ตรหัสผ่านบันทึกแล้ว';
end $$;

-- ผู้คุมงบ login → ล้างคำขอรีเซ็ต + สิทธิ์
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
do $$ declare m jsonb; begin
  m := public.v2_me(true);
  if m ->> 'role' <> 'controller' or not (m -> 'permissions') ? 'budget.verify' or (m -> 'permissions') ? 'user.manage' then raise exception 'FAIL perms %', m; end if;
  if m ->> 'resetRequestedAt' is not null then raise exception 'FAIL ควรล้างคำขอรีเซ็ต'; end if;
  raise notice 'PASS: v2_me(login)';
end $$;

-- Admin จัดการผู้ใช้/บทบาท
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
do $$ declare u jsonb; r jsonb; begin
  if jsonb_array_length(public.v2_list_users()) <> 3 then raise exception 'FAIL list_users'; end if;
  u := public.v2_update_user('00000000-0000-0000-0000-000000000003', 'Biz 2', 'วิศวกร', 'IT', 'PBI', '{PBI,PCC}', 'controller');
  if u ->> 'role' <> 'controller' or jsonb_array_length(u -> 'companies') <> 2 then raise exception 'FAIL update_user %', u; end if;
  raise notice 'PASS: Admin แก้ผู้ใช้';
  r := public.v2_save_role('auditor', 'ผู้ตรวจสอบ', 'อ่านอย่างเดียว', array['budget.view_all', 'not.real']);
  if jsonb_array_length(r -> 'permissions') <> 1 then raise exception 'FAIL save_role ต้องตัดสิทธิ์ที่ไม่มีในระบบ %', r; end if;
  raise notice 'PASS: สร้างบทบาท';
end $$;
select pg_temp.expect_fail($$select public.v2_save_role('Bad Key', 'x', '', '{}')$$, 'รหัสบทบาทผิดรูปแบบ');
select pg_temp.expect_fail($$select public.v2_save_role('admin', 'Admin', '', array['budget.view_all'])$$, 'admin ต้องมี user.manage');
select pg_temp.expect_fail($$select public.v2_update_user('00000000-0000-0000-0000-000000000001', 'Admin', '', '', '', '{}', 'business')$$, 'ลดสิทธิ์ Admin คนสุดท้ายไม่ได้');
select pg_temp.expect_fail($$select public.v2_delete_role('admin')$$, 'ลบบทบาทตั้งต้นไม่ได้');
select pg_temp.expect_fail($$select public.v2_update_user('00000000-0000-0000-0000-000000000003', '', '', '', '', '{}', 'business')$$, 'ชื่อว่างไม่ได้');
do $$ begin
  perform public.v2_update_user('00000000-0000-0000-0000-000000000003', 'Biz 2', '', '', 'PBI', '{PBI}', 'auditor');
  begin perform public.v2_delete_role('auditor'); raise exception 'FAIL ลบบทบาทที่ยังมีผู้ใช้'; exception when others then
    if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: ลบบทบาทที่มีผู้ใช้ไม่ได้'; end;
  perform public.v2_update_user('00000000-0000-0000-0000-000000000003', 'Biz 2', '', '', 'PBI', '{PBI}', 'business');
  perform public.v2_delete_role('auditor');
  raise notice 'PASS: ลบบทบาทที่สร้างเพิ่ม';
end $$;

-- มี Admin ที่สอง → ลดสิทธิ์คนแรกได้
reset role;
insert into public.v2_profiles (id, email, name, role) values ('00000000-0000-0000-0000-000000000004', 'admin2@example.com', 'Admin2', 'admin');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
do $$ begin
  perform public.v2_update_user('00000000-0000-0000-0000-000000000001', 'Admin', '', '', '', '{}', 'business');
  raise notice 'PASS: ลดสิทธิ์ได้เมื่อมี Admin อื่น';
end $$;
select pg_temp.expect_fail($$select public.v2_list_users()$$, 'หลังลดสิทธิ์ ดูรายชื่อไม่ได้');

-- ผู้ใช้ที่ถูกปิดใช้งานเข้าไม่ได้
reset role;
update public.v2_profiles set active = false where email = 'admin2@example.com';
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
select pg_temp.expect_fail($$select public.v2_list_users()$$, 'บัญชีที่ปิดใช้งานเข้าไม่ได้');

reset role;
\echo ALL V2 TESTS PASSED
