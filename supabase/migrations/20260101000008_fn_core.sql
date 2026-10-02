-- ───────────── Konteks request (PostgREST: request.headers = JSON, key lowercase) ─────────────
CREATE OR REPLACE FUNCTION request_header(p_name TEXT) RETURNS TEXT
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT NULLIF(current_setting('request.headers', true), '')::jsonb ->> lower(p_name)
$$;

CREATE OR REPLACE FUNCTION request_device_hash() RETURNS TEXT
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT h FROM (SELECT request_header('x-device-id') AS h) s WHERE h ~ '^[a-f0-9]{64}$'
$$;

CREATE OR REPLACE FUNCTION _secret(p_name TEXT) RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v TEXT;
BEGIN
  SELECT decrypted_secret INTO v FROM vault.decrypted_secrets WHERE name = p_name;
  IF v IS NULL OR v = '' THEN RAISE EXCEPTION 'Secret % belum dikonfigurasi', p_name USING ERRCODE = 'XX000'; END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION request_ip_hmac() RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ip TEXT := btrim(split_part(COALESCE(request_header('x-forwarded-for'), ''), ',', 1));
BEGIN
  IF v_ip = '' THEN RETURN NULL; END IF;
  RETURN encode(hmac(v_ip, _secret('ip_pepper'), 'sha256'), 'hex');
END $$;

