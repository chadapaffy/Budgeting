-- ทดสอบ schema_v2b.sql (เฟส 2a) กับ Postgres ในเครื่อง — ต้องรัน shim.sql, schema_v2.sql, schema_v2b.sql ก่อน
--   psql -v ON_ERROR_STOP=1 -d sp -f shim.sql -f ../schema_v2.sql -f ../schema_v2b.sql -f v2b_test.sql
\set ON_ERROR_STOP on

insert into auth.users (id, email)
select ('00000000-0000-0000-0000-0000000000' || lpad(g::text, 2, '0'))::uuid, 'u' || g || '@example.com' from generate_series(1, 8) g;
-- 01 admin · 02 ผู้คุมงบ PBI · 03 ผู้คุมงบ PCC · 04 จัดซื้อ PBI · 05 business1 · 06 business2 · 07 ผู้คุมงบที่ปิดใช้งาน · 08 ผู้คุมงบไม่มีบริษัท
insert into public.v2_profiles (id, email, name, role, companies, active) values
  ('00000000-0000-0000-0000-000000000001', 'u1@example.com', 'Admin', 'admin', '{}', true),
  ('00000000-0000-0000-0000-000000000002', 'u2@example.com', 'CtrlPBI', 'controller', '{PBI}', true),
  ('00000000-0000-0000-0000-000000000003', 'u3@example.com', 'CtrlPCC', 'controller', '{PCC}', true),
  ('00000000-0000-0000-0000-000000000004', 'u4@example.com', 'PurPBI', 'purchasing', '{PBI}', true),
  ('00000000-0000-0000-0000-000000000005', 'u5@example.com', 'Biz1', 'business', '{}', true),
  ('00000000-0000-0000-0000-000000000006', 'u6@example.com', 'Biz2', 'business', '{}', true),
  ('00000000-0000-0000-0000-000000000007', 'u7@example.com', 'Off', 'controller', '{PBI}', false),
  ('00000000-0000-0000-0000-000000000008', 'u8@example.com', 'NoCo', 'controller', '{}', true);
grant usage on schema public to anon, authenticated;

create or replace function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', ('00000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0')), false);
end $$;
grant execute on function pg_temp.as_user(int) to public;
create or replace function pg_temp.expect_fail(sql text, label text, expect text default '') returns void language plpgsql as $$
begin
  begin execute sql; exception when others then
    if expect <> '' and sqlerrm not like '%' || expect || '%' then raise exception 'FAIL: % ผิดข้อความ: %', label, sqlerrm; end if;
    raise notice 'PASS: % (%)', label, sqlerrm; return; end;
  raise exception 'FAIL: % ควรถูกปฏิเสธ', label;
end $$;
grant execute on function pg_temp.expect_fail(text, text, text) to public;
create or replace function pg_temp.ok(c boolean, label text) returns void language plpgsql as $$
begin if not c then raise exception 'FAIL: %', label; end if; raise notice 'PASS: %', label; end $$;
grant execute on function pg_temp.ok(boolean, text) to public;
create or replace function pg_temp.ids(j jsonb, k text) returns text language sql as $$
  select coalesce(string_agg(x ->> 'id', ',' order by x ->> 'id'), '') from jsonb_array_elements(j -> 'docs') x where x ->> 'kind' = k and not (x ->> 'deleted')::boolean
$$;
grant execute on function pg_temp.ids(jsonb, text) to public;

set role authenticated;

-- ---------------------------------------------------------------- ข้อมูลหลัก: เฉพาะผู้มีสิทธิ์ master.manage
select pg_temp.as_user(5);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"master","id":"master","version":0,"data":{"companies":[]}}]')$$, 'business เขียนข้อมูลหลักไม่ได้', 'ไม่มีสิทธิ์');
select pg_temp.as_user(2);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"master","id":"master","version":0,"data":{"companies":[]}}]')$$, 'ผู้คุมงบเขียนข้อมูลหลักไม่ได้', 'ไม่มีสิทธิ์');
select pg_temp.as_user(1);
select public.v2_save_docs('[{"kind":"master","id":"master","version":0,"data":{"companies":[{"code":"PBI"}]}}]');
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"master","id":"master","version":0,"data":{"x":1}}]')$$, 'สร้างข้อมูลหลักซ้ำ (version 0) = CONFLICT', 'CONFLICT');
do $$ begin
  perform pg_temp.ok((select public.v2_save_docs('[{"kind":"master","id":"master","version":1,"data":{"companies":[{"code":"PBI"},{"code":"PCC"}]}}]') -> 'docs' -> 0 ->> 'version') = '2', 'Admin แก้ข้อมูลหลัก version 1→2');
