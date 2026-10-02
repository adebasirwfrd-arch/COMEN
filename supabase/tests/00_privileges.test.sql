-- 22.2 · 00_privileges: default deny untuk anon & authenticated
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(11);

SELECT is(
  (SELECT count(*)::INT FROM information_schema.role_table_grants WHERE grantee = 'anon' AND table_schema = 'public'),
  0, 'anon tidak punya privilege tabel/view apa pun');

SELECT is(
  (SELECT count(*)::INT FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
  0, 'anon tidak bisa EXECUTE fungsi public');

SELECT is(
  (SELECT count(*)::INT FROM information_schema.role_table_grants
    WHERE grantee = 'authenticated' AND table_schema = 'public'
      AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')),
  0, 'authenticated tanpa INSERT/UPDATE/DELETE di tabel mana pun');

SELECT is(
  (SELECT count(*)::INT FROM information_schema.column_privileges
    WHERE grantee = 'authenticated' AND table_schema = 'public' AND privilege_type <> 'SELECT'),
  0, 'authenticated tanpa privilege tulis level kolom');

SELECT ok(NOT has_column_privilege('authenticated', 'public.tasks', 'confirm_code', 'SELECT'), 'tasks.confirm_code tidak ter-GRANT');
SELECT ok(NOT has_column_privilege('authenticated', 'public.trusted_devices', 'device_hash', 'SELECT'), 'trusted_devices.device_hash tidak ter-GRANT');
SELECT ok(NOT has_column_privilege('authenticated', 'public.trusted_devices', 'last_ip_hmac', 'SELECT'), 'trusted_devices.last_ip_hmac tidak ter-GRANT');
SELECT ok(NOT has_column_privilege('authenticated', 'public.profiles', 'phone_enc', 'SELECT'), 'profiles.phone_enc tidak ter-GRANT');
SELECT ok(has_column_privilege('authenticated', 'public.tasks', 'task_id', 'SELECT'), 'tasks.task_id ter-GRANT (kontrol positif)');

SELECT is(
  (SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND (p.proname LIKE 'svc\_%' OR (p.proname LIKE '\_%' AND p.proname <> '_topic_channel'))
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  NULL, 'fungsi _xxx / svc_xxx tidak executable oleh authenticated');

SELECT ok(
  (SELECT bool_and(c.relrowsecurity) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relispartition),
  'RLS aktif di semua tabel public');

SELECT * FROM finish();
ROLLBACK;
