-- 22.2 · 12_links_resolve: setiap literal '/...' di fungsi public adalah route/fragmen yang dikenal klien (18.3)
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(1);

SELECT is(
  (SELECT string_agg(DISTINCT m[1], ', ')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace,
          regexp_matches(p.prosrc, '''(/[^'']*)''', 'g') AS m
    WHERE n.nspname = 'public'
      AND m[1] NOT IN ('/', '/dashboard', '/tasks', '/tasks/', '/contracts/', '/onedrive', '/meetings/', '/vendors/',
                       '/my-company', '/pending', '/register', '/incidents/', '/chat', '/chat/', '/settings/devices',
                       '/invite?email=', '/admin/approvals', '/admin/onedrive-links', '/admin/security', '/admin/audit')),
  NULL, 'tidak ada tautan server yang mengarah ke route tak dikenal');

SELECT * FROM finish();
ROLLBACK;
