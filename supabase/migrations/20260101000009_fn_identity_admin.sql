-- ═════════════ ONBOARDING ═════════════
CREATE OR REPLACE FUNCTION _is_allowlisted_google(p_uid UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.identities i
    JOIN admin_allowlist a ON a.email = lower(i.identity_data ->> 'email')
    JOIN profiles p ON p.id = i.user_id AND p.email = a.email
    WHERE i.user_id = p_uid AND i.provider = 'google'
      AND COALESCE((i.identity_data ->> 'email_verified')::BOOLEAN, FALSE))
$$;

CREATE OR REPLACE FUNCTION _validate_scope(p_type TEXT, p_id TEXT) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF p_type = 'global' THEN
    IF p_id IS NOT NULL THEN RAISE EXCEPTION 'Scope global tidak memakai target' USING ERRCODE = '22023'; END IF;
  ELSIF p_type = 'geozone' THEN
    IF NOT EXISTS (SELECT 1 FROM geozones WHERE code = p_id AND active) THEN RAISE EXCEPTION 'Geozone tidak valid' USING ERRCODE = '22023'; END IF;
  ELSIF p_type IN ('contract','contractor') THEN
    IF p_id IS NULL OR p_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'Target scope tidak valid' USING ERRCODE = '22023';
    END IF;
    IF p_type = 'contract' AND NOT EXISTS (SELECT 1 FROM contracts WHERE id = p_id::UUID) THEN
      RAISE EXCEPTION 'Kontrak tidak ditemukan' USING ERRCODE = '22023'; END IF;
    IF p_type = 'contractor' AND NOT EXISTS (SELECT 1 FROM contractors WHERE id = p_id::UUID) THEN
      RAISE EXCEPTION 'Contractor tidak ditemukan' USING ERRCODE = '22023'; END IF;
  ELSE
    RAISE EXCEPTION 'Tipe scope tidak valid' USING ERRCODE = '22023';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION _grant_role_internal(p_user UUID, p_role UUID, p_scope_type TEXT, p_scope_id TEXT,
  p_expires TIMESTAMPTZ, p_reason TEXT, p_by UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id UUID;
BEGIN
  IF p_expires IS NOT NULL AND p_expires <= NOW() THEN RAISE EXCEPTION 'Tanggal berakhir harus di masa depan' USING ERRCODE = '22023'; END IF;
  INSERT INTO user_roles (user_id, role_id, scope_type, scope_id, expires_at, reason, granted_by)
  VALUES (p_user, p_role, p_scope_type, p_scope_id, p_expires, p_reason, p_by)
  ON CONFLICT (user_id, role_id, scope_type, scope_key)
  DO UPDATE SET expires_at = EXCLUDED.expires_at, reason = EXCLUDED.reason, granted_by = EXCLUDED.granted_by, granted_at = NOW()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Dipanggil setelah akun aktif / contractor berubah: task vendor dibuat jika registrasi sudah submitted
CREATE OR REPLACE FUNCTION _after_activation(p_user UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_c UUID;
BEGIN
  SELECT c.id INTO v_c FROM profiles p JOIN contractors c ON c.id = p.contractor_id
  WHERE p.id = p_user AND p.status = 'active' AND c.submitted_at IS NOT NULL;
  IF v_c IS NOT NULL THEN PERFORM generate_vendor_tasks(v_c); END IF;
END $$;

CREATE OR REPLACE FUNCTION _onboard_user(p_uid UUID, p_signup_provider TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_p profiles; v_confirmed BOOLEAN; v_inv user_invites; v_role roles;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND OR v_p.anonymized_at IS NOT NULL THEN RETURN; END IF;
  SELECT email_confirmed_at IS NOT NULL INTO v_confirmed FROM auth.users WHERE id = p_uid;

  -- (A) Root admin: email allowlist + identitas Google terverifikasi
  IF EXISTS (SELECT 1 FROM admin_allowlist WHERE email = v_p.email)
     AND (_is_allowlisted_google(p_uid) OR (p_signup_provider = 'google' AND v_confirmed)) THEN
    DELETE FROM user_roles ur USING roles r WHERE ur.role_id = r.id AND ur.user_id = p_uid AND NOT r.is_wfrd;
    IF NOT v_p.is_root_admin OR v_p.status <> 'active' OR v_p.contractor_id IS NOT NULL THEN
      UPDATE profiles SET is_root_admin = TRUE, status = 'active', contractor_id = NULL, status_reason = NULL,
                          approved_at = COALESCE(approved_at, NOW())
      WHERE id = p_uid;
      PERFORM _security_event(p_uid, 'root_admin_activated', 'warning', jsonb_build_object('email', v_p.email));
    END IF;
    PERFORM _grant_role_internal(p_uid, (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL,
                                 'Root admin (admin_allowlist)', NULL);
    RETURN;
  END IF;

  IF v_p.status <> 'pending' OR NOT v_confirmed THEN RETURN; END IF;

  -- (B) Undangan aktif untuk email terverifikasi
  SELECT * INTO v_inv FROM user_invites
  WHERE email = v_p.email AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > NOW()
  FOR UPDATE;
  IF FOUND THEN
    SELECT * INTO v_role FROM roles WHERE id = v_inv.role_id;
    UPDATE profiles SET status = 'active', status_reason = NULL,
                        contractor_id = CASE WHEN v_role.is_wfrd THEN NULL ELSE v_inv.contractor_id END,
                        approved_by = v_inv.invited_by, approved_at = NOW()
    WHERE id = p_uid;
    PERFORM _grant_role_internal(p_uid, v_inv.role_id, v_inv.scope_type, v_inv.scope_id, v_inv.role_expires_at,
                                 'Undangan ' || v_inv.id, v_inv.invited_by);
    UPDATE user_invites SET accepted_at = NOW(), accepted_by = p_uid WHERE id = v_inv.id;
    PERFORM _security_event(p_uid, 'user_status', 'info', jsonb_build_object('status', 'active', 'via', 'invite', 'invite', v_inv.id));
    PERFORM _notify(p_uid, 'account_approved', 'Akun Anda aktif', 'Selamat datang di COMEN.', '/', 'info', 7003,
                    jsonb_build_object('name', v_p.full_name), 'approved:' || p_uid);
    PERFORM _after_activation(p_uid);
    RETURN;
  END IF;

  -- (C) Pending → antrian approval (sekali)
  IF NOT EXISTS (SELECT 1 FROM security_events WHERE user_id = p_uid AND event = 'new_pending_user') THEN
    PERFORM _security_event(p_uid, 'new_pending_user', 'info',
                            jsonb_build_object('email', v_p.email, 'provider', p_signup_provider));
    PERFORM _notify_permission_holders('admin.users.approve', NULL, 'user_pending', 'User baru menunggu persetujuan',
                                       v_p.email, '/admin/approvals', 'info', 7001,
                                       jsonb_build_object('email', v_p.email, 'name', v_p.full_name), 'pending:' || p_uid);
  END IF;
END $$;

-- Trigger auth.users (dipasang di 14.14)
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_name TEXT; v_avatar TEXT;
BEGIN
  IF NEW.email IS NULL THEN RETURN NEW; END IF;
  v_name := left(btrim(regexp_replace(COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.raw_user_meta_data ->> 'name', ''),
                                      '[\x01-\x1F\x7F]', '', 'g')), 120);
  IF v_name = '' THEN v_name := split_part(NEW.email, '@', 1); END IF;
  v_avatar := NEW.raw_user_meta_data ->> 'avatar_url';
  IF v_avatar !~ '^https://' THEN v_avatar := NULL; END IF;

  INSERT INTO profiles (id, email, full_name, avatar_url) VALUES (NEW.id, lower(NEW.email), v_name, v_avatar)
  ON CONFLICT (id) DO NOTHING;
  BEGIN
    PERFORM _onboard_user(NEW.id, NEW.raw_app_meta_data ->> 'provider');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO security_events (user_id, event, severity, detail)
    VALUES (NEW.id, 'onboarding_error', 'warning', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
  END;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION handle_user_confirmed() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  BEGIN
    PERFORM _onboard_user(NEW.id, NULL);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO security_events (user_id, event, severity, detail)
    VALUES (NEW.id, 'onboarding_error', 'warning', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
  END;
  RETURN NEW;
END $$;

-- ═════════════ PERANGKAT & SESI ═════════════
CREATE OR REPLACE FUNCTION register_device(p_device_hash TEXT, p_label TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := auth.uid(); v_p profiles; v_dev trusted_devices; v_new BOOLEAN := FALSE;
  v_label TEXT := _clean_text(p_label, 80); v_sid UUID := NULLIF(auth.jwt() ->> 'session_id', '')::UUID; v_sev TEXT;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  IF p_device_hash IS NULL OR p_device_hash !~ '^[a-f0-9]{64}$' OR p_device_hash IS DISTINCT FROM request_device_hash() THEN
    PERFORM _deny('device_mismatch', 'Identitas perangkat tidak cocok');
  END IF;
  PERFORM hit_rate_limit('register_device:' || v_uid, 30, INTERVAL '1 hour');

  PERFORM _onboard_user(v_uid, NULL);
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  IF v_p.status NOT IN ('pending','active') THEN
    RETURN jsonb_build_object('new_device', FALSE, 'status', v_p.status);
  END IF;

  IF NOT _setting_bool('email_otp_enabled', TRUE) AND NOT v_p.is_root_admin AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) e
       WHERE e ->> 'method' IN ('otp','magiclink')) THEN
    PERFORM _deny('login_method_disabled', 'Login via email OTP sedang dinonaktifkan Admin');
  END IF;
  -- Provider email Supabase selalu menerima password via API → ditolak kecuali diizinkan (hanya lokal/mock, 14.19)
  IF NOT _setting_bool('password_login_enabled', FALSE) AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) e WHERE e ->> 'method' = 'password') THEN
    PERFORM _deny('login_method_disabled', 'Login dengan password tidak diizinkan');
  END IF;

  SELECT * INTO v_dev FROM trusted_devices WHERE user_id = v_uid AND device_hash = p_device_hash FOR UPDATE;
  IF FOUND THEN
    IF v_dev.revoked_at IS NOT NULL THEN
      -- RETURN (bukan RAISE) agar security event ter-commit; klien membaca device_state
      PERFORM _security_event(v_uid, 'revoked_device_attempt', 'warning', jsonb_build_object('device', v_dev.id));
      RETURN jsonb_build_object('new_device', FALSE, 'status', v_p.status, 'device_state', 'revoked');
    END IF;
    IF v_dev.last_session_id IS DISTINCT FROM v_sid THEN
      PERFORM _security_event(v_uid, 'login', 'info', jsonb_build_object('device', v_dev.id));
    END IF;
    UPDATE trusted_devices SET last_seen = NOW(), last_ip_hmac = request_ip_hmac(), last_session_id = v_sid,
                               label = COALESCE(label, v_label)
    WHERE id = v_dev.id;
  ELSE
    -- Perangkat baru hanya dari login segar: refresh token curian (auth_time lama) tidak bisa mendaftarkan perangkat baru
    IF COALESCE(jwt_auth_time(), '-infinity'::TIMESTAMPTZ) < NOW() - INTERVAL '15 minutes' THEN
      PERFORM _security_event(v_uid, 'stale_device_registration', 'warning', jsonb_build_object('label', v_label));
      RETURN jsonb_build_object('new_device', FALSE, 'status', v_p.status, 'device_state', 'reauth_required');
    END IF;
    INSERT INTO trusted_devices (user_id, device_hash, label, last_ip_hmac, last_session_id)
    VALUES (v_uid, p_device_hash, v_label, request_ip_hmac(), v_sid)
    RETURNING * INTO v_dev;
    v_new := TRUE;
    v_sev := CASE WHEN user_requires_mfa(v_uid) THEN 'critical' ELSE 'info' END;
    PERFORM _security_event(v_uid, 'new_device', v_sev, jsonb_build_object('device', v_dev.id, 'label', v_label));
    PERFORM _notify(v_uid, 'new_device', 'Login dari perangkat baru', COALESCE(v_label, 'Perangkat tidak dikenal'),
                    '/settings/devices', CASE WHEN v_sev = 'critical' THEN 'critical' ELSE 'warning' END, 7002,
                    jsonb_build_object('label', v_label, 'at', NOW()), 'newdev:' || v_dev.id);
  END IF;
  UPDATE profiles SET last_login_at = NOW() WHERE id = v_uid;
  RETURN jsonb_build_object('new_device', v_new, 'status', v_p.status, 'device_id', v_dev.id, 'device_state', device_state());
END $$;

CREATE OR REPLACE FUNCTION my_session_state() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_p profiles; v_c contractors; v_active BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  IF NOT FOUND THEN PERFORM _deny('account_inactive', 'Profil belum tersedia'); END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_p.contractor_id;
  v_active := v_p.status = 'active';
  RETURN jsonb_build_object(
    'user_id', v_p.id, 'email', v_p.email, 'full_name', v_p.full_name, 'avatar_url', v_p.avatar_url,
    'status', v_p.status, 'status_reason', v_p.status_reason, 'is_root_admin', v_p.is_root_admin,
    'is_wfrd', v_active AND v_p.contractor_id IS NULL,
    'contractor_id', v_p.contractor_id, 'contractor_name', v_c.legal_name, 'vendor_status', v_c.status,
    'registration_submitted', v_c.submitted_at IS NOT NULL, 'locale', v_p.locale,
    'roles', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', ur.id, 'key', r.key, 'name', r.name, 'scope_type', ur.scope_type,
                                            'scope_id', ur.scope_id, 'expires_at', ur.expires_at) ORDER BY r.key)
        FROM user_roles ur JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = v_uid AND (ur.expires_at IS NULL OR ur.expires_at > NOW())), '[]'::jsonb) ELSE '[]'::jsonb END,
    'permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key))), '[]'::jsonb) ELSE '[]'::jsonb END,
    'global_permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key) g WHERE g.scope_type = 'global')), '[]'::jsonb)
        ELSE '[]'::jsonb END,
    'mfa_required', user_requires_mfa(v_uid),
    'mfa_enrolled', EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = v_uid AND f.status = 'verified' AND f.factor_type = 'totp'),
    'aal', auth_aal(),
    'step_up_fresh', mfa_fresh(_setting_int('step_up_hours', 12)),
    'device_state', device_state(),
    'read_only_mode', _setting_bool('read_only_mode', FALSE),
    'email_otp_enabled', _setting_bool('email_otp_enabled', TRUE),
    'unread_notifications', (SELECT count(*) FROM notifications WHERE user_id = v_uid AND read_at IS NULL)
  );
