-- v3.4 · Act As Mode — RPC klien, session state, penyesuaian RPC yang bersinggungan dengan identitas

-- ═════════════ HELPER ═════════════
CREATE OR REPLACE FUNCTION _act_as_json(p_ctx impersonation_contexts) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN p_ctx.id IS NULL THEN NULL ELSE jsonb_build_object(
    'id', p_ctx.id, 'kind', p_ctx.kind,
    'target_user_id', p_ctx.act_as_user_id,
    'target_name', (SELECT COALESCE(full_name, email) FROM profiles WHERE id = p_ctx.act_as_user_id),
    'target_email', (SELECT email FROM profiles WHERE id = p_ctx.act_as_user_id),
    'contractor_id', p_ctx.act_as_contractor_id,
    'contractor_name', (SELECT legal_name FROM contractors WHERE id = p_ctx.act_as_contractor_id),
    'level', p_ctx.act_as_level,
    'role_key', p_ctx.act_as_role_key,
    'role_name', (SELECT name FROM roles WHERE key = p_ctx.act_as_role_key),
    'reason', p_ctx.reason, 'started_at', p_ctx.created_at, 'expires_at', p_ctx.expires_at,
    'hard_expires_at', p_ctx.hard_expires_at, 'refresh_count', p_ctx.refresh_count, 'server_now', NOW()) END
$$;

CREATE OR REPLACE FUNCTION _act_as_new_token() RETURNS TEXT
LANGUAGE sql VOLATILE SET search_path = public, extensions AS $$
  SELECT translate(encode(gen_random_bytes(32), 'base64'), '+/=', '-_')
$$;

CREATE OR REPLACE FUNCTION _act_as_assert_starter(p_uid UUID) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Act As membutuhkan sesi MFA (aal2)'); END IF;
  IF NOT _can_act_as(p_uid) THEN PERFORM _deny('forbidden', 'Act As hanya untuk Super Admin'); END IF;
END $$;