end $$;
-- ทุกคนอ่านข้อมูลหลักได้
select pg_temp.as_user(5);
select pg_temp.ok(pg_temp.ids(public.v2_load(), 'master') = 'master', 'business อ่านข้อมูลหลักได้');

-- ---------------------------------------------------------------- งบ: เจ้าของ / บริษัท
select pg_temp.as_user(1);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"bX","version":0,"data":{"company":"PBI","ownerId":"x"}}]')$$, 'Admin ทำรายการงบไม่ได้', 'ไม่มีสิทธิ์');

select pg_temp.as_user(5);
select public.v2_save_docs('[{"kind":"budget","id":"b1","version":0,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000005","code":"A"}}]',
  '[{"action":"สร้างงบ","ref":"งบ A","detail":"ทดสอบ","ownerId":"00000000-0000-0000-0000-000000000005","company":"PBI"}]');
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"b2","version":0,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000006","code":"B"}}]')$$, 'business สร้างงบให้คนอื่นเป็นเจ้าของไม่ได้', 'นอกขอบเขต');
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"b3","version":0,"data":{"company":"PBI","code":"C"}}]')$$, 'business สร้างงบที่ไม่มีเจ้าของ (มองไม่เห็น) ไม่ได้', 'นอกขอบเขต');

-- การมองเห็น
select pg_temp.as_user(5); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = 'b1', 'เจ้าของเห็นงบตัวเอง');
select pg_temp.as_user(6); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = '', 'business คนอื่นไม่เห็น');
select pg_temp.as_user(2); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = 'b1', 'ผู้คุมงบ PBI เห็นงบ PBI');
select pg_temp.as_user(3); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = '', 'ผู้คุมงบ PCC ไม่เห็นงบ PBI');
select pg_temp.as_user(4); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = 'b1', 'จัดซื้อ PBI เห็นงบ PBI');
select pg_temp.as_user(8); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = '', 'ผู้คุมงบที่ไม่ได้กำหนดบริษัทไม่เห็นงบเลย');
select pg_temp.as_user(1); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = 'b1', 'Admin เห็นทุกบริษัท');
select pg_temp.as_user(7); select pg_temp.expect_fail($$select public.v2_load()$$, 'บัญชีที่ปิดใช้งานโหลดไม่ได้', 'ไม่มีสิทธิ์');

-- แก้ไขงบ: ผู้คุมงบ PBI แก้ได้ · PCC แก้ไม่ได้ · business คนอื่นแก้ไม่ได้ · เวอร์ชันเก่า = CONFLICT
select pg_temp.as_user(3);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"b1","version":1,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000005","code":"HACK"}}]')$$, 'ผู้คุมงบ PCC แก้งบ PBI ไม่ได้', 'ไม่มีสิทธิ์');
select pg_temp.as_user(6);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"b1","version":1,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000006","code":"HACK"}}]')$$, 'business คนอื่นแย่งความเป็นเจ้าของงบไม่ได้', 'ไม่มีสิทธิ์');
select pg_temp.as_user(2);
select public.v2_save_docs('[{"kind":"budget","id":"b1","version":1,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000005","code":"A","by":"ctrl"}}]');
select pg_temp.as_user(5);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"b1","version":1,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000005","code":"A","by":"stale"}}]')$$, 'บันทึกทับด้วยเวอร์ชันเก่า = CONFLICT', 'CONFLICT');
reset role;
select pg_temp.ok((select data ->> 'by' from public.v2_docs where id = 'b1') = 'ctrl', 'ข้อมูลไม่ถูกเขียนทับเมื่อ CONFLICT');
set role authenticated;

-- ---------------------------------------------------------------- คำขอเบิก + ออกเลขที่
select pg_temp.as_user(5);
do $$ declare r jsonb; begin
  r := public.v2_save_docs(
    '[{"kind":"request","id":"r1","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","no":"@@NO:REQ-2026:aaaa1111@@","memoNo":"@@NO:REQ-2026:aaaa1111@@"}},
      {"kind":"request","id":"r2","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","no":"@@NO:REQ-2026:bbbb2222@@"}}]',
    '[{"action":"สร้างคำขอ","ref":"@@NO:REQ-2026:aaaa1111@@","detail":"เลขที่ @@NO:REQ-2026:aaaa1111@@"}]');
  perform pg_temp.ok(r -> 'tokens' ->> '@@NO:REQ-2026:aaaa1111@@' = 'REQ-2026-0001' and r -> 'tokens' ->> '@@NO:REQ-2026:bbbb2222@@' = 'REQ-2026-0002', 'ออกเลขตามลำดับ ไม่ซ้ำ');
  perform pg_temp.ok(r -> 'log' -> 0 ->> 'ref' = 'REQ-2026-0001' and r -> 'log' -> 0 ->> 'detail' = 'เลขที่ REQ-2026-0001', 'แทนที่ token ใน Log ด้วย');