END $$;

CREATE OR REPLACE FUNCTION revoke_my_device(p_device UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  UPDATE trusted_devices SET revoked_at = NOW(), revoked_by = v_uid, revoke_reason = 'Dicabut oleh pemilik'
  WHERE id = p_device AND user_id = v_uid AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Perangkat tidak ditemukan' USING ERRCODE = '22023'; END IF;
  DELETE FROM push_subscriptions WHERE device_id = p_device;
  PERFORM _security_event(v_uid, 'device_revoked', 'info', jsonb_build_object('device', p_device, 'by', 'self'));
END $$;

CREATE OR REPLACE FUNCTION rename_my_device(p_device UUID, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE);
BEGIN
  UPDATE trusted_devices SET label = _clean_text(p_label, 80, TRUE) WHERE id = p_device AND user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Perangkat tidak ditemukan' USING ERRCODE = '22023'; END IF;
END $$;

CREATE OR REPLACE FUNCTION update_my_profile(p_full_name TEXT, p_job_title TEXT, p_phone TEXT, p_locale TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE); v_ver SMALLINT := _active_key_ver('data');
BEGIN
  IF p_locale NOT IN ('id','en') THEN RAISE EXCEPTION 'Bahasa tidak didukung' USING ERRCODE = '22023'; END IF;
  IF p_phone IS NOT NULL AND p_phone !~ '^\+?[0-9 ()-]{6,20}$' THEN RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE profiles SET full_name = _clean_text(p_full_name, 120, TRUE), job_title = _clean_text(p_job_title, 120),
                      phone_enc = _encrypt(_clean_text(p_phone, 20), 'data', v_ver), enc_key_ver = v_ver,
                      locale = p_locale, updated_at = NOW()
  WHERE id = v_uid;
END $$;

CREATE OR REPLACE FUNCTION get_my_profile() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_p profiles;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  RETURN jsonb_build_object('full_name', v_p.full_name, 'email', v_p.email, 'job_title', v_p.job_title,
                            'phone', _decrypt(v_p.phone_enc, 'data', v_p.enc_key_ver), 'locale', v_p.locale,
                            'avatar_url', v_p.avatar_url);
END $$;

CREATE OR REPLACE FUNCTION mark_notifications_read(p_ids BIGINT[] DEFAULT NULL) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_n INT;
BEGIN
  UPDATE notifications SET read_at = NOW()
  WHERE user_id = v_uid AND read_at IS NULL AND (p_ids IS NULL OR id = ANY(p_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION save_push_subscription(p_endpoint TEXT, p_p256dh TEXT, p_auth TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE); v_dev UUID; v_ver SMALLINT := _active_key_ver('data');
BEGIN
  SELECT id INTO v_dev FROM trusted_devices WHERE user_id = v_uid AND device_hash = request_device_hash();
  IF p_endpoint !~ '^https://' OR length(p_endpoint) > 1000 OR p_p256dh !~ '^[A-Za-z0-9_-]{40,200}$' OR p_auth !~ '^[A-Za-z0-9_-]{10,100}$' THEN
    RAISE EXCEPTION 'Subscription tidak valid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO push_subscriptions (user_id, device_id, endpoint, p256dh, auth_secret_enc, enc_key_ver)
  VALUES (v_uid, v_dev, p_endpoint, p_p256dh, _encrypt(p_auth, 'data', v_ver), v_ver)
  ON CONFLICT (endpoint) DO UPDATE SET user_id = EXCLUDED.user_id, device_id = EXCLUDED.device_id, p256dh = EXCLUDED.p256dh,
                                        auth_secret_enc = EXCLUDED.auth_secret_enc, enc_key_ver = EXCLUDED.enc_key_ver;
END $$;

CREATE OR REPLACE FUNCTION delete_push_subscription(p_endpoint TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  DELETE FROM push_subscriptions WHERE endpoint = p_endpoint AND user_id = v_uid;
END $$;

-- ═════════════ SELF-SERVICE REGISTRASI (akun pending boleh) ═════════════
CREATE OR REPLACE FUNCTION _assert_self_service(p_write BOOLEAN DEFAULT TRUE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_p profiles; v_ds TEXT;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  IF v_p.status NOT IN ('pending','active') THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;
  IF v_p.status = 'active' AND v_p.contractor_id IS NULL THEN PERFORM _deny('forbidden', 'Hanya untuk akun contractor'); END IF;
  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;
  IF p_write AND _setting_bool('read_only_mode', FALSE) THEN PERFORM _deny('read_only', 'Sistem dalam mode read-only'); END IF;
  RETURN v_uid;
END $$;

-- Header x-comen-attest = "<unix_ts>.<hex HMAC-SHA256(edge_attest_secret, uid|purpose|ts)>", berlaku 120 detik, sekali pakai
CREATE OR REPLACE FUNCTION _assert_attestation(p_purpose TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_hdr TEXT := request_header('x-comen-attest'); v_ts BIGINT; v_sig TEXT;
BEGIN
  IF v_hdr IS NULL OR v_hdr !~ '^\d{10}\.[a-f0-9]{64}$' THEN PERFORM _deny('captcha_required', 'Verifikasi manusia diperlukan'); END IF;
  v_ts := split_part(v_hdr, '.', 1)::BIGINT;
  v_sig := split_part(v_hdr, '.', 2);
  IF abs(EXTRACT(EPOCH FROM NOW()) - v_ts) > 120 THEN PERFORM _deny('captcha_required', 'Verifikasi kedaluwarsa'); END IF;
  IF encode(hmac(auth.uid()::TEXT || '|' || p_purpose || '|' || v_ts, _secret('edge_attest_secret'), 'sha256'), 'hex') <> v_sig THEN
    PERFORM _deny('captcha_required', 'Verifikasi tidak valid');
  END IF;
  INSERT INTO rate_limits (key, window_start, hits, limit_value) VALUES ('attest:' || v_sig, to_timestamp(v_ts), 1, 1)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN PERFORM _deny('captcha_required', 'Verifikasi sudah dipakai'); END IF;
END $$;

CREATE OR REPLACE FUNCTION save_registration_draft(p_data JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := _assert_self_service(TRUE); v_cid UUID; v_c contractors; v_ver SMALLINT := _active_key_ver('data');
  v_country TEXT := upper(_clean_text(p_data ->> 'country', 2)); v_phone TEXT := _clean_text(p_data ->> 'primary_contact_phone', 20);
  v_pc_email TEXT := _clean_email(p_data ->> 'primary_contact_email', FALSE);
BEGIN
  PERFORM hit_rate_limit('reg_draft:' || v_uid, 120, INTERVAL '1 hour');
  IF jsonb_typeof(p_data) <> 'object' THEN RAISE EXCEPTION 'Data tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'Kode negara ISO-2 tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^\+?[0-9 ()-]{6,20}$' THEN RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_data ? 'website' AND NULLIF(p_data ->> 'website', '') IS NOT NULL AND p_data ->> 'website' !~* '^https?://' THEN
    RAISE EXCEPTION 'Website harus diawali http(s)://' USING ERRCODE = '22023'; END IF;

  SELECT contractor_id INTO v_cid FROM profiles WHERE id = v_uid;
  IF v_cid IS NULL THEN
    INSERT INTO contractors (legal_name, registered_by) VALUES (_clean_text(p_data ->> 'legal_name', 200, TRUE), v_uid)
    RETURNING id INTO v_cid;
    UPDATE profiles SET contractor_id = v_cid WHERE id = v_uid;
  END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_cid FOR UPDATE;
  IF v_c.status <> 'draft' THEN RAISE EXCEPTION 'Registrasi sudah dikirim; perubahan via profil perusahaan' USING ERRCODE = '22023'; END IF;

  BEGIN
    UPDATE contractors SET
      legal_name            = CASE WHEN p_data ? 'legal_name' THEN _clean_text(p_data ->> 'legal_name', 200, TRUE) ELSE legal_name END,
      trading_name          = CASE WHEN p_data ? 'trading_name' THEN _clean_text(p_data ->> 'trading_name', 200) ELSE trading_name END,
      registration_no       = CASE WHEN p_data ? 'registration_no' THEN _clean_text(p_data ->> 'registration_no', 60) ELSE registration_no END,
      tax_id                = CASE WHEN p_data ? 'tax_id' THEN _clean_text(p_data ->> 'tax_id', 40) ELSE tax_id END,
      country               = CASE WHEN p_data ? 'country' THEN v_country ELSE country END,
      address               = CASE WHEN p_data ? 'address' THEN _clean_text(p_data ->> 'address', 500) ELSE address END,
      website               = CASE WHEN p_data ? 'website' THEN _clean_text(p_data ->> 'website', 300) ELSE website END,
      primary_contact_name  = CASE WHEN p_data ? 'primary_contact_name' THEN _clean_text(p_data ->> 'primary_contact_name', 120) ELSE primary_contact_name END,
      primary_contact_email = CASE WHEN p_data ? 'primary_contact_email' THEN v_pc_email ELSE primary_contact_email END,
      email_domain          = CASE WHEN p_data ? 'primary_contact_email' THEN split_part(v_pc_email, '@', 2) ELSE email_domain END,
      primary_contact_phone_enc = CASE WHEN p_data ? 'primary_contact_phone' THEN _encrypt(v_phone, 'data', v_ver) ELSE primary_contact_phone_enc END,
      enc_key_ver           = CASE WHEN p_data ? 'primary_contact_phone' THEN v_ver ELSE enc_key_ver END,
      hse_manager_name      = CASE WHEN p_data ? 'hse_manager_name' THEN _clean_text(p_data ->> 'hse_manager_name', 120) ELSE hse_manager_name END,
      hse_manager_email     = CASE WHEN p_data ? 'hse_manager_email' THEN _clean_email(p_data ->> 'hse_manager_email', FALSE) ELSE hse_manager_email END,
      updated_at = NOW()
    WHERE id = v_cid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Tax ID sudah terdaftar untuk negara ini' USING ERRCODE = '23505', HINT = 'duplicate_tax_id';
  END;
  RETURN jsonb_build_object('contractor_id', v_cid, 'tracking_id', 'CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'));
END $$;

CREATE OR REPLACE FUNCTION submit_registration(p_privacy_accepted BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_self_service(TRUE); v_c contractors; v_p profiles;
BEGIN
  PERFORM _assert_attestation('registration');
  IF p_privacy_accepted IS NOT TRUE THEN RAISE EXCEPTION 'Privacy Notice wajib disetujui' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  SELECT * INTO v_c FROM contractors WHERE id = v_p.contractor_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Draft registrasi belum ada' USING ERRCODE = '22023'; END IF;
  IF v_c.status <> 'draft' THEN RAISE EXCEPTION 'Registrasi sudah dikirim' USING ERRCODE = '22023'; END IF;
  IF v_c.registration_no IS NULL OR v_c.tax_id IS NULL OR v_c.country IS NULL OR v_c.address IS NULL
     OR v_c.primary_contact_name IS NULL OR v_c.primary_contact_email IS NULL OR v_c.primary_contact_phone_enc IS NULL
     OR v_c.hse_manager_name IS NULL OR v_c.hse_manager_email IS NULL THEN
    RAISE EXCEPTION 'Lengkapi semua field wajib' USING ERRCODE = '22023';
  END IF;

  UPDATE contractors SET status = 'under_review', submitted_at = NOW(), status_reason = NULL, updated_at = NOW() WHERE id = v_c.id;
  UPDATE profiles SET privacy_accepted_at = NOW() WHERE id = v_uid;
  PERFORM _notify(v_uid, 'registration_received', 'Registrasi diterima',
                  'Tracking ID CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'),
                  CASE WHEN v_p.status = 'active' THEN '/my-company' ELSE '/pending' END, 'info', 1001,
                  jsonb_build_object('tracking_id', 'CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'), 'company', v_c.legal_name),
                  'regsubmit:' || v_c.id || ':' || extract(epoch FROM NOW())::BIGINT);
  PERFORM _notify_permission_holders('vendor.edit', NULL, 'vendor_submitted', 'Registrasi vendor baru', v_c.legal_name,
                                     '/vendors/' || v_c.id, 'info', NULL, '{}'::jsonb, 'vendorsub:' || v_c.id || ':' || extract(epoch FROM NOW())::BIGINT);
  IF v_p.status = 'active' THEN PERFORM generate_vendor_tasks(v_c.id); END IF;
  RETURN jsonb_build_object('tracking_id', 'CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'), 'status', 'under_review');
END $$;

CREATE OR REPLACE FUNCTION get_my_registration() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_self_service(FALSE); v_c contractors;
BEGIN
  SELECT c.* INTO v_c FROM profiles p JOIN contractors c ON c.id = p.contractor_id WHERE p.id = v_uid;
  RETURN jsonb_build_object(
    'contractor', CASE WHEN v_c.id IS NULL THEN NULL ELSE jsonb_build_object(
       'id', v_c.id, 'tracking_id', 'CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'), 'status', v_c.status,
       'status_reason', v_c.status_reason, 'submitted_at', v_c.submitted_at,
       'legal_name', v_c.legal_name, 'trading_name', v_c.trading_name, 'registration_no', v_c.registration_no,
       'tax_id', v_c.tax_id, 'country', v_c.country, 'address', v_c.address, 'website', v_c.website,
       'primary_contact_name', v_c.primary_contact_name, 'primary_contact_email', v_c.primary_contact_email,
       'primary_contact_phone', _decrypt(v_c.primary_contact_phone_enc, 'data', v_c.enc_key_ver),
       'hse_manager_name', v_c.hse_manager_name, 'hse_manager_email', v_c.hse_manager_email) END,
    'documents_preview', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code', code, 'label', label,
                                  'requirement', vendor_requirement, 'condition', vendor_condition_key) ORDER BY code), '[]'::jsonb)
                          FROM doc_type_catalog WHERE vendor_requirement IS NOT NULL AND active));
