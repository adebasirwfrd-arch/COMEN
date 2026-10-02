-- 20260103000005 · Pemulihan MFA lewat kode email (R48)
-- User yang kehilangan authenticator (aal1, punya faktor TOTP terverifikasi) meminta kode 6 digit ke email akunnya.
-- Kode dibuat & diverifikasi di DB, tetapi RPC hanya bisa dipanggil Edge `mfa-recovery` (attestasi HMAC edge_attest_secret)
-- → kode tidak pernah sampai ke browser. Kode benar → Edge menghapus semua faktor TOTP + mencabut sesi lain,
-- lalu gate mengarahkan user ke /mfa/enroll (scan QR baru) sebelum bisa memakai aplikasi.

INSERT INTO app_settings (key, value, is_public, required_permission, description) VALUES
  ('mfa_email_recovery_enabled', 'true', FALSE, 'admin.security.manage',
   'User yang kehilangan authenticator bisa mereset MFA dengan kode sekali pakai ke email akun, lalu wajib scan QR baru')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS mfa_recovery_codes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  code_hash   TEXT NOT NULL CHECK (code_hash ~ '^[a-f0-9]{64}$'),
  attempts    SMALLINT NOT NULL DEFAULT 0,
  device_hash TEXT,
  ip_hmac     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL,
  used_at     TIMESTAMPTZ,
  revoked_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_mfa_recovery_codes_user ON mfa_recovery_codes(user_id, created_at DESC);
ALTER TABLE mfa_recovery_codes ENABLE ROW LEVEL SECURITY;
-- Tanpa policy & tanpa GRANT: hanya fungsi SECURITY DEFINER di bawah yang menyentuh tabel ini

CREATE OR REPLACE FUNCTION _mfa_recovery_hash(p_id UUID, p_code TEXT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT encode(hmac(p_id::TEXT || '|' || p_code, _secret('confirm_code_secret'), 'sha256'), 'hex')
$$;

-- Syarat bersama: sesi valid di perangkat terdaftar, masih aal1, dan memang punya authenticator terverifikasi
CREATE OR REPLACE FUNCTION _mfa_recovery_subject() RETURNS profiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_p profiles; v_ds TEXT;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  IF NOT _setting_bool('mfa_email_recovery_enabled', TRUE) THEN
    PERFORM _deny('forbidden', 'Pemulihan lewat email dinonaktifkan Admin. Hubungi Admin COMEN untuk reset MFA.');
  END IF;
  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  IF NOT FOUND OR v_p.status NOT IN ('active','pending') OR v_p.anonymized_at IS NOT NULL THEN
    PERFORM _deny('account_inactive', 'Akun tidak aktif');
  END IF;
  IF auth_aal() = 'aal2' THEN
    RAISE EXCEPTION 'Sesi Anda sudah terverifikasi MFA. Kelola authenticator di Pengaturan → Keamanan.' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = v_uid AND f.status = 'verified' AND f.factor_type = 'totp') THEN
    RAISE EXCEPTION 'Tidak ada authenticator terdaftar. Muat ulang halaman untuk mendaftarkan yang baru.' USING ERRCODE = '22023';
  END IF;
  RETURN v_p;
END $$;

-- Dipanggil Edge (attestasi) atas nama user. Mengembalikan kode polos HANYA ke Edge untuk dikirim via email.
CREATE OR REPLACE FUNCTION mfa_recovery_request() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_p profiles; v_email TEXT; v_last TIMESTAMPTZ; v_code TEXT; v_id UUID := gen_random_uuid();
        v_ttl INT := 10; v_wait INT;
