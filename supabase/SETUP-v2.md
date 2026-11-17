# ตั้งค่า Supabase — เฟส 1: ล็อกอินและบัญชีผู้ใช้จริง

ใช้กับระบบรอบใหม่ (ตารางขึ้นต้น `v2_` ไม่แตะตารางของระบบรอบแรก) · ทำครั้งเดียว ประมาณ 20 นาที
เฟสนี้ย้ายเฉพาะ **ล็อกอิน บัญชี บทบาทและสิทธิ์** ไปไว้บนเซิร์ฟเวอร์ — ข้อมูลงบ/คำขอยังเก็บในเบราว์เซอร์ (เฟส 2 จะย้ายขึ้นฐานข้อมูล)

## 1. ตั้งค่าการล็อกอิน (Authentication)
**Authentication → Sign In / Providers → Email**
- เปิด Email provider
- **ปิด** "Allow new users to sign up" (ให้ผู้ดูแลเพิ่มผู้ใช้เท่านั้น)

**Authentication → URL Configuration**
- **Site URL** = `https://chadapaffy.github.io/Budgeting/`
- **Redirect URLs** เพิ่ม `https://chadapaffy.github.io/Budgeting/` (ลิงก์ตั้งรหัสผ่านจะพากลับมาที่นี่)

> ระบบนี้ **ไม่ส่งอีเมลเชิญ** — Admin ได้ "ลิงก์ตั้งรหัสผ่าน" ในหน้า Admin แล้วส่งให้ผู้ใช้เอง (LINE / อีเมลของ Admin) จึงไม่ต้องตั้ง SMTP ลิงก์ใช้ได้ครั้งเดียวและหมดอายุเร็ว (ตั้งเวลาได้ที่ Authentication → Sessions / Email: OTP expiration)

## 2. สร้างตารางและฟังก์ชัน
**SQL Editor → New query** → วางเนื้อหา [`schema_v2.sql`](schema_v2.sql) ทั้งไฟล์ → **Run** (รันซ้ำได้ ไม่ลบข้อมูล)

## 3. สร้างผู้ดูแลระบบคนแรก
1. **Authentication → Users → Add user → Create new user** ใส่อีเมลจริง + รหัสผ่านที่คุณตั้งเอง (ติ๊ก **Auto Confirm User**)
2. กลับ SQL Editor แล้วรัน (แก้อีเมลและชื่อ):
   ```sql
   insert into public.v2_profiles (id, email, name, title, role)
   select id, email, 'ชื่อ นามสกุล', 'ตำแหน่ง', 'admin'
   from auth.users where lower(email) = lower('อีเมลที่สร้างไว้');
   ```
คนถัดไปให้ Admin เพิ่มในหน้า Admin (ไม่ต้องเข้า dashboard อีก)

## 4. ติดตั้ง Edge Function `v2-admin-users`
ฟังก์ชันนี้ถือ service_role ฝั่งเซิร์ฟเวอร์ ใช้สร้างบัญชี / สร้างลิงก์ตั้งรหัสผ่าน / ปิดบัญชี (เบราว์เซอร์ห้ามถือ service_role key)

ผ่าน dashboard: **Edge Functions → Deploy a new function** → ตั้งชื่อ `v2-admin-users` → วางโค้ดจาก [`functions/v2-admin-users/index.ts`](functions/v2-admin-users/index.ts) → Deploy
หรือผ่าน CLI: `supabase functions deploy v2-admin-users --project-ref <project-ref>`

แล้วตั้ง secret **Edge Functions → Secrets** : `SITE_URL` = `https://chadapaffy.github.io/Budgeting/`
(`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` Supabase ใส่ให้ฟังก์ชันเอง ไม่ต้องตั้ง)

## 5. เชื่อมเว็บกับโปรเจกต์
**Project Settings → API** คัดลอก **anon public key** ใส่ที่ `js/config.js` ช่อง `supabaseAnonKey` (ค่านี้เปิดเผยในหน้าเว็บได้ — **ห้ามใส่ service_role key**) แล้วขึ้นเว็บตามขั้นตอนใน `CLAUDE.md`
พอมี anon key ระบบจะเปลี่ยนจากโหมดทดลองเป็นล็อกอินจริงอัตโนมัติ (บัญชีตัวอย่างและ `DEMO_QUICK_LOGIN` ไม่ใช้อีกต่อไป)

## ใช้งานจริง
| ต้องการ | ทำที่ |
|---|---|
| เพิ่มผู้ใช้ | Admin → ผู้ใช้ → + เพิ่มผู้ใช้ → ได้ลิงก์ → ส่งให้ผู้ใช้ → ผู้ใช้เปิดลิงก์ตั้งรหัสผ่านเอง |
| ผู้ใช้ลืมรหัสผ่าน | ผู้ใช้กด "ลืมรหัสผ่าน" (บัญชีขึ้น "ขอรีเซ็ตรหัสผ่าน" + ตัวเลขที่เมนู Admin) → Admin กด "รีเซ็ตรหัสผ่าน" ได้ลิงก์ใหม่ → ส่งให้ผู้ใช้ |
| ปิดบัญชี | Admin → ผู้ใช้ → ปิดใช้งาน (ล็อกอินไม่ได้ทันที ระบบกันไม่ให้ปิด Admin คนสุดท้าย) |
| แก้สิทธิ์ / สร้างบทบาท | Admin → บทบาทและสิทธิ์ |

## ความปลอดภัย (สิ่งที่ระบบทำให้ / สิ่งที่ต้องระวัง)
- ตาราง `v2_*` เปิด RLS และไม่มี policy — เบราว์เซอร์อ่าน/เขียนตารางตรงๆ ไม่ได้ ทุกอย่างผ่านฟังก์ชัน `v2_*` ที่ตรวจสิทธิ์ฝั่งฐานข้อมูล · รายชื่อผู้ใช้สำหรับเลือก/แท็กงาน (`v2_directory`) ไม่มีอีเมล
- Admin ไม่เห็นและไม่ตั้งรหัสผ่านให้ผู้ใช้ — ได้เพียงลิงก์ที่ผู้ใช้เปิดแล้วตั้งเอง · **ลิงก์คือกุญแจเข้าบัญชีนั้น** ส่งผ่านช่องทางที่เชื่อถือได้เท่านั้น
- อยู่ในเฟสนี้เท่านั้น: **Log การทำงานและข้อมูลหลักยังเก็บในเบราว์เซอร์** (ยังไม่ใช่ audit log กลาง) · ขอบเขตบริษัท (`companies`) ฝั่งฐานข้อมูลยังไม่ถูกบังคับด้วย RLS เพราะยังไม่มีข้อมูลงบบนฐานข้อมูล — จะทำในเฟส 2

## ทดสอบฐานข้อมูล (ไม่จำเป็นสำหรับผู้ใช้)
ดู `tests/v2_test.sql` — รันกับ Postgres ในเครื่องพร้อม `tests/shim.sql`:
```bash
psql -v ON_ERROR_STOP=1 -d sp -f tests/shim.sql -f schema_v2.sql -f tests/v2_test.sql
```