-- ═════════════ RPC ACT AS ═════════════
-- Tepat satu dari p_target_user (mode user) / p_role_key (mode role template). Konteks lama aktor otomatis ditutup.
CREATE OR REPLACE FUNCTION act_as_start(p_target_user UUID DEFAULT NULL, p_role_key TEXT DEFAULT NULL, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_real UUID := _assert_real_session(); v_reason TEXT; v_t profiles; v_lvl contractor_user_level; v_tok TEXT;
  v_ctx impersonation_contexts; r RECORD;
BEGIN
  PERFORM _act_as_assert_starter(v_real);
  PERFORM assert_step_up();
  v_reason := _require_reason(p_reason);
  IF (p_target_user IS NULL) = (NULLIF(p_role_key, '') IS NULL) THEN
    RAISE EXCEPTION 'Pilih tepat satu: user target atau role template' USING ERRCODE = '22023';
  END IF;
  PERFORM hit_rate_limit('act_as:' || v_real, 30, INTERVAL '1 hour');

  IF p_target_user IS NOT NULL THEN
    IF p_target_user = v_real THEN RAISE EXCEPTION 'Tidak bisa Act As sebagai diri sendiri' USING ERRCODE = '22023'; END IF;
    SELECT * INTO v_t FROM profiles WHERE id = p_target_user;
    IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
    IF v_t.is_root_admin OR EXISTS (SELECT 1 FROM user_roles ur JOIN roles x ON x.id = ur.role_id
                                    WHERE ur.user_id = v_t.id AND x.key IN ('super_admin','hse_admin')
                                      AND (ur.expires_at IS NULL OR ur.expires_at > NOW())) THEN
      PERFORM _deny('forbidden', 'Tidak bisa Act As sebagai admin (super admin / HSE admin)');
    END IF;
    IF v_t.status <> 'active' OR v_t.anonymized_at IS NOT NULL THEN
      RAISE EXCEPTION 'Hanya user berstatus aktif yang bisa di-Act As (status: %)', v_t.status USING ERRCODE = '22023';
    END IF;
    v_lvl := _contractor_level_of(v_t.id);
  ELSIF NOT _act_as_role_allowed(p_role_key) OR NOT EXISTS (SELECT 1 FROM roles WHERE key = p_role_key) THEN
    RAISE EXCEPTION 'Role template tidak diizinkan untuk Act As' USING ERRCODE = '22023';
  END IF;

  FOR r IN UPDATE impersonation_contexts
           SET closed_at = NOW(), close_reason = CASE WHEN expires_at <= NOW() THEN 'expired' ELSE 'replaced' END
           WHERE real_actor_id = v_real AND closed_at IS NULL
           RETURNING id, close_reason LOOP
    INSERT INTO impersonation_events (context_id, real_actor_id, event, detail)
    VALUES (r.id, v_real, 'closed', jsonb_build_object('reason', r.close_reason));
  END LOOP;

  v_tok := _act_as_new_token();
  INSERT INTO impersonation_contexts (token_hash, real_actor_id, kind, act_as_user_id, act_as_role_key, act_as_contractor_id, act_as_level,
                                      reason, session_id, device_hash, expires_at, hard_expires_at)
  VALUES (encode(digest(v_tok, 'sha256'), 'hex'), v_real, CASE WHEN p_target_user IS NOT NULL THEN 'user' ELSE 'role' END,
          p_target_user, CASE WHEN p_target_user IS NULL THEN p_role_key END, v_t.contractor_id, v_lvl, v_reason,
          NULLIF(auth.jwt() ->> 'session_id', '')::UUID, request_device_hash(),
          NOW() + INTERVAL '15 minutes', NOW() + INTERVAL '2 hours')
  RETURNING * INTO v_ctx;
  INSERT INTO impersonation_events (context_id, real_actor_id, event, detail)
  VALUES (v_ctx.id, v_real, 'started', jsonb_build_object('kind', v_ctx.kind, 'target', p_target_user, 'role', v_ctx.act_as_role_key));
  PERFORM _security_event(v_real, 'act_as_start', 'warning', jsonb_build_object(
    'context', v_ctx.id, 'kind', v_ctx.kind, 'target', p_target_user, 'role', v_ctx.act_as_role_key, 'reason', v_reason));
  PERFORM set_config('comen.act_as_cache', '', TRUE);
  RETURN jsonb_build_object('token', v_tok, 'context', _act_as_json(v_ctx));
END $$;

-- Perpanjang 15 menit (maks. 2 jam sejak mulai) + rotasi token; token lama berlaku 60 detik untuk request yang sedang berjalan
CREATE OR REPLACE FUNCTION act_as_refresh() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_real UUID := _assert_real_session(); v_ctx impersonation_contexts := _act_as_ctx(); v_tok TEXT;
BEGIN
  IF v_ctx.id IS NULL THEN PERFORM _deny('act_as_invalid', 'Tidak sedang dalam mode Act As'); END IF;
  PERFORM _act_as_assert_starter(v_real);
  IF v_ctx.expires_at >= v_ctx.hard_expires_at THEN
    RAISE EXCEPTION 'Batas maksimal sesi Act As (2 jam) tercapai. Mulai sesi baru.' USING ERRCODE = '22023';
  END IF;
  PERFORM hit_rate_limit('act_as_refresh:' || v_real, 60, INTERVAL '1 hour');
  v_tok := _act_as_new_token();
  UPDATE impersonation_contexts
  SET prev_token_hash = token_hash, prev_valid_until = NOW() + INTERVAL '60 seconds',
      token_hash = encode(digest(v_tok, 'sha256'), 'hex'),
      expires_at = LEAST(NOW() + INTERVAL '15 minutes', hard_expires_at),
      last_refreshed_at = NOW(), refresh_count = refresh_count + 1
  WHERE id = v_ctx.id AND closed_at IS NULL
  RETURNING * INTO v_ctx;
  IF v_ctx.id IS NULL THEN PERFORM _deny('act_as_closed', 'Sesi Act As sudah ditutup'); END IF;
  INSERT INTO impersonation_events (context_id, real_actor_id, event, detail)
  VALUES (v_ctx.id, v_real, 'refreshed', jsonb_build_object('expires_at', v_ctx.expires_at, 'n', v_ctx.refresh_count));
  PERFORM set_config('comen.act_as_cache', '', TRUE);
  RETURN jsonb_build_object('token', v_tok, 'context', _act_as_json(v_ctx));
END $$;

-- Tutup semua konteks terbuka milik aktor nyata (exit, logout, kedaluwarsa). Tetap jalan walau token sudah tidak valid.
CREATE OR REPLACE FUNCTION act_as_close(p_reason TEXT DEFAULT 'user_exit') RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_real UUID := auth.uid(); v_reason TEXT; v_n INT := 0; r RECORD;
BEGIN
  IF v_real IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_reason := CASE WHEN p_reason IN ('user_exit','logout','expired','lost') THEN p_reason ELSE 'user_exit' END;
  FOR r IN UPDATE impersonation_contexts
           SET closed_at = NOW(), close_reason = CASE WHEN expires_at <= NOW() THEN 'expired' ELSE v_reason END
           WHERE real_actor_id = v_real AND closed_at IS NULL
           RETURNING id, kind, act_as_user_id, act_as_role_key, close_reason, created_at LOOP
    INSERT INTO impersonation_events (context_id, real_actor_id, event, detail)
    VALUES (r.id, v_real, 'closed', jsonb_build_object('reason', r.close_reason));
    PERFORM _security_event(v_real, 'act_as_end', 'info', jsonb_build_object(
      'context', r.id, 'kind', r.kind, 'target', r.act_as_user_id, 'role', r.act_as_role_key, 'reason', r.close_reason,
      'duration_s', extract(epoch FROM NOW() - r.created_at)::INT));
    v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('comen.act_as_cache', '', TRUE);
  RETURN v_n;
END $$;

-- Konteks terbuka aktor nyata (tanpa membaca header) — untuk UI & pemulihan
CREATE OR REPLACE FUNCTION act_as_status() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_real UUID := _assert_real_session(); v_ctx impersonation_contexts;
BEGIN
  SELECT * INTO v_ctx FROM impersonation_contexts
  WHERE real_actor_id = v_real AND closed_at IS NULL AND expires_at > NOW();
  RETURN jsonb_build_object('can_act_as', _can_act_as(v_real) AND auth_aal() = 'aal2', 'active', _act_as_json(v_ctx));
END $$;

-- Daftar target: template role WFRD + user aktif non-admin, plus riwayat terakhir
CREATE OR REPLACE FUNCTION act_as_list_targets(p_query TEXT DEFAULT NULL, p_limit INT DEFAULT 50) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_real UUID := _assert_real_session(); v_q TEXT := NULLIF(_clean_text(p_query, 100), '');
BEGIN
  PERFORM _act_as_assert_starter(v_real);
  RETURN jsonb_build_object(
    'roles', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('key', r.key, 'name', r.name, 'description', r.description,
                                          'permission_count', (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id))
                       ORDER BY array_position(ARRAY['process_owner','hse_reviewer','procurement','auditor','hse_director','viewer'], r.key))
      FROM roles r WHERE _act_as_role_allowed(r.key)
        AND (v_q IS NULL OR r.name ILIKE '%' || v_q || '%' OR r.key ILIKE '%' || v_q || '%')), '[]'::jsonb),
    'users', COALESCE((
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x.is_wfrd, x.contractor_name NULLS LAST, x.full_name) FROM (
        SELECT p.id, COALESCE(p.full_name, p.email) AS full_name, p.email, p.contractor_id, c.legal_name AS contractor_name,
               p.contractor_id IS NULL AS is_wfrd, _contractor_level_of(p.id) AS level,
               (SELECT jsonb_agg(DISTINCT r.name) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE ur.user_id = p.id AND (ur.expires_at IS NULL OR ur.expires_at > NOW())) AS roles
        FROM profiles p LEFT JOIN contractors c ON c.id = p.contractor_id
        WHERE _act_as_target_ok(p.id, v_real)
          AND (v_q IS NULL OR p.full_name ILIKE '%' || v_q || '%' OR p.email ILIKE '%' || v_q || '%' OR c.legal_name ILIKE '%' || v_q || '%')
        ORDER BY p.contractor_id IS NULL, c.legal_name NULLS LAST, p.full_name
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) x), '[]'::jsonb),
    'recent', COALESCE((
      SELECT jsonb_agg(to_jsonb(y) ORDER BY y.last_at DESC) FROM (
        SELECT k.kind, k.act_as_user_id AS target_user_id, k.act_as_role_key AS role_key,
               (SELECT COALESCE(full_name, email) FROM profiles WHERE id = k.act_as_user_id) AS target_name,
               (SELECT name FROM roles WHERE key = k.act_as_role_key) AS role_name,
               max(k.created_at) AS last_at
        FROM impersonation_contexts k
        WHERE k.real_actor_id = v_real AND k.created_at > NOW() - INTERVAL '30 days'
          AND (k.kind = 'role' OR _act_as_target_ok(k.act_as_user_id, v_real))
        GROUP BY k.kind, k.act_as_user_id, k.act_as_role_key
        ORDER BY max(k.created_at) DESC LIMIT 5) y), '[]'::jsonb));