end $$;
reset role;
select pg_temp.ok((select data ->> 'memoNo' from public.v2_docs where id = 'r1') = 'REQ-2026-0001' and (select data ->> 'no' from public.v2_docs where id = 'r1') = 'REQ-2026-0001', 'เลขในเอกสารถูกแทนที่แล้ว');
select pg_temp.ok((select company from public.v2_docs where id = 'r1') = 'PBI' and (select owner_id from public.v2_docs where id = 'r1') = '00000000-0000-0000-0000-000000000005', 'บริษัท/เจ้าของของคำขอมาจากงบที่อ้างอิง');
set role authenticated;

-- ชุดที่ CONFLICT ไม่กินเลข และไม่บันทึกอะไรเลย (ทั้งชุด)
select pg_temp.as_user(5);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"request","id":"r3","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","no":"@@NO:REQ-2026:cccc3333@@"}},{"kind":"request","id":"r1","version":99,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005"}}]')$$, 'ชุดที่มี CONFLICT ถูกปฏิเสธทั้งชุด', 'CONFLICT');
do $$ declare r jsonb; begin
  r := public.v2_save_docs('[{"kind":"request","id":"r3","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","no":"@@NO:REQ-2026:dddd4444@@"}}]');
  perform pg_temp.ok(r -> 'tokens' ->> '@@NO:REQ-2026:dddd4444@@' = 'REQ-2026-0003', 'เลขที่ไม่มีช่องว่างหลังชุดที่ล้มเหลว');
  r := public.v2_save_docs('[{"kind":"request","id":"r4","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","no":"@@NO:CAPEX-2026:eeee5555@@","x":"@@NO:REQ-2027:ffff6666@@"}}]');
  perform pg_temp.ok(r -> 'tokens' ->> '@@NO:CAPEX-2026:eeee5555@@' = 'CAPEX-2026-0001' and r -> 'tokens' ->> '@@NO:REQ-2027:ffff6666@@' = 'REQ-2027-0001', 'ตัวนับแยกตามคำนำหน้าและปี');
end $$;

-- ปลอมผู้ขอ / ข้ามบริษัท
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"request","id":"r5","version":0,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000006"}}]')$$, 'business ปลอมผู้ขอเป็นคนอื่นไม่ได้', 'นอกขอบเขต');
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"request","id":"r6","version":0,"data":{"budgetId":"ไม่มีจริง","requesterId":"00000000-0000-0000-0000-000000000005"}}]')$$, 'อ้างงบที่ไม่มีอยู่ไม่ได้', 'ไม่พบงบ');
select pg_temp.as_user(3);
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"request","id":"r1","version":1,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","status":"HACK"}}]')$$, 'ผู้คุมงบ PCC แก้คำขอของงบ PBI ไม่ได้', 'ไม่มีสิทธิ์');

-- การมองเห็นคำขอ
select pg_temp.as_user(5); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'request') = 'r1,r2,r3,r4', 'ผู้ขอเห็นคำขอของตัวเอง');
select pg_temp.as_user(6); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'request') = '', 'business คนอื่นไม่เห็นคำขอ');
select pg_temp.as_user(2); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'request') = 'r1,r2,r3,r4', 'ผู้คุมงบ PBI เห็นทุกคำขอของบริษัท');
select pg_temp.as_user(3); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'request') = '', 'ผู้คุมงบ PCC ไม่เห็นคำขอ PBI');
-- จัดซื้อบันทึก PR/PO ที่คำขอได้ · ผู้คุมงบตัดสินใจได้
select pg_temp.as_user(4);
select public.v2_save_docs('[{"kind":"request","id":"r1","version":1,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","po":"PO-1"}}]');
select pg_temp.as_user(2);
select public.v2_save_docs('[{"kind":"request","id":"r1","version":2,"data":{"budgetId":"b1","requesterId":"00000000-0000-0000-0000-000000000005","po":"PO-1","status":"approved"}}]');

