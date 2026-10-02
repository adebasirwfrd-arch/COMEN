-- 22.2 · 13_seed: seed produksi konsisten
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(9);

SELECT is((SELECT count(*)::INT FROM roles WHERE is_system), 10, '10 role sistem');
SELECT ok((SELECT count(*) FROM permissions) >= 60, 'katalog permission lengkap');
SELECT is((SELECT count(*)::INT FROM doc_type_catalog), 50, '50 kode dokumen (49 v3.2 + VISACK v3.3)');
SELECT ok((SELECT count(*) FROM doc_type_catalog WHERE is_mob_gate) >= 13, 'minimal 13 dokumen gate mobilisasi');
SELECT is((SELECT sum(w.value::INT)::INT FROM app_settings s, jsonb_each_text(s.value) AS w WHERE s.key = 'kpi_weights'),
          100, 'bobot KPI = 100');
SELECT is((SELECT string_agg(s.key, ', ') FROM app_settings s
            WHERE s.required_permission IS NOT NULL AND NOT EXISTS (SELECT 1 FROM permissions p WHERE p.key = s.required_permission)),
          NULL, 'semua required_permission setting ada di permissions');
SELECT is((SELECT string_agg(proname, ', ') FROM (
            SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' GROUP BY p.proname HAVING count(*) > 1) x),
          NULL, 'tidak ada overload fungsi');
SELECT ok(EXISTS (SELECT 1 FROM admin_allowlist WHERE email = 'ade.basirwfrd@gmail.com'), 'root admin di allowlist');
SELECT is((SELECT value::TEXT FROM app_settings WHERE key = 'read_only_mode'), 'false', 'read-only mode mati secara default');

SELECT * FROM finish();
ROLLBACK;