END $$;

-- ═════════════ SESSION STATE ═════════════
-- Identitas tampilan/otorisasi = efektif; perangkat, MFA, inbox notifikasi = aktor nyata.
CREATE OR REPLACE FUNCTION my_session_state() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_real UUID := auth.uid(); v_ctx impersonation_contexts; v_uid UUID; v_p profiles; v_rp profiles; v_c contractors;
  v_active BOOLEAN; v_lvl contractor_user_level; v_contracts JSONB; v_roles JSONB;
BEGIN
  IF v_real IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_ctx := _act_as_ctx();
  v_uid := CASE WHEN v_ctx.kind = 'user' THEN v_ctx.act_as_user_id ELSE v_real END;
  SELECT * INTO v_rp FROM profiles WHERE id = v_real;
  IF NOT FOUND THEN PERFORM _deny('account_inactive', 'Profil belum tersedia'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  SELECT * INTO v_c FROM contractors WHERE id = v_p.contractor_id;
  v_active := v_p.status = 'active';
  v_lvl := _contractor_level_of(v_uid);
  v_contracts := CASE WHEN v_active AND v_p.contractor_id IS NOT NULL THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', k.id, 'contract_no', k.contract_no, 'title', k.title, 'status', k.status,
                                          'contract_mode', k.contract_mode, 'duration_category', k.duration_category,
                                          'access_tier', k.access_tier) ORDER BY k.contract_no DESC)
      FROM contracts k WHERE k.contractor_id = v_p.contractor_id AND k.status NOT IN ('closed','terminated')), '[]'::jsonb)
    ELSE '[]'::jsonb END;
  v_roles := CASE
    WHEN NOT v_active THEN '[]'::jsonb
    WHEN v_ctx.kind = 'role' THEN (
      SELECT jsonb_build_array(jsonb_build_object('id', NULL, 'key', r.key, 'name', r.name, 'scope_type', 'global',
                                                  'scope_id', NULL, 'expires_at', v_ctx.expires_at))
      FROM roles r WHERE r.key = v_ctx.act_as_role_key)
    ELSE COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', ur.id, 'key', r.key, 'name', r.name, 'scope_type', ur.scope_type,
                                          'scope_id', ur.scope_id, 'expires_at', ur.expires_at) ORDER BY r.key)
      FROM user_roles ur JOIN roles r ON r.id = ur.role_id
      WHERE ur.user_id = v_uid AND (ur.expires_at IS NULL OR ur.expires_at > NOW())), '[]'::jsonb) END;
  RETURN jsonb_build_object(
    'user_id', v_p.id, 'email', v_p.email, 'full_name', v_p.full_name, 'avatar_url', v_p.avatar_url,
    'status', v_p.status, 'status_reason', v_p.status_reason, 'is_root_admin', v_p.is_root_admin AND v_ctx.id IS NULL,
    'is_wfrd', v_active AND v_p.contractor_id IS NULL,
    'contractor_id', v_p.contractor_id, 'contractor_name', v_c.legal_name, 'vendor_status', v_c.status,
    'registration_submitted', v_c.submitted_at IS NOT NULL, 'locale', v_p.locale,
    'contractor_level', v_lvl,
    'active_contracts', v_contracts,
    'roles', v_roles,
    'permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key))
          AND (v_lvl IS NULL OR _perm_min_level(pm.key) IS NULL OR _level_rank(v_lvl) >= _level_rank(_perm_min_level(pm.key)))), '[]'::jsonb)
        ELSE '[]'::jsonb END,
    'global_permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key) g WHERE g.scope_type = 'global')
          AND (v_lvl IS NULL OR _perm_min_level(pm.key) IS NULL OR _level_rank(v_lvl) >= _level_rank(_perm_min_level(pm.key)))), '[]'::jsonb)
        ELSE '[]'::jsonb END,
    'mfa_required', user_requires_mfa(v_real),
    'mfa_enrolled', EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = v_real AND f.status = 'verified' AND f.factor_type = 'totp'),
    'aal', auth_aal(),
    'step_up_fresh', mfa_fresh(_setting_int('step_up_hours', 12)),
    'device_state', device_state(),
    'read_only_mode', _setting_bool('read_only_mode', FALSE),
    'email_otp_enabled', _setting_bool('email_otp_enabled', TRUE),
    'unread_notifications', (SELECT count(*) FROM notifications WHERE user_id = v_real AND read_at IS NULL),
    'real_user_id', v_real, 'real_email', v_rp.email, 'real_full_name', v_rp.full_name,
    'real_is_root_admin', v_rp.is_root_admin,
    'can_act_as', _can_act_as(v_real),
    'act_as', _act_as_json(v_ctx)
  );