BEGIN
  PERFORM _assert_attestation('mfa_recovery_request');
  v_p := _mfa_recovery_subject();
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_p.id AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Email akun belum terverifikasi. Hubungi Admin COMEN untuk reset MFA.' USING ERRCODE = '22023';
  END IF;

  SELECT max(created_at) INTO v_last FROM mfa_recovery_codes WHERE user_id = v_p.id AND used_at IS NULL AND revoked_at IS NULL;
  v_wait := CASE WHEN v_last IS NULL THEN 0 ELSE CEIL(60 - EXTRACT(EPOCH FROM (NOW() - v_last)))::INT END;
  IF v_wait > 0 THEN
    RAISE EXCEPTION 'Kode baru saja dikirim. Tunggu % detik sebelum meminta lagi.', v_wait USING ERRCODE = '22023';
  END IF;
  PERFORM hit_rate_limit('mfa_recovery_req:' || v_p.id, 5, INTERVAL '1 hour');
  PERFORM hit_rate_limit('mfa_recovery_req_day:' || v_p.id, 10, INTERVAL '1 day');

  DELETE FROM mfa_recovery_codes WHERE created_at < NOW() - INTERVAL '30 days';
  UPDATE mfa_recovery_codes SET revoked_at = NOW() WHERE user_id = v_p.id AND used_at IS NULL AND revoked_at IS NULL;
  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::BIT(32)::BIGINT) % 1000000)::TEXT, 6, '0');
  INSERT INTO mfa_recovery_codes (id, user_id, code_hash, device_hash, ip_hmac, expires_at)
  VALUES (v_id, v_p.id, _mfa_recovery_hash(v_id, v_code), request_device_hash(), request_ip_hmac(),
          NOW() + make_interval(mins => v_ttl));

  PERFORM _security_event(v_p.id, 'mfa_recovery_requested', 'warning', jsonb_build_object('request', v_id));
  RETURN jsonb_build_object(
    'code', v_code, 'email', v_email, 'full_name', v_p.full_name, 'expires_minutes', v_ttl,
    'device_label', (SELECT label FROM trusted_devices WHERE user_id = v_p.id AND device_hash = request_device_hash()));
END $$;

-- Kode salah TIDAK me-RAISE (agar hitungan percobaan ter-commit) → {ok:false, reason, remaining}
CREATE OR REPLACE FUNCTION mfa_recovery_verify(p_code TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_p profiles; v_r mfa_recovery_codes; v_max INT := 5; v_n INT; v_email TEXT;
BEGIN
  PERFORM _assert_attestation('mfa_recovery_verify');
  v_p := _mfa_recovery_subject();
  IF p_code IS NULL OR p_code !~ '^\d{6}$' THEN RAISE EXCEPTION 'Kode harus 6 digit' USING ERRCODE = '22023'; END IF;
  PERFORM hit_rate_limit('mfa_recovery_verify:' || v_p.id, 20, INTERVAL '1 hour');

  SELECT * INTO v_r FROM mfa_recovery_codes
  WHERE user_id = v_p.id AND used_at IS NULL AND revoked_at IS NULL
  ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_r.expires_at <= NOW() THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'expired', 'remaining', 0);
  END IF;

  IF v_r.code_hash <> _mfa_recovery_hash(v_r.id, p_code) THEN
    v_n := v_r.attempts + 1;
    UPDATE mfa_recovery_codes SET attempts = v_n, revoked_at = CASE WHEN v_n >= v_max THEN NOW() END WHERE id = v_r.id;
    PERFORM _security_event(v_p.id, 'mfa_recovery_failed', 'warning', jsonb_build_object('request', v_r.id, 'attempts', v_n));
    RETURN jsonb_build_object('ok', FALSE, 'reason', CASE WHEN v_n >= v_max THEN 'locked' ELSE 'invalid' END,
                              'remaining', GREATEST(v_max - v_n, 0));
  END IF;

  PERFORM hit_rate_limit('mfa_recovery_reset:' || v_p.id, 3, INTERVAL '7 days');
  UPDATE mfa_recovery_codes SET used_at = NOW() WHERE id = v_r.id;
  SELECT email INTO v_email FROM auth.users WHERE id = v_p.id;

  PERFORM _security_event(v_p.id, 'mfa_recovery_reset', 'critical', jsonb_build_object('request', v_r.id, 'via', 'email_code'));
  PERFORM _notify(v_p.id, 'security_mfa_reset', 'Authenticator Anda direset',
                  'MFA direset lewat kode email. Daftarkan authenticator baru. Bila bukan Anda yang melakukannya, segera hubungi Admin COMEN.',
                  '/settings/security', 'warning', NULL, '{}'::jsonb, 'mfarec:' || v_r.id || ':' || v_p.id);
  PERFORM _notify_permission_holders('admin.security.manage', NULL, 'security_mfa_reset', 'MFA user direset via email',
                                     COALESCE(v_p.full_name, '-') || ' · ' || v_email, '/admin/security', 'warning', NULL,
                                     '{}'::jsonb, 'mfarec:' || v_r.id);
  RETURN jsonb_build_object('ok', TRUE, 'email', v_email, 'full_name', v_p.full_name);
END $$;

REVOKE ALL ON TABLE mfa_recovery_codes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _mfa_recovery_hash(UUID, TEXT) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION _mfa_recovery_subject() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION mfa_recovery_request() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION mfa_recovery_request() TO authenticated;
REVOKE ALL ON FUNCTION mfa_recovery_verify(TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION mfa_recovery_verify(TEXT) TO authenticated;