-- ───────────── Setting ─────────────
CREATE OR REPLACE FUNCTION setting(p_key TEXT) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT value FROM app_settings WHERE key = p_key
$$;
CREATE OR REPLACE FUNCTION _setting_text(p_key TEXT, p_default TEXT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT COALESCE(setting(p_key) #>> '{}', p_default)
$$;
CREATE OR REPLACE FUNCTION _setting_int(p_key TEXT, p_default INT) RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT COALESCE((setting(p_key) #>> '{}')::INT, p_default)
$$;
CREATE OR REPLACE FUNCTION _setting_bool(p_key TEXT, p_default BOOLEAN) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT COALESCE((setting(p_key) #>> '{}')::BOOLEAN, p_default)
$$;

-- ───────────── Kriptografi kolom (AES-256 OpenPGP, kunci di Vault) ─────────────
-- p_kind: 'chat' → secret chat_key_v{n} · 'data' → secret comen_data_key_v{n}
CREATE OR REPLACE FUNCTION _active_key_ver(p_kind TEXT) RETURNS SMALLINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _setting_int(p_kind || '_key_ver', 1)::SMALLINT
$$;
CREATE OR REPLACE FUNCTION _key(p_kind TEXT, p_ver SMALLINT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _secret(CASE p_kind WHEN 'chat' THEN 'chat_key_v' WHEN 'data' THEN 'comen_data_key_v' END || p_ver)
$$;
CREATE OR REPLACE FUNCTION _encrypt(p_plain TEXT, p_kind TEXT, p_ver SMALLINT) RETURNS BYTEA
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN p_plain IS NULL THEN NULL
    ELSE pgp_sym_encrypt(p_plain, _key(p_kind, p_ver), 'cipher-algo=aes256, compress-algo=0, s2k-mode=1') END
$$;
CREATE OR REPLACE FUNCTION _decrypt(p_cipher BYTEA, p_kind TEXT, p_ver SMALLINT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN p_cipher IS NULL THEN NULL ELSE pgp_sym_decrypt(p_cipher, _key(p_kind, p_ver)) END
$$;

-- ───────────── Validasi input ─────────────
CREATE OR REPLACE FUNCTION _clean_text(p_text TEXT, p_max INT, p_required BOOLEAN DEFAULT FALSE) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE SET search_path = public, extensions AS $$
DECLARE v TEXT := NULLIF(btrim(p_text), '');
BEGIN
  IF v IS NULL THEN
    IF p_required THEN RAISE EXCEPTION 'Field wajib diisi' USING ERRCODE = '22023'; END IF;
    RETURN NULL;
  END IF;
  IF length(v) > p_max THEN RAISE EXCEPTION 'Teks melebihi % karakter', p_max USING ERRCODE = '22023'; END IF;
  IF v ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]' THEN
    RAISE EXCEPTION 'Teks mengandung karakter kontrol' USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION _require_reason(p_reason TEXT) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE SET search_path = public, extensions AS $$
DECLARE v TEXT := _clean_text(p_reason, 500, TRUE);
BEGIN
  IF length(v) < 5 THEN RAISE EXCEPTION 'Alasan minimal 5 karakter' USING ERRCODE = '22023'; END IF;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION _clean_email(p_email TEXT, p_required BOOLEAN DEFAULT TRUE) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE SET search_path = public, extensions AS $$
DECLARE v TEXT := lower(_clean_text(p_email, 254, p_required));
BEGIN
  IF v IS NOT NULL AND v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Format email tidak valid' USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;

-- ───────────── Klaim JWT & sesi ─────────────
CREATE OR REPLACE FUNCTION auth_aal() RETURNS TEXT
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT COALESCE(auth.jwt() ->> 'aal', 'aal1')
$$;

-- Waktu autentikasi terakhir (bukan refresh)
CREATE OR REPLACE FUNCTION jwt_auth_time() RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT to_timestamp(max((e ->> 'timestamp')::BIGINT))
  FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) e
  WHERE e ->> 'method' <> 'token_refresh'
$$;

CREATE OR REPLACE FUNCTION mfa_fresh(p_hours INT) RETURNS BOOLEAN
LANGUAGE sql STABLE SET search_path = public, extensions AS $$
  SELECT auth_aal() = 'aal2' AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) e
    WHERE e ->> 'method' = 'totp'
      AND to_timestamp((e ->> 'timestamp')::BIGINT) > NOW() - make_interval(hours => p_hours))
$$;

-- anonymous | missing | unregistered | revoked | reauth_required | ok
CREATE OR REPLACE FUNCTION device_state() RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_hash TEXT := request_device_hash(); v_rev TIMESTAMPTZ; v_found BOOLEAN; v_after TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN RETURN 'anonymous'; END IF;
  IF v_hash IS NULL THEN RETURN 'missing'; END IF;
  SELECT TRUE, revoked_at INTO v_found, v_rev FROM trusted_devices WHERE user_id = v_uid AND device_hash = v_hash;
  IF v_found IS NULL THEN RETURN 'unregistered'; END IF;
  IF v_rev IS NOT NULL THEN RETURN 'revoked'; END IF;
  SELECT GREATEST(p.sessions_valid_after,
                  COALESCE((setting('global_sessions_valid_after') #>> '{}')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ))
    INTO v_after FROM profiles p WHERE p.id = v_uid;
  IF COALESCE(jwt_auth_time(), '-infinity'::TIMESTAMPTZ) < COALESCE(v_after, '-infinity'::TIMESTAMPTZ) THEN
    RETURN 'reauth_required';
  END IF;
  -- Sesi hasil login password (mis. password diset via updateUser oleh pencuri sesi) tidak berlaku di production
  IF NOT _setting_bool('password_login_enabled', FALSE) AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(COALESCE(auth.jwt() -> 'amr', '[]'::jsonb)) e WHERE e ->> 'method' = 'password') THEN
    RETURN 'reauth_required';
  END IF;
  RETURN 'ok';
END $$;

CREATE OR REPLACE FUNCTION device_ok() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT device_state() = 'ok'
$$;

CREATE OR REPLACE FUNCTION _device_hint(p_state TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state WHEN 'reauth_required' THEN 'reauth_required'
                      WHEN 'anonymous' THEN 'unauthenticated'
                      ELSE 'device_' || p_state END       -- device_missing | device_unregistered | device_revoked
$$;

-- ───────────── Identitas pemanggil (hanya akun ACTIVE) ─────────────
CREATE OR REPLACE FUNCTION auth_is_active() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND status = 'active')
$$;
CREATE OR REPLACE FUNCTION auth_contractor_id() RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT contractor_id FROM profiles WHERE id = auth.uid() AND status = 'active'
$$;
CREATE OR REPLACE FUNCTION auth_is_wfrd() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND status = 'active' AND contractor_id IS NULL)
$$;

-- ───────────── Permission ─────────────
-- Grant aktif user untuk satu permission. '*' mencakup semua permission ber-audience wfrd/any.
CREATE OR REPLACE FUNCTION _perm_grants(p_uid UUID, p_perm TEXT)
RETURNS TABLE (scope_type TEXT, scope_id TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT ur.scope_type, ur.scope_id
  FROM user_roles ur
  JOIN profiles p          ON p.id = ur.user_id AND p.status = 'active'
  JOIN role_permissions rp ON rp.role_id = ur.role_id
  WHERE ur.user_id = p_uid
    AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
    AND (rp.permission_key = p_perm
         OR (rp.permission_key = '*' AND EXISTS (SELECT 1 FROM permissions x WHERE x.key = p_perm AND x.audience <> 'contractor')))
$$;

CREATE OR REPLACE FUNCTION has_permission(p_perm TEXT) RETURNS BOOLEAN            -- scope global
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants(auth.uid(), p_perm) g WHERE g.scope_type = 'global')
$$;

CREATE OR REPLACE FUNCTION has_any_permission(p_perm TEXT) RETURNS BOOLEAN        -- scope apa pun (menu/listing)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants(auth.uid(), p_perm))
$$;

CREATE OR REPLACE FUNCTION _uid_has_contract_permission(p_uid UUID, p_perm TEXT, p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM _perm_grants(p_uid, p_perm) g
    LEFT JOIN contracts c ON c.id = p_contract
    WHERE g.scope_type = 'global'
       OR (g.scope_type = 'geozone'    AND g.scope_id = c.geozone)
       OR (g.scope_type = 'contract'   AND g.scope_id = c.id::TEXT)
       OR (g.scope_type = 'contractor' AND g.scope_id = c.contractor_id::TEXT))
$$;

CREATE OR REPLACE FUNCTION has_contract_permission(p_perm TEXT, p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _uid_has_contract_permission(auth.uid(), p_perm, p_contract)
$$;

-- Scope contractor: global · contractor = X · geozone/contract tempat X punya kontrak
CREATE OR REPLACE FUNCTION has_contractor_permission(p_perm TEXT, p_contractor UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM _perm_grants(auth.uid(), p_perm) g
    WHERE g.scope_type = 'global'
       OR (g.scope_type = 'contractor' AND g.scope_id = p_contractor::TEXT)
       OR (g.scope_type = 'geozone'  AND EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND c.geozone = g.scope_id))
       OR (g.scope_type = 'contract' AND EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND c.id::TEXT = g.scope_id)))
$$;

CREATE OR REPLACE FUNCTION _has_geozone_permission(p_perm TEXT, p_geozone TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants(auth.uid(), p_perm) g
                 WHERE g.scope_type = 'global' OR (g.scope_type = 'geozone' AND g.scope_id = p_geozone))
$$;

-- ───────────── Visibilitas objek (dipakai RLS & RPC) ─────────────
CREATE OR REPLACE FUNCTION can_view_contract(p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM contracts c
    WHERE c.id = p_contract AND (
         c.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND (c.process_owner_id = auth.uid() OR c.hse_reviewer_id = auth.uid()
                              OR has_contract_permission('contract.view', c.id)))))
$$;

CREATE OR REPLACE FUNCTION can_view_task(p_task UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task AND (
         t.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND (
             t.reviewer_id = auth.uid() OR t.assigned_to = auth.uid()
          OR (t.contract_id IS NOT NULL AND (has_contract_permission('task.view', t.contract_id)
                                             OR EXISTS (SELECT 1 FROM contracts c WHERE c.id = t.contract_id
                                                        AND auth.uid() IN (c.process_owner_id, c.hse_reviewer_id))))
          OR (t.contract_id IS NULL AND has_contractor_permission('task.view', t.contractor_id))))))
$$;

-- ───────────── MFA, assert_access, step-up ─────────────
CREATE OR REPLACE FUNCTION user_requires_mfa(p_uid UUID DEFAULT auth.uid()) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = p_uid AND is_root_admin)
      OR EXISTS (
        SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = p_uid AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
          AND r.key IN (SELECT jsonb_array_elements_text(COALESCE(setting('mfa_required_roles'), '[]'::jsonb))))