END $$;

-- ═════════════ RPC YANG BERSINGGUNGAN DENGAN IDENTITAS ═════════════
-- Inbox notifikasi selalu milik aktor nyata (RLS notifications memakai auth.uid())
CREATE OR REPLACE FUNCTION mark_notifications_read(p_ids BIGINT[] DEFAULT NULL) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_n INT;
BEGIN
  PERFORM assert_session(FALSE);
  UPDATE notifications SET read_at = NOW()
  WHERE user_id = auth.uid() AND read_at IS NULL AND (p_ids IS NULL OR id = ANY(p_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION update_my_profile(p_full_name TEXT, p_job_title TEXT, p_phone TEXT, p_locale TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE); v_ver SMALLINT := _active_key_ver('data');
BEGIN
  PERFORM _assert_not_acting('Mengubah profil');
  IF p_locale NOT IN ('id','en') THEN RAISE EXCEPTION 'Bahasa tidak didukung' USING ERRCODE = '22023'; END IF;
  IF p_phone IS NOT NULL AND p_phone !~ '^\+?[0-9 ()-]{6,20}$' THEN RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE profiles SET full_name = _clean_text(p_full_name, 120, TRUE), job_title = _clean_text(p_job_title, 120),
                      phone_enc = _encrypt(_clean_text(p_phone, 20), 'data', v_ver), enc_key_ver = v_ver,
                      locale = p_locale, updated_at = NOW()
  WHERE id = v_uid;
END $$;

CREATE OR REPLACE FUNCTION list_my_devices() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_hash TEXT := request_device_hash();
BEGIN
  PERFORM _assert_not_acting('Daftar perangkat');
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'first_seen', d.first_seen, 'last_seen', d.last_seen,
                       'revoked_at', d.revoked_at, 'revoke_reason', d.revoke_reason, 'is_current', d.device_hash = v_hash,
                       'push_enabled', EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.device_id = d.id))
                     ORDER BY d.revoked_at NULLS FIRST, d.last_seen DESC)
    FROM trusted_devices d WHERE d.user_id = v_uid), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION _assert_admin_mode() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  PERFORM _assert_not_acting('Admin Console');
  IF auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Admin Mode membutuhkan MFA'); END IF;
  IF NOT EXISTS (SELECT 1 FROM permissions WHERE key LIKE 'admin.%' AND has_permission(key)) THEN PERFORM _deny('forbidden'); END IF;
  RETURN v_uid;