-- ---------------------------------------------------------------- คำขอเพิ่มงบ (change)
select pg_temp.as_user(5);
select public.v2_save_docs('[{"kind":"change","id":"c1","version":0,"data":{"budgetId":"b1","no":"@@NO:INC-2026:gggg7777@@"}}]');
select pg_temp.ok(pg_temp.ids(public.v2_load(), 'change') = 'c1', 'เจ้าของงบเห็นคำขอเพิ่มงบของงบตัวเอง');
select pg_temp.as_user(6); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'change') = '', 'business คนอื่นไม่เห็นคำขอเพิ่มงบ');
select pg_temp.as_user(3); select pg_temp.ok(pg_temp.ids(public.v2_load(), 'change') = '', 'ผู้คุมงบ PCC ไม่เห็นคำขอเพิ่มงบ PBI');

-- ---------------------------------------------------------------- ลบ + ซิงก์เพิ่มเติม (since)
select pg_temp.as_user(5);
select public.v2_save_docs('[{"kind":"budget","id":"b9","version":0,"data":{"company":"PBI","ownerId":"00000000-0000-0000-0000-000000000005","code":"ลบ"}}]');
do $$ declare t timestamptz; ld jsonb; begin
  t := (public.v2_load() ->> 'now')::timestamptz;
  perform public.v2_save_docs('[{"kind":"budget","id":"b9","version":1,"deleted":true}]');
  ld := public.v2_load(t);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(ld -> 'docs') x where x ->> 'id' = 'b9' and (x ->> 'deleted')::boolean), 'ซิงก์เพิ่มเติมได้เอกสารที่ถูกลบ (tombstone)');
  perform pg_temp.ok(not (ld ->> 'full')::boolean, 'โหลดเพิ่มเติมไม่ใช่การโหลดทั้งหมด');
  perform pg_temp.ok(pg_temp.ids(public.v2_load(), 'budget') = 'b1', 'โหลดทั้งหมดไม่มีเอกสารที่ลบแล้ว');
end $$;
select pg_temp.expect_fail($$select public.v2_save_docs('[{"kind":"budget","id":"nope","version":1,"deleted":true}]')$$, 'ลบเอกสารที่ไม่มีอยู่ไม่ได้', 'CONFLICT');

-- ---------------------------------------------------------------- Log
select pg_temp.as_user(5);
do $$ declare lg jsonb; begin
  lg := public.v2_load() -> 'log';
  perform pg_temp.ok(jsonb_array_length(lg) >= 1 and (lg -> 0 ->> 'by') = '00000000-0000-0000-0000-000000000005', 'ผู้ใช้เห็น Log ของตัวเอง');
end $$;
select pg_temp.as_user(6); select pg_temp.ok(jsonb_array_length(public.v2_load() -> 'log') = 0, 'business คนอื่นไม่เห็น Log ของคนอื่น');
select pg_temp.as_user(1); select pg_temp.ok(jsonb_array_length(public.v2_load() -> 'log') >= 1, 'ผู้มีสิทธิ์ log.view เห็น Log ทั้งหมด');
select pg_temp.as_user(2);
do $$ begin
  perform public.v2_save_docs('[]', '[{"action":"ปลอมผู้ทำ","ref":"x","detail":"by ควรเป็นผู้ล็อกอิน","by":"00000000-0000-0000-0000-000000000001"}]');
end $$;
reset role;
select pg_temp.ok((select by_id::text from public.v2_log where action = 'ปลอมผู้ทำ') = '00000000-0000-0000-0000-000000000002', 'Log บันทึกผู้ทำเป็นผู้ล็อกอิน ไม่เชื่อค่าจากเบราว์เซอร์');
set role authenticated;

-- ---------------------------------------------------------------- เรียกตรงๆ ไม่ได้
select pg_temp.as_user(5);
select pg_temp.expect_fail($$select * from public.v2_docs$$, 'อ่านตารางเอกสารตรงๆ ไม่ได้');
select pg_temp.expect_fail($$update public.v2_docs set data = '{}'$$, 'แก้ตารางเอกสารตรงๆ ไม่ได้');
select pg_temp.expect_fail($$select * from public.v2_counters$$, 'อ่านตัวนับตรงๆ ไม่ได้');
select pg_temp.expect_fail($$select * from public.v2_log$$, 'อ่าน Log ตรงๆ ไม่ได้');
select pg_temp.expect_fail($$select public._v2_can_write('admin', 'budget')$$, 'เรียกฟังก์ชันภายในไม่ได้');
reset role; set role anon;
select pg_temp.expect_fail($$select public.v2_load()$$, 'anon โหลดไม่ได้');
select pg_temp.expect_fail($$select public.v2_save_docs('[]')$$, 'anon บันทึกไม่ได้');
reset role;
\echo ALL V2B TESTS PASSED
