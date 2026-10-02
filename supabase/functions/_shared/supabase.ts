// _shared/supabase.ts
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { env } from './env.ts';
import { bearer, HttpError } from './http.ts';

const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

export const serviceClient = (): SupabaseClient =>
  createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), opts);

// Meneruskan identitas user + perangkat + IP → assert_access/device_state di DB berlaku penuh
export function userClient(req: Request, extra: Record<string, string> = {}): SupabaseClient {
  const headers: Record<string, string> = { Authorization: `Bearer ${bearer(req)}`, ...extra };
  const dev = req.headers.get('x-device-id');
  if (dev && /^[a-f0-9]{64}$/.test(dev)) headers['x-device-id'] = dev;
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim();
  if (ip) headers['x-forwarded-for'] = ip;
  return createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), { ...opts, global: { headers } });
}

export async function requireUser(req: Request): Promise<{ id: string; email: string }> {
  const token = bearer(req);
  if (!token) throw new HttpError(401, 'unauthenticated', 'unauthenticated');
  const { data, error } = await serviceClient().auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, 'unauthenticated', 'unauthenticated');
  return { id: data.user.id, email: data.user.email ?? '' };
}