END $$;

-- Read receipt target tidak bergeser saat admin sekadar membaca chat lewat Act As
CREATE OR REPLACE FUNCTION mark_read(p_channel UUID, p_seq BIGINT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
BEGIN
  IF _act_as_user() IS NOT NULL THEN RETURN; END IF;
  UPDATE chat_members SET last_read_seq = GREATEST(last_read_seq, LEAST(p_seq, (SELECT COALESCE(max(seq), 0) FROM chat_messages WHERE channel_id = p_channel)))
  WHERE channel_id = p_channel AND user_id = v_uid;
  PERFORM _rt_send('user:' || v_uid, 'chat_read', jsonb_build_object('channel', p_channel, 'seq', p_seq));
END $$;

-- via_act_as terlihat semua anggota (transparansi); nama aktor hanya untuk WFRD
CREATE OR REPLACE FUNCTION get_messages(p_channel UUID, p_before_seq BIGINT DEFAULT NULL, p_limit INT DEFAULT 50, p_thread_root UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE); v_wfrd BOOLEAN := auth_is_wfrd();
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'seq')::BIGINT DESC), '[]'::jsonb) FROM (
    SELECT jsonb_build_object(
      'id', m.id, 'seq', m.seq, 'sender_id', m.sender_id, 'kind', m.kind, 'priority', m.priority, 'requires_ack', m.requires_ack,
      'body', CASE WHEN m.deleted_at IS NULL THEN _decrypt(m.body_enc, 'chat', m.key_ver) END,
      'deleted', m.deleted_at IS NOT NULL, 'edited_at', m.edited_at, 'created_at', m.created_at,
      'reply_to', m.reply_to, 'thread_root', m.thread_root, 'mentions', to_jsonb(m.mentions), 'task_refs', to_jsonb(m.task_refs),
      'reply_count', (SELECT count(*) FROM chat_messages r WHERE r.thread_root = m.id AND r.deleted_at IS NULL),
      'reactions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('emoji', emoji, 'count', n, 'mine', mine)), '[]'::jsonb) FROM (
                      SELECT emoji, count(*) n, bool_or(user_id = v_uid) mine FROM chat_reactions WHERE message_id = m.id GROUP BY emoji) rx),
      'acked_by_me', EXISTS (SELECT 1 FROM chat_acks a WHERE a.message_id = m.id AND a.user_id = v_uid),
      'pinned', EXISTS (SELECT 1 FROM chat_pins pn WHERE pn.message_id = m.id),
      'saved', EXISTS (SELECT 1 FROM chat_saved s WHERE s.message_id = m.id AND s.user_id = v_uid),
      'via_act_as', m.act_as_actor_id IS NOT NULL,
      'via_act_as_name', CASE WHEN m.act_as_actor_id IS NOT NULL AND v_wfrd
                              THEN (SELECT COALESCE(full_name, email) FROM profiles WHERE id = m.act_as_actor_id) END) AS x
    FROM chat_messages m
    WHERE m.channel_id = p_channel
      AND (p_before_seq IS NULL OR m.seq < p_before_seq)
      AND CASE WHEN p_thread_root IS NULL THEN m.thread_root IS NULL ELSE (m.thread_root = p_thread_root OR m.id = p_thread_root) END
    ORDER BY m.seq DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 100)) q);
