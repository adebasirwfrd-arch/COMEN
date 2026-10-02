-- 22.2 · 02_device_session: tanpa header x-device-id → missing; perangkat belum terdaftar → unregistered
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(5);

SELECT is(device_state(), 'anonymous', 'tanpa JWT → anonymous');

SELECT set_config('request.jwt.claims',
  json_build_object('sub', '11111111-1111-4111-8111-111111111111', 'role', 'authenticated', 'aal', 'aal1',
                    'amr', json_build_array(json_build_object('method', 'oauth', 'timestamp', extract(epoch FROM now())::INT)))::TEXT,
  TRUE);

SELECT is(device_state(), 'missing', 'JWT tanpa header x-device-id → missing');

SELECT set_config('request.headers', json_build_object('x-device-id', 'bukan-hash')::TEXT, TRUE);
SELECT is(device_state(), 'missing', 'header bukan SHA-256 hex → missing');

SELECT set_config('request.headers', json_build_object('x-device-id', repeat('a', 64))::TEXT, TRUE);
SELECT is(device_state(), 'unregistered', 'hash valid tetapi belum terdaftar → unregistered');

SELECT ok(NOT rls_ok(), 'rls_ok() false untuk perangkat yang belum terdaftar');

SELECT * FROM finish();
ROLLBACK;