END $$;

-- ═════════════ ADMIN — UMUM ═════════════
CREATE OR REPLACE FUNCTION _assert_admin_mode() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  IF auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Admin Mode membutuhkan MFA'); END IF;
  IF NOT EXISTS (SELECT 1 FROM permissions WHERE key LIKE 'admin.%' AND has_permission(key)) THEN PERFORM _deny('forbidden'); END IF;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION _assert_can_grant(p_role UUID) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM roles WHERE id = p_role AND key = 'super_admin') THEN
    PERFORM _deny('forbidden', 'super_admin hanya untuk email allowlist (migration)');
  END IF;
  IF EXISTS (SELECT 1 FROM role_permissions rp JOIN permissions pm ON pm.key = rp.permission_key
             WHERE rp.role_id = p_role AND pm.audience <> 'contractor' AND NOT has_permission(rp.permission_key)) THEN
    PERFORM _deny('forbidden', 'Anda tidak memiliki semua permission dalam role ini');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION _role_is_critical(p_role UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM role_permissions rp JOIN permissions pm ON pm.key = rp.permission_key
                 WHERE rp.role_id = p_role AND pm.risk_level = 'critical')
$$;

CREATE OR REPLACE FUNCTION _assert_not_root_target(p_user UUID) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND is_root_admin) AND p_user <> auth.uid() THEN
    PERFORM _deny('forbidden', 'Root admin dilindungi');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION admin_overview() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM _assert_admin_mode();
  RETURN jsonb_build_object(
    'pending_users',      (SELECT count(*) FROM profiles WHERE status = 'pending' AND anonymized_at IS NULL),
    'active_users',       (SELECT count(*) FROM profiles WHERE status = 'active'),
    'open_security',      (SELECT count(*) FROM security_events WHERE handled_at IS NULL AND severity <> 'info'),
    'outbox_failed',      (SELECT count(*) FROM notification_outbox WHERE status = 'failed'),
    'link_gaps',          (SELECT count(*) FROM tasks t WHERE t.status IN ('open','file_issue') AND t.kind IN ('document','evidence')
                                                      AND resolve_upload_link(t.id) IS NULL),
    'tasks_overdue',      (SELECT count(*) FROM tasks WHERE status IN ('open','awaiting_email','file_issue') AND due_date < _local_today()),
    'reviews_overdue',    (SELECT count(*) FROM tasks WHERE status IN ('submitted','under_review') AND review_due_at < NOW()),
    'contracts_by_status',(SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) FROM (SELECT status, count(*) n FROM contracts GROUP BY status) s),
    'vendors_by_status',  (SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) FROM (SELECT status, count(*) n FROM contractors GROUP BY status) s),
    'read_only_mode',     _setting_bool('read_only_mode', FALSE),
    'audit_head',         (SELECT jsonb_build_object('id', last_id, 'hash', last_hash) FROM audit_chain_head WHERE id = 1),
    -- Checklist go-live (Part 20.6): TRUE = masalah yang harus dibereskan. Kredensial Google dicek manual (tidak terlihat dari DB)
    'golive_checks', jsonb_build_object(
      'vendor_mailbox_placeholder',  COALESCE(_setting_text('vendor_review_mailbox', NULL), '') ILIKE '%example.com',
      'geozone_mailbox_placeholder', EXISTS (SELECT 1 FROM geozones WHERE active AND review_mailbox ILIKE '%example.com'),
      'inbound_placeholder',         _setting_bool('inbound_auto_match', FALSE)
                                     AND COALESCE(_setting_text('inbound_address', NULL), '') ILIKE '%example.com',
      'templates_unmapped',          (SELECT count(*) FROM jsonb_each(setting('brevo_template_map')) e WHERE COALESCE(e.value #>> '{}', '') !~ '^[1-9][0-9]*$'),
      'no_holidays_next_year',       NOT EXISTS (SELECT 1 FROM holidays WHERE extract(year FROM holiday_date) = extract(year FROM _local_today()) + 1),
      'password_login_enabled',      _setting_bool('password_login_enabled', FALSE),
      'mock_or_dev_users',           EXISTS (SELECT 1 FROM profiles WHERE email LIKE '%@dev.local' OR email LIKE '%.dev.local'))
  );
END $$;

-- ═════════════ ADMIN — USERS ═════════════
CREATE OR REPLACE FUNCTION admin_approve_user(p_user UUID, p_role_key TEXT, p_scope_type TEXT, p_scope_id TEXT,
  p_contractor UUID, p_expires_at TIMESTAMPTZ, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.approve'); v_reason TEXT := _require_reason(p_reason);
        v_p profiles; v_role roles; v_cid UUID; v_st TEXT; v_sid TEXT;
BEGIN
  IF p_user = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa menyetujui akun sendiri'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND OR v_p.status <> 'pending' THEN RAISE EXCEPTION 'User tidak dalam status pending' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_role FROM roles WHERE key = p_role_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak dikenal' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_can_grant(v_role.id);
  IF _role_is_critical(v_role.id) THEN PERFORM assert_step_up(); END IF;

  IF v_role.is_wfrd THEN
    IF p_contractor IS NOT NULL THEN RAISE EXCEPTION 'Role WFRD tidak boleh terhubung ke contractor' USING ERRCODE = '22023'; END IF;
    v_cid := NULL; v_st := COALESCE(p_scope_type, 'global'); v_sid := CASE WHEN v_st = 'global' THEN NULL ELSE p_scope_id END;
    PERFORM _validate_scope(v_st, v_sid);
  ELSE
    v_cid := COALESCE(p_contractor, v_p.contractor_id);
    IF v_cid IS NULL OR NOT EXISTS (SELECT 1 FROM contractors WHERE id = v_cid) THEN
      RAISE EXCEPTION 'Role contractor wajib memilih contractor' USING ERRCODE = '22023';
    END IF;
    v_st := 'global'; v_sid := NULL;
  END IF;

  UPDATE profiles SET status = 'active', status_reason = NULL, contractor_id = v_cid, approved_by = v_uid, approved_at = NOW()
  WHERE id = p_user;
  PERFORM _grant_role_internal(p_user, v_role.id, v_st, v_sid, p_expires_at, v_reason, v_uid);
  UPDATE user_invites SET accepted_at = NOW(), accepted_by = p_user
  WHERE email = v_p.email AND accepted_at IS NULL AND revoked_at IS NULL;
  PERFORM _security_event(p_user, 'user_status', 'info', jsonb_build_object('status', 'active', 'by', v_uid, 'role', p_role_key));
  PERFORM _notify(p_user, 'account_approved', 'Akun Anda aktif', 'Selamat datang di COMEN.', '/', 'info', 7003,
                  jsonb_build_object('name', v_p.full_name), 'approved:' || p_user);
  PERFORM _after_activation(p_user);
END $$;

CREATE OR REPLACE FUNCTION admin_reject_user(p_user UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.approve'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  IF p_user = v_uid THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND OR v_p.status <> 'pending' THEN RAISE EXCEPTION 'User tidak dalam status pending' USING ERRCODE = '22023'; END IF;
  UPDATE profiles SET status = 'rejected', status_reason = v_reason, sessions_valid_after = NOW() WHERE id = p_user;
  PERFORM _security_event(p_user, 'user_status', 'info', jsonb_build_object('status', 'rejected', 'by', v_uid));
  PERFORM _email(7008, v_p.email, jsonb_build_object('name', v_p.full_name, 'reason', v_reason), 'rejected:' || p_user);
END $$;

CREATE OR REPLACE FUNCTION admin_grant_role(p_user UUID, p_role_key TEXT, p_scope_type TEXT, p_scope_id TEXT,
  p_expires_at TIMESTAMPTZ, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.edit'); v_reason TEXT := _require_reason(p_reason);
        v_p profiles; v_role roles; v_st TEXT; v_sid TEXT; v_id UUID;
BEGIN
  IF p_user = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa mengubah role sendiri'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user;
  IF v_p.status <> 'active' THEN RAISE EXCEPTION 'User belum aktif (gunakan User Approval)' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_role FROM roles WHERE key = p_role_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak dikenal' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_can_grant(v_role.id);
  IF _role_is_critical(v_role.id) THEN PERFORM assert_step_up(); END IF;
  IF v_role.is_wfrd THEN
    v_st := COALESCE(p_scope_type, 'global'); v_sid := CASE WHEN v_st = 'global' THEN NULL ELSE p_scope_id END;
    PERFORM _validate_scope(v_st, v_sid);
  ELSE
    v_st := 'global'; v_sid := NULL;                                   -- trigger menolak jika user bukan contractor
  END IF;
  v_id := _grant_role_internal(p_user, v_role.id, v_st, v_sid, p_expires_at, v_reason, v_uid);
  PERFORM _security_event(p_user, 'role_changed', CASE WHEN _role_is_critical(v_role.id) THEN 'critical' ELSE 'info' END,
                          jsonb_build_object('action', 'grant', 'role', p_role_key, 'scope_type', v_st, 'scope_id', v_sid, 'by', v_uid));
  PERFORM _notify(p_user, 'role_changed', 'Akses Anda diperbarui', 'Role ' || v_role.name || ' ditambahkan', '/', 'info', 7007,
                  jsonb_build_object('role', v_role.name, 'action', 'grant'), 'rolegrant:' || v_id || ':' || extract(epoch FROM NOW())::BIGINT);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION admin_revoke_role(p_user_role UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.edit'); v_reason TEXT := _require_reason(p_reason); v_ur user_roles; v_role roles;
BEGIN
  SELECT * INTO v_ur FROM user_roles WHERE id = p_user_role;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role user tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_ur.user_id = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa mengubah role sendiri'); END IF;
  SELECT * INTO v_role FROM roles WHERE id = v_ur.role_id;
  PERFORM _assert_can_grant(v_role.id);
  IF _role_is_critical(v_role.id) THEN PERFORM assert_step_up(); END IF;
  DELETE FROM user_roles WHERE id = p_user_role;                       -- trg_user_roles_guard melindungi root
  PERFORM _security_event(v_ur.user_id, 'role_changed', 'info',
                          jsonb_build_object('action', 'revoke', 'role', v_role.key, 'reason', v_reason, 'by', v_uid));
  PERFORM _notify(v_ur.user_id, 'role_changed', 'Akses Anda diperbarui', 'Role ' || v_role.name || ' dicabut', '/', 'warning', 7007,
                  jsonb_build_object('role', v_role.name, 'action', 'revoke'), 'rolerevoke:' || p_user_role);
END $$;

-- Dipanggil Edge admin-actions (JWT admin) sebelum ban/unban via Auth Admin API
CREATE OR REPLACE FUNCTION admin_set_user_status(p_user UUID, p_status account_status, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.suspend'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  IF p_status NOT IN ('active','suspended','deactivated') THEN RAISE EXCEPTION 'Status tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_user = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa mengubah status sendiri'); END IF;
  PERFORM _assert_not_root_target(p_user);
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_p.status = 'pending' OR v_p.status = 'rejected' THEN RAISE EXCEPTION 'Gunakan User Approval untuk akun pending/rejected' USING ERRCODE = '22023'; END IF;
  IF v_p.anonymized_at IS NOT NULL THEN RAISE EXCEPTION 'Akun sudah dianonimkan' USING ERRCODE = '22023'; END IF;
  UPDATE profiles SET status = p_status, status_reason = v_reason,
                      sessions_valid_after = CASE WHEN p_status <> 'active' THEN NOW() ELSE sessions_valid_after END
  WHERE id = p_user;
  PERFORM _security_event(p_user, 'user_status', CASE WHEN p_status = 'active' THEN 'info' ELSE 'warning' END,
                          jsonb_build_object('status', p_status, 'reason', v_reason, 'by', v_uid));
  IF p_status = 'suspended' THEN
    PERFORM _email(7004, v_p.email, jsonb_build_object('name', v_p.full_name), 'suspended:' || p_user || ':' || extract(epoch FROM NOW())::BIGINT);
  END IF;
  PERFORM _rt_send('user:' || p_user, 'session_check', '{}'::jsonb);
  RETURN jsonb_build_object('user_id', p_user, 'status', p_status, 'ban', p_status <> 'active');
END $$;

CREATE OR REPLACE FUNCTION admin_force_logout(p_user UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.sessions.revoke'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  PERFORM _assert_not_root_target(p_user);
  UPDATE profiles SET sessions_valid_after = NOW() WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(p_user, 'force_logout', 'warning', jsonb_build_object('reason', v_reason, 'by', v_uid));
  PERFORM _rt_send('user:' || p_user, 'session_check', '{}'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_revoke_device(p_device UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.sessions.revoke'); v_reason TEXT := _require_reason(p_reason); v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM trusted_devices WHERE id = p_device;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'Perangkat tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_not_root_target(v_owner);
  UPDATE trusted_devices SET revoked_at = NOW(), revoked_by = v_uid, revoke_reason = v_reason WHERE id = p_device AND revoked_at IS NULL;
  DELETE FROM push_subscriptions WHERE device_id = p_device;
  PERFORM _security_event(v_owner, 'device_revoked', 'warning', jsonb_build_object('device', p_device, 'reason', v_reason, 'by', v_uid));
  PERFORM _notify(v_owner, 'device_revoked', 'Perangkat dicabut', v_reason, '/settings/devices', 'warning', NULL, '{}'::jsonb, 'devrev:' || p_device);
  PERFORM _rt_send('user:' || v_owner, 'session_check', '{}'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_set_user_contractor(p_user UUID, p_contractor UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.edit'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  IF p_user = v_uid THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF v_p.contractor_id IS NULL AND v_p.status = 'active' THEN
    RAISE EXCEPTION 'User WFRD tidak bisa dipindah ke contractor' USING ERRCODE = '22023';
  END IF;
  IF p_contractor IS NULL OR NOT EXISTS (SELECT 1 FROM contractors WHERE id = p_contractor) THEN
    RAISE EXCEPTION 'Contractor tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  UPDATE profiles SET contractor_id = p_contractor WHERE id = p_user;
  PERFORM _security_event(p_user, 'contractor_changed', 'warning',
                          jsonb_build_object('from', v_p.contractor_id, 'to', p_contractor, 'reason', v_reason, 'by', v_uid));
  PERFORM _after_activation(p_user);
END $$;

-- Otorisasi aksi Auth Admin API oleh Edge admin-actions: 'ban' | 'unban' | 'reset_mfa'
CREATE OR REPLACE FUNCTION admin_authorize_action(p_action TEXT, p_user UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.suspend'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  IF p_action NOT IN ('ban','unban','reset_mfa') THEN RAISE EXCEPTION 'Aksi tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_user = v_uid AND p_action <> 'reset_mfa' THEN PERFORM _deny('forbidden'); END IF;
  PERFORM _assert_not_root_target(p_user);
  SELECT * INTO v_p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF p_action = 'reset_mfa' THEN
    PERFORM assert_step_up();
    UPDATE profiles SET sessions_valid_after = NOW() WHERE id = p_user;
  END IF;
  IF p_action = 'unban' AND v_p.status <> 'active' THEN RAISE EXCEPTION 'Aktifkan akun dulu' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(p_user, 'admin_action', 'warning', jsonb_build_object('action', p_action, 'reason', v_reason, 'by', v_uid));
  RETURN jsonb_build_object('user_id', p_user, 'action', p_action, 'authorized', TRUE);
END $$;

CREATE OR REPLACE FUNCTION admin_user_effective_permissions(p_user UUID)
RETURNS TABLE (permission_key TEXT, risk_level TEXT, audience TEXT, role_key TEXT, scope_type TEXT, scope_id TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_access('admin.users.view', NULL, FALSE);
  RETURN QUERY
  SELECT pm.key, pm.risk_level, pm.audience, r.key, ur.scope_type, ur.scope_id, ur.expires_at
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id
  JOIN role_permissions rp ON rp.role_id = r.id
  JOIN permissions pm ON pm.key = rp.permission_key
                      OR (rp.permission_key = '*' AND pm.key <> '*' AND pm.audience <> 'contractor')
  WHERE ur.user_id = p_user AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
  ORDER BY pm.key, r.key;
END $$;

CREATE OR REPLACE FUNCTION admin_list_users(p_status account_status DEFAULT NULL, p_search TEXT DEFAULT NULL,
  p_contractor UUID DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_q TEXT := _clean_text(p_search, 100);
BEGIN
  PERFORM assert_access('admin.users.view', NULL, FALSE);
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) FROM (
    SELECT p.id, p.email, p.full_name, p.avatar_url, p.status, p.status_reason, p.is_root_admin, p.contractor_id,
           c.legal_name AS contractor_name, c.status AS vendor_status, p.last_login_at, p.created_at,
           (SELECT i.provider FROM auth.identities i WHERE i.user_id = p.id ORDER BY i.created_at LIMIT 1) AS provider,
           EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = p.id AND f.status = 'verified') AS mfa_enrolled,
           (SELECT count(*) FROM trusted_devices d WHERE d.user_id = p.id AND d.revoked_at IS NULL) AS devices,
           (SELECT count(*) FROM profiles q WHERE q.status = 'pending' AND split_part(q.email, '@', 2) = split_part(p.email, '@', 2)) AS same_domain_pending,
           EXISTS (SELECT 1 FROM contractors k WHERE k.email_domain = split_part(p.email, '@', 2) AND k.status <> 'draft') AS domain_matches_contractor,
           (SELECT jsonb_agg(jsonb_build_object('id', ur.id, 'role', r.key, 'scope_type', ur.scope_type, 'scope_id', ur.scope_id, 'expires_at', ur.expires_at))
              FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p.id) AS roles
    FROM profiles p LEFT JOIN contractors c ON c.id = p.contractor_id
    WHERE (p_status IS NULL OR p.status = p_status)
      AND (p_contractor IS NULL OR p.contractor_id = p_contractor)
      AND (v_q IS NULL OR p.email ILIKE '%' || v_q || '%' OR p.full_name ILIKE '%' || v_q || '%')
    ORDER BY p.created_at DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200) OFFSET GREATEST(p_offset, 0)) x);
END $$;

-- ═════════════ ADMIN — INVITES ═════════════
CREATE OR REPLACE FUNCTION admin_create_invite(p_email TEXT, p_role_key TEXT, p_scope_type TEXT, p_scope_id TEXT,
  p_contractor UUID, p_role_expires_at TIMESTAMPTZ, p_note TEXT, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.invites.manage'); v_reason TEXT := _require_reason(p_reason);
        v_email TEXT := _clean_email(p_email, TRUE); v_role roles; v_st TEXT; v_sid TEXT; v_cid UUID; v_id UUID; v_existing UUID;
BEGIN
  PERFORM hit_rate_limit('invite:' || v_uid, 50, INTERVAL '1 hour');
  SELECT * INTO v_role FROM roles WHERE key = p_role_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak dikenal' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_can_grant(v_role.id);
  IF EXISTS (SELECT 1 FROM profiles WHERE email = v_email AND status <> 'pending') THEN
    RAISE EXCEPTION 'Email sudah memiliki akun (gunakan Users & Access)' USING ERRCODE = '22023';
  END IF;
  IF v_role.is_wfrd THEN
    IF p_contractor IS NOT NULL THEN RAISE EXCEPTION 'Role WFRD tidak boleh terhubung ke contractor' USING ERRCODE = '22023'; END IF;
    v_st := COALESCE(p_scope_type, 'global'); v_sid := CASE WHEN v_st = 'global' THEN NULL ELSE p_scope_id END;
    PERFORM _validate_scope(v_st, v_sid);
  ELSE
    IF p_contractor IS NULL OR NOT EXISTS (SELECT 1 FROM contractors WHERE id = p_contractor) THEN
      RAISE EXCEPTION 'Role contractor wajib memilih contractor' USING ERRCODE = '22023';
    END IF;
    v_st := 'global'; v_sid := NULL; v_cid := p_contractor;
  END IF;
  UPDATE user_invites SET revoked_at = NOW() WHERE email = v_email AND accepted_at IS NULL AND revoked_at IS NULL;
  INSERT INTO user_invites (email, role_id, scope_type, scope_id, contractor_id, role_expires_at, note, invited_by)
  VALUES (v_email, v_role.id, v_st, v_sid, v_cid, p_role_expires_at, _clean_text(p_note, 500), v_uid)
  RETURNING id INTO v_id;
  PERFORM _email(1007, v_email, jsonb_build_object('role', v_role.name, 'link', '/invite?email=' || replace(replace(v_email, '%', '%25'), '+', '%2B'),
                 'company', (SELECT legal_name FROM contractors WHERE id = v_cid)), 'invite:' || v_id);
  SELECT id INTO v_existing FROM profiles WHERE email = v_email AND status = 'pending';
  IF v_existing IS NOT NULL THEN PERFORM _onboard_user(v_existing, NULL); END IF;     -- user pending terverifikasi langsung aktif
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION admin_revoke_invite(p_invite UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.invites.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  UPDATE user_invites SET revoked_at = NOW() WHERE id = p_invite AND accepted_at IS NULL AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Undangan tidak aktif' USING ERRCODE = '22023'; END IF;
END $$;

-- ═════════════ ADMIN — ROLES & PERMISSIONS ═════════════
CREATE OR REPLACE FUNCTION admin_upsert_role(p_id UUID, p_key TEXT, p_name TEXT, p_description TEXT, p_is_wfrd BOOLEAN, p_reason TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.roles.manage'); v_reason TEXT := _require_reason(p_reason); v_r roles; v_id UUID;
BEGIN
  IF p_id IS NULL THEN
    IF p_key !~ '^[a-z_]{3,40}$' THEN RAISE EXCEPTION 'Key role: huruf kecil & underscore, 3–40' USING ERRCODE = '22023'; END IF;
    INSERT INTO roles (key, name, description, is_system, is_wfrd)
    VALUES (p_key, _clean_text(p_name, 80, TRUE), _clean_text(p_description, 500), FALSE, COALESCE(p_is_wfrd, TRUE))
    RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_r FROM roles WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak ditemukan' USING ERRCODE = '22023'; END IF;
    IF v_r.key = 'super_admin' THEN PERFORM _deny('forbidden', 'Role super_admin terkunci'); END IF;
    IF p_is_wfrd IS DISTINCT FROM v_r.is_wfrd AND (v_r.is_system
       OR EXISTS (SELECT 1 FROM user_roles WHERE role_id = p_id) OR EXISTS (SELECT 1 FROM role_permissions WHERE role_id = p_id)) THEN
      RAISE EXCEPTION 'Tipe WFRD/contractor tidak bisa diubah untuk role yang sudah dipakai' USING ERRCODE = '22023';
    END IF;
    UPDATE roles SET name = _clean_text(p_name, 80, TRUE), description = _clean_text(p_description, 500),
                     is_wfrd = COALESCE(p_is_wfrd, is_wfrd), updated_at = NOW()
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  PERFORM _security_event(v_uid, 'settings_changed', 'info', jsonb_build_object('role', v_id, 'reason', v_reason));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION admin_preview_role_change(p_role UUID, p_permissions TEXT[]) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_added TEXT[]; v_removed TEXT[];
BEGIN
  PERFORM assert_access('admin.roles.manage', NULL, FALSE);
  SELECT COALESCE(array_agg(x ORDER BY x), '{}') INTO v_added FROM unnest(p_permissions) x
   WHERE x NOT IN (SELECT permission_key FROM role_permissions WHERE role_id = p_role);
  SELECT COALESCE(array_agg(permission_key ORDER BY permission_key), '{}') INTO v_removed FROM role_permissions
   WHERE role_id = p_role AND permission_key <> ALL(p_permissions);
  RETURN jsonb_build_object(
    'added', to_jsonb(v_added), 'removed', to_jsonb(v_removed),
    'has_critical', EXISTS (SELECT 1 FROM permissions WHERE key = ANY(v_added || v_removed) AND risk_level = 'critical'),
    'invalid_audience', (SELECT COALESCE(jsonb_agg(pm.key), '[]'::jsonb) FROM permissions pm JOIN roles r ON r.id = p_role
                          WHERE pm.key = ANY(v_added) AND ((r.is_wfrd AND pm.audience = 'contractor') OR (NOT r.is_wfrd AND pm.audience = 'wfrd'))),
    'affected_count', (SELECT count(DISTINCT user_id) FROM user_roles WHERE role_id = p_role),
    'affected_users', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'email', p.email, 'name', p.full_name)), '[]'::jsonb)
                       FROM (SELECT DISTINCT user_id FROM user_roles WHERE role_id = p_role LIMIT 100) u JOIN profiles p ON p.id = u.user_id));
END $$;

CREATE OR REPLACE FUNCTION admin_set_role_permissions(p_role UUID, p_permissions TEXT[], p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.roles.manage'); v_reason TEXT := _require_reason(p_reason); v_r roles; v_crit BOOLEAN;
BEGIN
  SELECT * INTO v_r FROM roles WHERE id = p_role FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_r.key = 'super_admin' THEN PERFORM _deny('forbidden', 'Role super_admin terkunci'); END IF;
  IF '*' = ANY(p_permissions) THEN PERFORM _deny('forbidden', 'Permission * hanya milik super_admin'); END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_permissions) x WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE key = x)) THEN
    RAISE EXCEPTION 'Ada permission tidak dikenal' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM permissions pm WHERE pm.key = ANY(p_permissions) AND pm.audience <> 'contractor'
               AND pm.key NOT IN (SELECT permission_key FROM role_permissions WHERE role_id = p_role)
               AND NOT has_permission(pm.key)) THEN
    PERFORM _deny('forbidden', 'Anda tidak bisa memberikan permission yang tidak Anda miliki');
  END IF;
  SELECT EXISTS (SELECT 1 FROM permissions pm WHERE pm.risk_level = 'critical' AND (
           (pm.key = ANY(p_permissions) AND pm.key NOT IN (SELECT permission_key FROM role_permissions WHERE role_id = p_role))
        OR (pm.key <> ALL(p_permissions) AND pm.key IN (SELECT permission_key FROM role_permissions WHERE role_id = p_role))))
    INTO v_crit;
  IF v_crit THEN PERFORM assert_step_up(); END IF;

  DELETE FROM role_permissions WHERE role_id = p_role AND permission_key <> ALL(p_permissions);
  INSERT INTO role_permissions (role_id, permission_key)
  SELECT p_role, x FROM unnest(p_permissions) x ON CONFLICT DO NOTHING;           -- trigger audience menolak yang tidak cocok
  PERFORM _security_event(v_uid, 'permission_changed', CASE WHEN v_crit THEN 'critical' ELSE 'info' END,
                          jsonb_build_object('role', v_r.key, 'permissions', to_jsonb(p_permissions), 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_delete_role(p_role UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.roles.manage'); v_reason TEXT := _require_reason(p_reason); v_r roles;
BEGIN
  SELECT * INTO v_r FROM roles WHERE id = p_role;
  IF NOT FOUND OR v_r.is_system THEN PERFORM _deny('forbidden', 'Role sistem tidak bisa dihapus'); END IF;
  IF EXISTS (SELECT 1 FROM user_roles WHERE role_id = p_role)
     OR EXISTS (SELECT 1 FROM user_invites WHERE role_id = p_role AND accepted_at IS NULL AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'Role masih dipakai user/undangan' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM doc_type_catalog WHERE reviewer_role = v_r.key) THEN
    RAISE EXCEPTION 'Role dipakai sebagai reviewer_role di katalog' USING ERRCODE = '22023';
  END IF;
  DELETE FROM roles WHERE id = p_role;
  PERFORM _security_event(v_uid, 'settings_changed', 'info', jsonb_build_object('deleted_role', v_r.key, 'reason', v_reason));
END $$;

-- ═════════════ ADMIN — SETTINGS, HOLIDAY, GEOZONE ═════════════
CREATE OR REPLACE FUNCTION admin_upsert_setting(p_key TEXT, p_value JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_s app_settings; v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  SELECT * INTO v_s FROM app_settings WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Setting tidak dikenal' USING ERRCODE = '22023'; END IF;
  IF p_key IN ('read_only_mode','global_sessions_valid_after','email_otp_enabled','password_login_enabled') THEN
    RAISE EXCEPTION 'Setting ini hanya bisa diubah lewat Danger Zone / migration' USING ERRCODE = '22023';
  END IF;
  v_uid := assert_access(v_s.required_permission);
  IF v_s.required_permission IN ('admin.security.manage','admin.system.danger') THEN PERFORM assert_step_up(); END IF;

  CASE p_key
    WHEN 'mfa_required_roles' THEN
      IF jsonb_typeof(p_value) <> 'array' OR NOT p_value ? 'super_admin'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_value) k WHERE NOT EXISTS (SELECT 1 FROM roles WHERE key = k)) THEN
        RAISE EXCEPTION 'Harus array role valid dan memuat super_admin' USING ERRCODE = '22023'; END IF;
    WHEN 'step_up_hours' THEN
      IF jsonb_typeof(p_value) <> 'number' OR (p_value #>> '{}')::INT NOT BETWEEN 1 AND 24 THEN
        RAISE EXCEPTION 'step_up_hours 1–24' USING ERRCODE = '22023'; END IF;
    WHEN 'rate_chat_per_min' THEN
      IF jsonb_typeof(p_value) <> 'number' OR (p_value #>> '{}')::INT NOT BETWEEN 5 AND 120 THEN
        RAISE EXCEPTION 'rate_chat_per_min 5–120' USING ERRCODE = '22023'; END IF;
    WHEN 'chat_key_ver', 'data_key_ver' THEN
      IF jsonb_typeof(p_value) <> 'number' THEN RAISE EXCEPTION 'Versi kunci harus angka' USING ERRCODE = '22023'; END IF;
      PERFORM _key(replace(p_key, '_key_ver', ''), (p_value #>> '{}')::SMALLINT);   -- gagal jika secret belum ada di Vault
    WHEN 'vendor_review_mailbox', 'inbound_address' THEN
      PERFORM _clean_email(p_value #>> '{}', TRUE);
    WHEN 'business_timezone' THEN
      PERFORM NOW() AT TIME ZONE (p_value #>> '{}');
    WHEN 'brevo_template_map', 'kpi_weights', 'kpi_targets' THEN
      IF jsonb_typeof(p_value) <> 'object' THEN RAISE EXCEPTION 'Harus objek JSON' USING ERRCODE = '22023'; END IF;
      IF p_key = 'kpi_weights' AND (SELECT sum(v::NUMERIC) FROM jsonb_each_text(p_value) e(k, v)) <> 100 THEN
        RAISE EXCEPTION 'Total bobot KPI harus 100' USING ERRCODE = '22023'; END IF;
    ELSE
      IF jsonb_typeof(p_value) IS DISTINCT FROM jsonb_typeof(v_s.value) THEN
        RAISE EXCEPTION 'Tipe nilai harus %', jsonb_typeof(v_s.value) USING ERRCODE = '22023'; END IF;
  END CASE;

  UPDATE app_settings SET value = p_value, updated_by = v_uid, updated_at = NOW() WHERE key = p_key;
  PERFORM _security_event(v_uid, 'settings_changed', CASE WHEN v_s.required_permission = 'admin.settings.manage' THEN 'info' ELSE 'warning' END,
                          jsonb_build_object('key', p_key, 'old', v_s.value, 'new', p_value, 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_upsert_holiday(p_id UUID, p_date DATE, p_geozone TEXT, p_name TEXT, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason); v_id UUID;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO holidays (holiday_date, geozone, name) VALUES (p_date, p_geozone, _clean_text(p_name, 120, TRUE)) RETURNING id INTO v_id;
  ELSE
    UPDATE holidays SET holiday_date = p_date, geozone = p_geozone, name = _clean_text(p_name, 120, TRUE) WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Hari libur sudah ada untuk tanggal & geozone ini' USING ERRCODE = '23505';
END $$;

CREATE OR REPLACE FUNCTION admin_delete_holiday(p_id UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  DELETE FROM holidays WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION admin_upsert_geozone(p_code TEXT, p_name TEXT, p_review_mailbox TEXT, p_timezone TEXT, p_active BOOLEAN, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  PERFORM NOW() AT TIME ZONE p_timezone;
  INSERT INTO geozones (code, name, review_mailbox, timezone, active)
  VALUES (upper(p_code), _clean_text(p_name, 80, TRUE), _clean_email(p_review_mailbox, TRUE), p_timezone, COALESCE(p_active, TRUE))
  ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, review_mailbox = EXCLUDED.review_mailbox,
                                   timezone = EXCLUDED.timezone, active = EXCLUDED.active;
END $$;

-- ═════════════ ADMIN — KATALOG DOKUMEN ═════════════
CREATE OR REPLACE FUNCTION admin_upsert_doc_type(p_code TEXT, p_data JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.catalog.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  IF p_code !~ '^[A-Z0-9]{6}$' THEN RAISE EXCEPTION 'Kode dokumen 6 karakter A-Z0-9' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM roles WHERE key = p_data ->> 'reviewer_role' AND is_wfrd) THEN
    RAISE EXCEPTION 'reviewer_role harus role WFRD yang ada' USING ERRCODE = '22023';
  END IF;
  INSERT INTO doc_type_catalog (code, label, allowed_scopes, kind, phase, requirement, condition_key, min_risk_class,
    vendor_requirement, vendor_condition_key, subcon_required, reviewer_role, requires_email, requires_expiry,
    requires_fingerprint, sensitive, due_anchor, due_offset_days, review_sla_days, is_mob_gate, checklist_template, active)
  VALUES (p_code, _clean_text(p_data ->> 'label', 120, TRUE),
    ARRAY(SELECT jsonb_array_elements_text(p_data -> 'allowed_scopes'))::task_scope[],
    (p_data ->> 'kind')::task_kind, (p_data ->> 'phase')::lifecycle_phase, p_data ->> 'requirement', p_data ->> 'condition_key',
    p_data ->> 'min_risk_class', p_data ->> 'vendor_requirement', p_data ->> 'vendor_condition_key',
    COALESCE((p_data ->> 'subcon_required')::BOOLEAN, FALSE), p_data ->> 'reviewer_role',
    COALESCE((p_data ->> 'requires_email')::BOOLEAN, (p_data ->> 'kind') = 'document'),
    COALESCE((p_data ->> 'requires_expiry')::BOOLEAN, FALSE), COALESCE((p_data ->> 'requires_fingerprint')::BOOLEAN, FALSE),
    COALESCE((p_data ->> 'sensitive')::BOOLEAN, FALSE), p_data ->> 'due_anchor', (p_data ->> 'due_offset_days')::INT,
    COALESCE((p_data ->> 'review_sla_days')::INT, 3), COALESCE((p_data ->> 'is_mob_gate')::BOOLEAN, FALSE),
    p_data -> 'checklist_template', COALESCE((p_data ->> 'active')::BOOLEAN, TRUE))
  ON CONFLICT (code) DO UPDATE SET
    label = EXCLUDED.label, allowed_scopes = EXCLUDED.allowed_scopes, kind = EXCLUDED.kind, phase = EXCLUDED.phase,
    requirement = EXCLUDED.requirement, condition_key = EXCLUDED.condition_key, min_risk_class = EXCLUDED.min_risk_class,
    vendor_requirement = EXCLUDED.vendor_requirement, vendor_condition_key = EXCLUDED.vendor_condition_key,
    subcon_required = EXCLUDED.subcon_required, reviewer_role = EXCLUDED.reviewer_role, requires_email = EXCLUDED.requires_email,
    requires_expiry = EXCLUDED.requires_expiry, requires_fingerprint = EXCLUDED.requires_fingerprint, sensitive = EXCLUDED.sensitive,
    due_anchor = EXCLUDED.due_anchor, due_offset_days = EXCLUDED.due_offset_days, review_sla_days = EXCLUDED.review_sla_days,
    is_mob_gate = EXCLUDED.is_mob_gate, checklist_template = EXCLUDED.checklist_template, active = EXCLUDED.active;
  -- Perubahan katalog TIDAK mengubah task yang sudah ada; berlaku untuk task baru.
END $$;

-- ═════════════ ADMIN — AUDIT & SECURITY ═════════════
CREATE OR REPLACE FUNCTION admin_audit_search(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_actor UUID DEFAULT NULL,
  p_table TEXT DEFAULT NULL, p_action TEXT DEFAULT NULL, p_record TEXT DEFAULT NULL,
  p_before_id BIGINT DEFAULT NULL, p_limit INT DEFAULT 100)
RETURNS TABLE (id BIGINT, created_at TIMESTAMPTZ, table_name TEXT, record_id TEXT, action TEXT, actor_id UUID,
               actor_email TEXT, old_data JSONB, new_data JSONB, row_hash TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_access('admin.audit.view', NULL, FALSE);
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to - p_from > INTERVAL '366 days' THEN
    RAISE EXCEPTION 'Rentang waktu wajib (maks 366 hari)' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT a.id, a.created_at, a.table_name, a.record_id, a.action, a.actor_id, p.email, a.old_data, a.new_data, a.row_hash
  FROM audit_logs a LEFT JOIN profiles p ON p.id = a.actor_id
  WHERE a.created_at >= p_from AND a.created_at < p_to
    AND (p_actor IS NULL OR a.actor_id = p_actor) AND (p_table IS NULL OR a.table_name = p_table)
    AND (p_action IS NULL OR a.action = p_action) AND (p_record IS NULL OR a.record_id = p_record)
    AND (p_before_id IS NULL OR a.id < p_before_id)
  ORDER BY a.id DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
END $$;

CREATE OR REPLACE FUNCTION admin_verify_audit_chain(p_from_id BIGINT DEFAULT NULL, p_limit INT DEFAULT 200000) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_prev TEXT; v_n INT := 0; v_first BOOLEAN := TRUE;
BEGIN
  PERFORM assert_access('admin.audit.verify', NULL, FALSE);
  FOR r IN SELECT * FROM audit_logs WHERE p_from_id IS NULL OR id >= p_from_id ORDER BY id LIMIT p_limit LOOP
    IF NOT v_first AND r.prev_hash IS DISTINCT FROM v_prev THEN
      RETURN jsonb_build_object('ok', FALSE, 'broken_at_id', r.id, 'reason', 'prev_hash_mismatch', 'checked', v_n);
    END IF;
    IF r.row_hash <> _audit_hash(r.prev_hash, r.table_name, r.record_id, r.action, r.old_data, r.new_data, r.actor_id, r.created_at) THEN
      RETURN jsonb_build_object('ok', FALSE, 'broken_at_id', r.id, 'reason', 'row_hash_mismatch', 'checked', v_n);
    END IF;
    v_prev := r.row_hash; v_first := FALSE; v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', TRUE, 'checked', v_n, 'last_hash', v_prev,
                            'head', (SELECT jsonb_build_object('id', last_id, 'hash', last_hash) FROM audit_chain_head WHERE id = 1));
END $$;

CREATE OR REPLACE FUNCTION admin_handle_security_event(p_id BIGINT, p_note TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.security.manage');
BEGIN
  UPDATE security_events SET handled_at = NOW(), handled_by = v_uid, handle_note = _require_reason(p_note)
  WHERE id = p_id AND handled_at IS NULL;
END $$;

-- ═════════════ ADMIN — PRIVACY ═════════════
CREATE OR REPLACE FUNCTION admin_export_user_data(p_user UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.privacy.manage'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  PERFORM assert_step_up();
  PERFORM hit_rate_limit('export:' || v_uid, 3, INTERVAL '1 hour');
  SELECT * INTO v_p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(p_user, 'export', 'warning', jsonb_build_object('kind', 'dsar', 'reason', v_reason, 'by', v_uid));
  RETURN jsonb_build_object(
    'generated_at', NOW(),
    'profile', to_jsonb(v_p) - 'phone_enc' || jsonb_build_object('phone', _decrypt(v_p.phone_enc, 'data', v_p.enc_key_ver)),
    'roles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', r.key, 'scope_type', ur.scope_type, 'scope_id', ur.scope_id,
                     'granted_at', ur.granted_at, 'expires_at', ur.expires_at)), '[]'::jsonb)
              FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p_user),
    'devices', (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', label, 'first_seen', first_seen, 'last_seen', last_seen,
                       'revoked_at', revoked_at)), '[]'::jsonb) FROM trusted_devices WHERE user_id = p_user),
    'security_events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', event, 'at', created_at)), '[]'::jsonb)
                        FROM security_events WHERE user_id = p_user),
    'tasks_confirmed', (SELECT COALESCE(jsonb_agg(jsonb_build_object('task_id', task_id, 'at', upload_confirmed_at)), '[]'::jsonb)
                        FROM tasks WHERE upload_confirmed_by = p_user),
    'messages', (SELECT COALESCE(jsonb_agg(jsonb_build_object('channel', channel_id, 'at', created_at,
                        'body', _decrypt(body_enc, 'chat', key_ver)) ORDER BY seq), '[]'::jsonb)
                 FROM chat_messages WHERE sender_id = p_user AND deleted_at IS NULL));
END $$;

CREATE OR REPLACE FUNCTION admin_anonymize_user(p_user UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.privacy.manage'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  PERFORM assert_step_up();
  IF p_user = v_uid THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_p.is_root_admin THEN PERFORM _deny('forbidden', 'Root admin tidak bisa dianonimkan'); END IF;
  IF v_p.anonymized_at IS NOT NULL THEN RETURN jsonb_build_object('already', TRUE); END IF;
  DELETE FROM user_roles WHERE user_id = p_user;
  DELETE FROM push_subscriptions WHERE user_id = p_user;
  DELETE FROM notifications WHERE user_id = p_user;
  DELETE FROM chat_saved WHERE user_id = p_user;
  UPDATE trusted_devices SET revoked_at = COALESCE(revoked_at, NOW()), revoked_by = v_uid, revoke_reason = 'anonymized', label = NULL, last_ip_hmac = NULL
  WHERE user_id = p_user;
  UPDATE profiles SET email = 'anon-' || p_user || '@anonymized.invalid', full_name = 'Pengguna Terhapus', avatar_url = NULL,
                      phone_enc = NULL, job_title = NULL, status = 'deactivated', status_reason = 'anonymized',
                      sessions_valid_after = NOW(), anonymized_at = NOW()
  WHERE id = p_user;
  -- PII di identitas Auth (nama/foto/email Google). `sub` dipertahankan → login Google berikutnya jatuh ke akun ter-ban ini
  UPDATE auth.identities SET identity_data = jsonb_build_object('sub', identity_data ->> 'sub',
                                                                'email', 'anon-' || p_user || '@anonymized.invalid',
                                                                'email_verified', TRUE)
  WHERE user_id = p_user;
  PERFORM _security_event(p_user, 'anonymized', 'warning', jsonb_build_object('reason', v_reason, 'by', v_uid));
  RETURN jsonb_build_object('user_id', p_user, 'auth_email', 'anon-' || p_user || '@anonymized.invalid');
END $$;

-- ═════════════ ADMIN — DANGER ZONE ═════════════
CREATE OR REPLACE FUNCTION _danger_set(p_key TEXT, p_value JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.system.danger', NULL, FALSE); v_reason TEXT := _require_reason(p_reason);
BEGIN
  PERFORM assert_step_up();
  UPDATE app_settings SET value = p_value, updated_by = v_uid, updated_at = NOW() WHERE key = p_key;
  PERFORM _security_event(v_uid, 'danger_zone', 'critical', jsonb_build_object('key', p_key, 'value', p_value, 'reason', v_reason));
  PERFORM _notify_permission_holders('admin.security.manage', NULL, 'security_alert', 'Danger Zone: ' || p_key, v_reason,
                                     '/admin/security', 'critical', 7005, jsonb_build_object('key', p_key), 'danger:' || p_key || ':' || extract(epoch FROM NOW())::BIGINT);
END $$;

CREATE OR REPLACE FUNCTION admin_set_read_only(p_on BOOLEAN, p_reason TEXT) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _danger_set('read_only_mode', to_jsonb(COALESCE(p_on, FALSE)), p_reason)
$$;
CREATE OR REPLACE FUNCTION admin_global_logout(p_reason TEXT) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _danger_set('global_sessions_valid_after', to_jsonb(NOW()), p_reason)
$$;
CREATE OR REPLACE FUNCTION admin_set_email_otp(p_on BOOLEAN, p_reason TEXT) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _danger_set('email_otp_enabled', to_jsonb(COALESCE(p_on, TRUE)), p_reason)
$$;

CREATE OR REPLACE FUNCTION admin_retry_outbox(p_ids BIGINT[], p_reason TEXT) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.templates.manage'); v_reason TEXT := _require_reason(p_reason); v_n INT;
BEGIN
  UPDATE notification_outbox SET status = 'queued', attempts = 0, send_after = NOW(), locked_until = NULL, last_error = NULL
  WHERE id = ANY(p_ids) AND status = 'failed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