$$;

CREATE OR REPLACE FUNCTION _deny(p_hint TEXT, p_msg TEXT DEFAULT 'Akses ditolak') RETURNS VOID
LANGUAGE plpgsql VOLATILE AS $$
BEGIN RAISE EXCEPTION '%', p_msg USING ERRCODE = '42501', HINT = p_hint; END $$;

CREATE OR REPLACE FUNCTION assert_access(
  p_perm       TEXT,
  p_contract   UUID    DEFAULT NULL,
  p_write      BOOLEAN DEFAULT TRUE,
  p_contractor UUID    DEFAULT NULL,
  p_geozone    TEXT    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := auth.uid(); v_status account_status; v_cid UUID; v_ds TEXT; v_risk TEXT; v_ok BOOLEAN; v_owner UUID;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;

  SELECT status, contractor_id INTO v_status, v_cid FROM profiles WHERE id = v_uid;
  IF v_status IS DISTINCT FROM 'active' THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;

  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;

  IF user_requires_mfa(v_uid) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;

  SELECT risk_level INTO v_risk FROM permissions WHERE key = p_perm;
  IF v_risk IS NULL THEN RAISE EXCEPTION 'Permission tidak dikenal: %', p_perm USING ERRCODE = 'XX000'; END IF;
  IF (v_risk = 'critical' OR p_perm LIKE 'admin.%') AND auth_aal() <> 'aal2' THEN
    PERFORM _deny('mfa_required', 'Aksi ini membutuhkan MFA');
  END IF;

  v_ok := CASE
    WHEN p_contract   IS NOT NULL THEN has_contract_permission(p_perm, p_contract)
    WHEN p_contractor IS NOT NULL THEN has_contractor_permission(p_perm, p_contractor)
    WHEN p_geozone    IS NOT NULL THEN _has_geozone_permission(p_perm, p_geozone)
    ELSE has_permission(p_perm) END;
  IF NOT v_ok THEN PERFORM _deny('forbidden'); END IF;

  IF v_cid IS NOT NULL THEN                                   -- user contractor: objek wajib milik perusahaannya
    IF p_contract IS NOT NULL THEN
      SELECT contractor_id INTO v_owner FROM contracts WHERE id = p_contract;
      IF v_owner IS DISTINCT FROM v_cid THEN PERFORM _deny('forbidden'); END IF;
    END IF;
    IF p_contractor IS NOT NULL AND p_contractor IS DISTINCT FROM v_cid THEN PERFORM _deny('forbidden'); END IF;
  END IF;

  IF p_write AND _setting_bool('read_only_mode', FALSE) AND NOT has_permission('admin.system.danger') THEN
    PERFORM _deny('read_only', 'Sistem dalam mode read-only');
  END IF;
  RETURN v_uid;
END $$;

-- Versi tanpa permission: akun aktif + perangkat ok + MFA role (untuk RPC milik-sendiri: notifikasi, perangkat, chat)
CREATE OR REPLACE FUNCTION assert_session(p_write BOOLEAN DEFAULT TRUE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_ds TEXT;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  IF NOT auth_is_active() THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;
  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;
  IF user_requires_mfa(v_uid) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;
  IF p_write AND _setting_bool('read_only_mode', FALSE) AND NOT has_permission('admin.system.danger') THEN
    PERFORM _deny('read_only', 'Sistem dalam mode read-only');
  END IF;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION assert_step_up() RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NOT mfa_fresh(_setting_int('step_up_hours', 12)) THEN
    PERFORM _deny('step_up_required', 'Masukkan kode MFA untuk melanjutkan');
  END IF;
END $$;

-- ───────────── Rate limit (fixed window) ─────────────
CREATE OR REPLACE FUNCTION hit_rate_limit(p_key TEXT, p_limit INT, p_window INTERVAL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_sec   NUMERIC := EXTRACT(EPOCH FROM p_window);
  v_start TIMESTAMPTZ := to_timestamp(floor(EXTRACT(EPOCH FROM NOW()) / v_sec) * v_sec);
  v_hits  INT;
BEGIN
  INSERT INTO rate_limits (key, window_start, hits, limit_value) VALUES (p_key, v_start, 1, p_limit)
  ON CONFLICT (key, window_start) DO UPDATE SET hits = rate_limits.hits + 1, limit_value = EXCLUDED.limit_value
  RETURNING hits INTO v_hits;
  IF v_hits > p_limit THEN
    RAISE EXCEPTION 'Terlalu banyak permintaan, coba lagi nanti' USING ERRCODE = 'PT429', HINT = 'rate_limited';
  END IF;
END $$;
-- Catatan: RAISE me-rollback increment → baris berhenti di hits = limit_value ("saturasi"), dibaca svc_security_scan.

-- ───────────── Waktu & hari kerja ─────────────
CREATE OR REPLACE FUNCTION _tz(p_geozone TEXT DEFAULT NULL) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT COALESCE((SELECT timezone FROM geozones WHERE code = p_geozone), _setting_text('business_timezone', 'Asia/Jakarta'))
$$;
CREATE OR REPLACE FUNCTION _local_today(p_geozone TEXT DEFAULT NULL) RETURNS DATE
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT (NOW() AT TIME ZONE _tz(p_geozone))::DATE
$$;
-- Versi publik (di-GRANT) untuk view security_invoker & fungsi invoker
CREATE OR REPLACE FUNCTION business_today() RETURNS DATE
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _local_today(NULL)
$$;

CREATE OR REPLACE FUNCTION add_business_days(p_start DATE, p_days INT, p_geozone TEXT DEFAULT NULL) RETURNS DATE
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v DATE := p_start; n INT := 0;
BEGIN
  IF p_days IS NULL OR p_days <= 0 THEN RETURN p_start; END IF;
  WHILE n < p_days LOOP
    v := v + 1;
    IF EXTRACT(ISODOW FROM v) < 6 AND NOT EXISTS (
         SELECT 1 FROM holidays h WHERE h.holiday_date = v AND (h.geozone IS NULL OR h.geozone = p_geozone)) THEN
      n := n + 1;
    END IF;
  END LOOP;
  RETURN v;
END $$;

-- Akhir hari kerja ke-n (00:00 lokal keesokan harinya)
CREATE OR REPLACE FUNCTION _business_deadline(p_days INT, p_geozone TEXT DEFAULT NULL) RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT ((add_business_days(_local_today(p_geozone), p_days, p_geozone) + 1)::TIMESTAMP) AT TIME ZONE _tz(p_geozone)
$$;

-- ───────────── Nomor record (INC/FND/MOM per kontrak) ─────────────
CREATE OR REPLACE FUNCTION _next_record_no(p_prefix TEXT, p_contract UUID) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_seq INT; v_cseq INT;
BEGIN
  SELECT contract_seq INTO v_cseq FROM contracts WHERE id = p_contract;
  INSERT INTO record_sequences (scope_key, kind, current_seq) VALUES (p_contract::TEXT, p_prefix, 1)
  ON CONFLICT (scope_key, kind) DO UPDATE SET current_seq = record_sequences.current_seq + 1
  RETURNING current_seq INTO v_seq;
  IF v_seq > 999 THEN RAISE EXCEPTION 'Nomor % untuk kontrak ini habis', p_prefix USING ERRCODE = '22023'; END IF;
  RETURN p_prefix || '-' || lpad(v_cseq::TEXT, 5, '0') || '-' || lpad(v_seq::TEXT, 3, '0');
END $$;

-- ───────────── Security event & notifikasi ─────────────
CREATE OR REPLACE FUNCTION _security_event(p_user UUID, p_event TEXT, p_severity TEXT DEFAULT 'info', p_detail JSONB DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  INSERT INTO security_events (user_id, event, severity, device_hash, ip_hmac, detail)
  VALUES (p_user, p_event, p_severity, request_device_hash(), request_ip_hmac(), p_detail);
END $$;

CREATE OR REPLACE FUNCTION _rt_send(p_topic TEXT, p_event TEXT, p_payload JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM realtime.send(p_payload, p_event, p_topic, TRUE);          -- private channel
EXCEPTION WHEN OTHERS THEN
  NULL;                                                               -- realtime gagal tidak boleh membatalkan transaksi bisnis
END $$;

-- In-app + realtime + (opsional) email via outbox. Duplikat (dedupe_key) diabaikan.
CREATE OR REPLACE FUNCTION _notify(
  p_user UUID, p_kind TEXT, p_title TEXT, p_body TEXT, p_link TEXT,
  p_severity TEXT DEFAULT 'info', p_template INT DEFAULT NULL, p_params JSONB DEFAULT '{}'::jsonb,
  p_dedupe TEXT DEFAULT NULL, p_send_after TIMESTAMPTZ DEFAULT NOW()
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id BIGINT;
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;
  INSERT INTO notifications (user_id, kind, title, body, link, severity, dedupe_key)
  VALUES (p_user, p_kind, left(p_title, 200), left(p_body, 1000), p_link, p_severity, p_dedupe)
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN; END IF;
  PERFORM _rt_send('user:' || p_user, 'notification', jsonb_build_object('id', v_id));
  IF p_template IS NOT NULL THEN
    INSERT INTO notification_outbox (template_id, to_user, params, dedupe_key, send_after)
    VALUES (p_template, p_user, p_params || jsonb_build_object('title', p_title, 'link', p_link),
            CASE WHEN p_dedupe IS NOT NULL THEN 'mail:' || p_dedupe END, p_send_after)
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
END $$;

-- Email ke alamat eksternal (HSE Manager contractor, mailbox) — tanpa baris in-app
CREATE OR REPLACE FUNCTION _email(p_template INT, p_to TEXT, p_params JSONB, p_dedupe TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF p_to IS NULL THEN RETURN; END IF;
  INSERT INTO notification_outbox (template_id, to_email, params, dedupe_key)
  VALUES (p_template, lower(p_to), p_params, p_dedupe)
  ON CONFLICT (dedupe_key) DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION _users_with_permission(p_perm TEXT, p_contract UUID DEFAULT NULL) RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT DISTINCT p.id FROM profiles p
  WHERE p.status = 'active' AND p.contractor_id IS NULL
    AND CASE WHEN p_contract IS NULL
             THEN EXISTS (SELECT 1 FROM _perm_grants(p.id, p_perm) g WHERE g.scope_type = 'global')
             ELSE _uid_has_contract_permission(p.id, p_perm, p_contract) END
$$;

CREATE OR REPLACE FUNCTION _notify_permission_holders(
  p_perm TEXT, p_contract UUID, p_kind TEXT, p_title TEXT, p_body TEXT, p_link TEXT,
  p_severity TEXT DEFAULT 'info', p_template INT DEFAULT NULL, p_params JSONB DEFAULT '{}'::jsonb, p_dedupe TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID;
BEGIN
  FOR v_uid IN SELECT * FROM _users_with_permission(p_perm, p_contract) LOOP
    PERFORM _notify(v_uid, p_kind, p_title, p_body, p_link, p_severity, p_template, p_params,
                    CASE WHEN p_dedupe IS NOT NULL THEN p_dedupe || ':' || v_uid END);
  END LOOP;
END $$;

-- Semua user aktif sebuah contractor (rep & viewer)
CREATE OR REPLACE FUNCTION _contractor_users(p_contractor UUID) RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT id FROM profiles WHERE contractor_id = p_contractor AND status = 'active'
$$;

CREATE OR REPLACE FUNCTION _notify_contractor(
  p_contractor UUID, p_kind TEXT, p_title TEXT, p_body TEXT, p_link TEXT,
  p_severity TEXT DEFAULT 'info', p_template INT DEFAULT NULL, p_params JSONB DEFAULT '{}'::jsonb, p_dedupe TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID;
BEGIN
  FOR v_uid IN SELECT * FROM _contractor_users(p_contractor) LOOP
    PERFORM _notify(v_uid, p_kind, p_title, p_body, p_link, p_severity, p_template, p_params,
                    CASE WHEN p_dedupe IS NOT NULL THEN p_dedupe || ':' || v_uid END);
  END LOOP;
END $$;
