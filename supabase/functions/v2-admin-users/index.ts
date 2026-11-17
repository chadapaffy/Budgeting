// Edge Function: จัดการบัญชีผู้ใช้ที่ต้องใช้สิทธิ์ service_role (เบราว์เซอร์ทำเองไม่ได้ และห้ามมี service_role key ในเบราว์เซอร์)
//   POST { action: 'create', email, name, title, department, company, companies, role } → { user, link }
//   POST { action: 'reset', id }                       → { link }   (ลิงก์ให้ผู้ใช้ตั้งรหัสผ่านใหม่เอง)
//   POST { action: 'set_active', id, active }          → { user }   (ปิดบัญชี = ban ใน Supabase Auth ด้วย)
// ทุกการเรียกต้องแนบ Authorization: Bearer <access token ของผู้ใช้> และผู้เรียกต้อง active + มีสิทธิ์ user.manage
// Admin ไม่เห็น / ไม่ตั้งรหัสผ่านให้ใคร — ได้เพียงลิงก์ (recovery) ที่ผู้ใช้เปิดแล้วตั้งรหัสผ่านเอง
//
// Secrets ที่ใช้ (Supabase ใส่ SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY ให้เองในฟังก์ชัน):
//   SITE_URL = https://chadapaffy.github.io/Budgeting/   (หน้าที่ลิงก์จะพาไปหลังกด)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE_URL = Deno.env.get('SITE_URL') || '';

const BAN_FOREVER = '876000h';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const fail = (message: string, status = 400) => json({ message }, status);

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const str = (v: unknown) => String(v ?? '').trim();
const validEmail = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

type Profile = {
  id: string; email: string; name: string; title: string; department: string; company: string;
  companies: string[]; role: string; active: boolean; created_at: string; last_login_at: string | null;
  reset_requested_at: string | null; reset_at: string | null;
};

const userJson = (p: Profile) => ({
  id: p.id, email: p.email, name: p.name, title: p.title, department: p.department, company: p.company,
  companies: p.companies, role: p.role, active: p.active, createdAt: p.created_at, lastLoginAt: p.last_login_at,
  resetRequestedAt: p.reset_requested_at, resetAt: p.reset_at,
});

/** ผู้เรียกต้องล็อกอิน (token ถูกต้อง) + active + บทบาทมีสิทธิ์ user.manage */
async function caller(req: Request): Promise<Profile | null> {
  const auth = req.headers.get('Authorization') || '';
  if (!auth.startsWith('Bearer ')) return null;
  const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) return null;
  const { data: p } = await admin.from('v2_profiles').select('*').eq('id', data.user.id).maybeSingle();
  if (!p || !p.active) return null;
  const { data: r } = await admin.from('v2_roles').select('permissions').eq('key', p.role).maybeSingle();
  if (!r || !(r.permissions as string[]).includes('user.manage')) return null;
  return p as Profile;
}

async function recoveryLink(email: string): Promise<string> {
  const { data, error } = await admin.auth.admin.generateLink({
    type: 'recovery', email, options: SITE_URL ? { redirectTo: SITE_URL } : undefined,
  });
  if (error || !data?.properties?.action_link) throw new Error('สร้างลิงก์ไม่สำเร็จ: ' + (error?.message || 'ไม่ทราบสาเหตุ'));
  return data.properties.action_link;
}

async function activeManagers(except: string): Promise<number> {
  const { data: roles } = await admin.from('v2_roles').select('key, permissions');
  const keys = (roles || []).filter((r) => (r.permissions as string[]).includes('user.manage')).map((r) => r.key);
  const { data } = await admin.from('v2_profiles').select('id').eq('active', true).neq('id', except).in('role', keys);
  return (data || []).length;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('method not allowed', 405);
  const me = await caller(req);
  if (!me) return fail('ไม่มีสิทธิ์จัดการผู้ใช้', 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('ข้อมูลไม่ถูกต้อง'); }

  try {
    if (body.action === 'create') {
      const email = str(body.email).toLowerCase();
      const name = str(body.name);
      const role = str(body.role);
      if (!validEmail(email)) return fail('รูปแบบอีเมลไม่ถูกต้อง');
      if (!name) return fail('กรุณาระบุชื่อ');
      const { data: r } = await admin.from('v2_roles').select('key').eq('key', role).maybeSingle();
      if (!r) return fail('ไม่พบบทบาท');
      const { data: dup } = await admin.from('v2_profiles').select('id').ilike('email', email).maybeSingle();
      if (dup) return fail('อีเมลนี้มีอยู่ในระบบแล้ว');
      const company = str(body.company);
      const companies = Array.isArray(body.companies) ? [...new Set((body.companies as unknown[]).map(str).filter(Boolean))] : (company ? [company] : []);

      // สร้างบัญชีโดยไม่มีรหัสผ่าน — ผู้ใช้ตั้งเองผ่านลิงก์
      const created = await admin.auth.admin.createUser({ email, email_confirm: true });
      if (created.error || !created.data.user) return fail('สร้างบัญชีไม่สำเร็จ: ' + (created.error?.message || ''), 400);
      const id = created.data.user.id;
      const { data: p, error: pe } = await admin.from('v2_profiles').insert({
        id, email, name, title: str(body.title), department: str(body.department), company, companies, role, created_by: me.id,
      }).select('*').single();
      if (pe || !p) {
        await admin.auth.admin.deleteUser(id); // ไม่ให้เหลือบัญชีที่ไม่มีโปรไฟล์
        return fail('บันทึกโปรไฟล์ไม่สำเร็จ: ' + (pe?.message || ''), 400);
      }
      const link = await recoveryLink(email);
      return json({ user: userJson(p as Profile), link });
    }

    if (body.action === 'reset') {
      const { data: p } = await admin.from('v2_profiles').select('*').eq('id', str(body.id)).maybeSingle();
      if (!p) return fail('ไม่พบบัญชี');
      if (!p.active) return fail('บัญชีนี้ถูกปิดการใช้งาน');
      const link = await recoveryLink(p.email);
      await admin.from('v2_profiles').update({ reset_at: new Date().toISOString(), reset_requested_at: null }).eq('id', p.id);
      return json({ link });
    }

    if (body.action === 'set_active') {
      const id = str(body.id);
      const active = body.active === true;
      const { data: p } = await admin.from('v2_profiles').select('*').eq('id', id).maybeSingle();
      if (!p) return fail('ไม่พบบัญชี');
      if (!active) {
        if (id === me.id) return fail('ปิดบัญชีของตัวเองไม่ได้');
        const { data: r } = await admin.from('v2_roles').select('permissions').eq('key', p.role).maybeSingle();
        if (p.active && r && (r.permissions as string[]).includes('user.manage') && (await activeManagers(id)) === 0) {
          return fail('ต้องมีผู้ดูแลระบบที่เปิดใช้งานอย่างน้อย 1 คน');
        }
      }
      const { error: be } = await admin.auth.admin.updateUserById(id, { ban_duration: active ? 'none' : BAN_FOREVER });
      if (be) return fail('ปรับสถานะบัญชีไม่สำเร็จ: ' + be.message);
      const { data: up } = await admin.from('v2_profiles').update({ active }).eq('id', id).select('*').single();
      return json({ user: userJson(up as Profile) });
    }

    return fail('ไม่รู้จักคำสั่ง');
  } catch (e) {
    return fail((e as Error).message || 'เกิดข้อผิดพลาด', 500);
  }
});
