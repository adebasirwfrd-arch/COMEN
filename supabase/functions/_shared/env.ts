// _shared/env.ts
export function env(key: string, required = true): string {
  const v = Deno.env.get(key) ?? '';
  if (required && !v) throw new Error(`Missing env ${key}`);
  return v;
}
export const isProd = () => ['production', 'staging'].includes(Deno.env.get('COMEN_ENV') ?? '');
