-- 22.2 · 11_audit: audit_logs append-only
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(4);

SELECT has_trigger('public', 'audit_logs', 'trg_audit_immutable', 'trigger immutability terpasang');

UPDATE app_settings SET value = '31' WHERE key = 'bbs_weekly_target';
SELECT ok((SELECT count(*) FROM audit_logs) > 0, 'mutasi tabel teraudit menghasilkan baris audit');

SELECT throws_ok($$UPDATE audit_logs SET action = action WHERE id = (SELECT max(id) FROM audit_logs)$$, NULL, NULL,
                 'UPDATE audit_logs ditolak');
SELECT throws_ok($$DELETE FROM audit_logs WHERE id = (SELECT max(id) FROM audit_logs)$$, NULL, NULL,
                 'DELETE audit_logs ditolak');

SELECT * FROM finish();
ROLLBACK;