END $$;

-- Audit search: tampilkan identitas Act As (return type berubah → DROP + CREATE)
DROP FUNCTION IF EXISTS admin_audit_search(TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, BIGINT, INT);
CREATE FUNCTION admin_audit_search(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_actor UUID DEFAULT NULL, p_table TEXT DEFAULT NULL,
                                   p_action TEXT DEFAULT NULL, p_record TEXT DEFAULT NULL, p_before_id BIGINT DEFAULT NULL,
                                   p_limit INT DEFAULT 100)
RETURNS TABLE(id BIGINT, created_at TIMESTAMPTZ, table_name TEXT, record_id TEXT, action TEXT, actor_id UUID, actor_email TEXT,
              old_data JSONB, new_data JSONB, row_hash TEXT, act_as_context_id UUID, act_as_user_id UUID, act_as_user_email TEXT,
              act_as_role_key TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_access('admin.audit.view', NULL, FALSE);
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to - p_from > INTERVAL '366 days' THEN
    RAISE EXCEPTION 'Rentang waktu wajib (maks 366 hari)' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT a.id, a.created_at, a.table_name, a.record_id, a.action, a.actor_id, p.email, a.old_data, a.new_data, a.row_hash,
         a.act_as_context_id, a.act_as_user_id, t.email, a.act_as_role_key
  FROM audit_logs a LEFT JOIN profiles p ON p.id = a.actor_id LEFT JOIN profiles t ON t.id = a.act_as_user_id
  WHERE a.created_at >= p_from AND a.created_at < p_to
    AND (p_actor IS NULL OR a.actor_id = p_actor OR a.act_as_user_id = p_actor) AND (p_table IS NULL OR a.table_name = p_table)
    AND (p_action IS NULL OR a.action = p_action) AND (p_record IS NULL OR a.record_id = p_record)
    AND (p_before_id IS NULL OR a.id < p_before_id)
  ORDER BY a.id DESC
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
END $$;

-- ═════════════ JOB ═════════════
CREATE OR REPLACE FUNCTION svc_act_as_sweep() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_n INT := 0; r RECORD;
BEGIN
  FOR r IN UPDATE impersonation_contexts SET closed_at = NOW(), close_reason = 'expired'
           WHERE closed_at IS NULL AND expires_at <= NOW()
           RETURNING id, real_actor_id LOOP
    INSERT INTO impersonation_events (context_id, real_actor_id, event, detail) VALUES (r.id, r.real_actor_id, 'closed', '{"reason":"expired"}');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
SELECT cron.schedule('comen-act-as-sweep', '*/5 * * * *', $$SELECT public.svc_act_as_sweep()$$);

-- ═════════════ PRIVILEGE ═════════════
REVOKE ALL ON FUNCTION _act_as_json(impersonation_contexts), _act_as_new_token(), _act_as_assert_starter(UUID), svc_act_as_sweep()
FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION act_as_start(UUID, TEXT, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION act_as_start(UUID, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION act_as_refresh() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION act_as_refresh() TO authenticated;
REVOKE ALL ON FUNCTION act_as_close(TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION act_as_close(TEXT) TO authenticated;
REVOKE ALL ON FUNCTION act_as_status() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION act_as_status() TO authenticated;
REVOKE ALL ON FUNCTION act_as_list_targets(TEXT, INT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION act_as_list_targets(TEXT, INT) TO authenticated;
REVOKE ALL ON FUNCTION admin_audit_search(TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, BIGINT, INT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION admin_audit_search(TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, BIGINT, INT) TO authenticated;
