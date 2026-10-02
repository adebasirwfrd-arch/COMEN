-- v3.4 · Act As Mode (addition 2.md, R37–R45)
-- Super admin (aal2) bisa bertindak sebagai user target (mode 'user') atau memakai template role WFRD (mode 'role').
-- Prinsip:
--   • Identitas NYATA (auth.uid())  → perangkat, sesi, MFA, inbox notifikasi, actor audit.
--   • Identitas EFEKTIF (_eff_uid()) → otorisasi, kepemilikan data, RLS.
-- Konteks dibawa header `x-comen-act-as` (token acak 256-bit; DB hanya menyimpan SHA-256). Header tidak valid → 42501 (fail-closed),
-- tidak pernah diam-diam jatuh kembali ke identitas super admin.

-- ═════════════ TABEL ═════════════
CREATE TABLE IF NOT EXISTS impersonation_contexts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash           TEXT NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  prev_token_hash      TEXT CHECK (prev_token_hash ~ '^[a-f0-9]{64}$'),
  prev_valid_until     TIMESTAMPTZ,
  real_actor_id        UUID NOT NULL REFERENCES profiles(id),
  kind                 TEXT NOT NULL CHECK (kind IN ('user','role')),
  act_as_user_id       UUID REFERENCES profiles(id),
  act_as_role_key      TEXT,
  act_as_contractor_id UUID REFERENCES contractors(id),
  act_as_level         contractor_user_level,
  reason               TEXT NOT NULL CHECK (char_length(reason) BETWEEN 5 AND 500),
  session_id           UUID,
  device_hash          TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at           TIMESTAMPTZ NOT NULL,
  hard_expires_at      TIMESTAMPTZ NOT NULL,
  last_refreshed_at    TIMESTAMPTZ,
  refresh_count        INT NOT NULL DEFAULT 0,
  closed_at            TIMESTAMPTZ,
  close_reason         TEXT CHECK (close_reason IN ('user_exit','logout','expired','replaced','lost')),
  CHECK ((kind = 'user' AND act_as_user_id IS NOT NULL AND act_as_role_key IS NULL)
      OR (kind = 'role' AND act_as_user_id IS NULL AND act_as_role_key IS NOT NULL)),
  CHECK (act_as_user_id IS DISTINCT FROM real_actor_id),
  CHECK (expires_at <= hard_expires_at AND hard_expires_at <= created_at + INTERVAL '2 hours'),
  CHECK ((closed_at IS NULL) = (close_reason IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_impersonation_open ON impersonation_contexts(real_actor_id) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_impersonation_prev ON impersonation_contexts(prev_token_hash) WHERE prev_token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_impersonation_actor ON impersonation_contexts(real_actor_id, created_at DESC);
ALTER TABLE impersonation_contexts ENABLE ROW LEVEL SECURITY;            -- tanpa policy: hanya via RPC

CREATE TABLE IF NOT EXISTS impersonation_events (
  id            BIGSERIAL PRIMARY KEY,
  context_id    UUID NOT NULL REFERENCES impersonation_contexts(id),
  real_actor_id UUID NOT NULL REFERENCES profiles(id),
  event         TEXT NOT NULL CHECK (event IN ('started','refreshed','closed')),
  detail        JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_impersonation_events_ctx ON impersonation_events(context_id, created_at);
ALTER TABLE impersonation_events ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS trg_append_only ON impersonation_events;
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON impersonation_events FOR EACH ROW EXECUTE FUNCTION _append_only();

REVOKE ALL ON impersonation_contexts, impersonation_events FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE impersonation_events_id_seq FROM PUBLIC, anon, authenticated, service_role;

-- Audit (R40): actor_id tetap aktor nyata; kolom act_as_* = identitas yang dipakai
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS act_as_context_id UUID;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS act_as_user_id UUID;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS act_as_role_key TEXT;

-- ═════════════ HELPER KONTEKS ═════════════
CREATE OR REPLACE FUNCTION _act_as_role_allowed(p_key TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT p_key IN ('process_owner','hse_reviewer','procurement','auditor','hse_director','viewer')
$$;

-- Permission yang TIDAK PERNAH berlaku saat Act As (R41): seluruh Admin Console + wildcard
CREATE OR REPLACE FUNCTION _act_as_perm_blocked(p_perm TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT p_perm = '*' OR p_perm LIKE 'admin.%' OR p_perm = 'level.pic.set'
$$;

-- Super admin nyata yang boleh memulai Act As (query langsung: tidak lewat helper yang sadar-Act-As)
CREATE OR REPLACE FUNCTION _can_act_as(p_uid UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles p JOIN user_roles ur ON ur.user_id = p.id JOIN roles r ON r.id = ur.role_id
    WHERE p.id = p_uid AND p.status = 'active' AND p.is_root_admin AND p.anonymized_at IS NULL
      AND r.key = 'super_admin' AND ur.scope_type = 'global' AND (ur.expires_at IS NULL OR ur.expires_at > NOW()))
$$;

-- Target user yang sah: aktif, bukan root/super admin, bukan aktor sendiri (R39)
CREATE OR REPLACE FUNCTION _act_as_target_ok(p_target UUID, p_real UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_target IS DISTINCT FROM p_real AND EXISTS (
    SELECT 1 FROM profiles p WHERE p.id = p_target AND p.status = 'active' AND NOT p.is_root_admin AND p.anonymized_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                      WHERE ur.user_id = p.id AND r.key IN ('super_admin','hse_admin')
                        AND (ur.expires_at IS NULL OR ur.expires_at > NOW())))
$$;

-- Validasi header TANPA raise: o_reason NULL + o_ctx NULL = tidak sedang Act As.
-- Tidak boleh memanggil helper yang sadar-Act-As (auth_is_*, has_*, _perm_grants, _user_has_role) → rekursi.
CREATE OR REPLACE FUNCTION _act_as_check(OUT o_ctx impersonation_contexts, OUT o_reason TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_tok TEXT := request_header('x-comen-act-as'); v_hash TEXT; v_cache TEXT; v_sid UUID;
BEGIN
  IF v_tok IS NULL OR v_tok = '' THEN RETURN; END IF;
  IF v_tok !~ '^[A-Za-z0-9_-]{43}$' THEN o_reason := 'act_as_invalid'; RETURN; END IF;
  v_hash := encode(digest(v_tok, 'sha256'), 'hex');

  -- Cache per-transaksi: RLS memanggil helper per baris
  v_cache := current_setting('comen.act_as_cache', TRUE);
  IF v_cache IS NOT NULL AND length(v_cache) > 65 AND left(v_cache, 64) = v_hash THEN
    o_ctx := jsonb_populate_record(NULL::impersonation_contexts, substr(v_cache, 66)::jsonb);
    IF o_ctx.real_actor_id = auth.uid() THEN RETURN; END IF;
    o_ctx := NULL;
  END IF;

  SELECT * INTO o_ctx FROM impersonation_contexts c
  WHERE c.token_hash = v_hash OR (c.prev_token_hash = v_hash AND c.prev_valid_until > NOW())
  LIMIT 1;
  IF o_ctx.id IS NULL OR o_ctx.real_actor_id IS DISTINCT FROM auth.uid() THEN o_ctx := NULL; o_reason := 'act_as_invalid'; RETURN; END IF;
  IF o_ctx.closed_at IS NOT NULL THEN o_ctx := NULL; o_reason := 'act_as_closed'; RETURN; END IF;
  IF o_ctx.expires_at <= NOW() THEN o_ctx := NULL; o_reason := 'act_as_expired'; RETURN; END IF;
  v_sid := NULLIF(auth.jwt() ->> 'session_id', '')::UUID;
  IF (o_ctx.session_id IS NOT NULL AND o_ctx.session_id IS DISTINCT FROM v_sid)
     OR (o_ctx.device_hash IS NOT NULL AND o_ctx.device_hash IS DISTINCT FROM request_device_hash()) THEN
    o_ctx := NULL; o_reason := 'act_as_invalid'; RETURN;                -- token terikat sesi & perangkat asal
  END IF;
  IF auth_aal() <> 'aal2' THEN o_ctx := NULL; o_reason := 'act_as_mfa'; RETURN; END IF;
  IF NOT _can_act_as(o_ctx.real_actor_id) THEN o_ctx := NULL; o_reason := 'act_as_forbidden'; RETURN; END IF;
  IF o_ctx.kind = 'user' AND NOT _act_as_target_ok(o_ctx.act_as_user_id, o_ctx.real_actor_id) THEN
    o_ctx := NULL; o_reason := 'act_as_target_invalid'; RETURN;
  END IF;
  IF o_ctx.kind = 'role' AND NOT (_act_as_role_allowed(o_ctx.act_as_role_key)
                                  AND EXISTS (SELECT 1 FROM roles WHERE key = o_ctx.act_as_role_key)) THEN
    o_ctx := NULL; o_reason := 'act_as_target_invalid'; RETURN;
  END IF;
  PERFORM set_config('comen.act_as_cache', v_hash || '|' || to_jsonb(o_ctx)::TEXT, TRUE);
END $$;

-- Versi fail-closed untuk jalur otorisasi
CREATE OR REPLACE FUNCTION _act_as_ctx() RETURNS impersonation_contexts
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD;
BEGIN
  IF COALESCE(request_header('x-comen-act-as'), '') = '' THEN RETURN NULL; END IF;
  SELECT * INTO r FROM _act_as_check();
  IF r.o_reason IS NOT NULL THEN
    PERFORM _deny(r.o_reason, CASE r.o_reason
      WHEN 'act_as_expired'        THEN 'Sesi Act As kedaluwarsa'
      WHEN 'act_as_closed'         THEN 'Sesi Act As sudah ditutup'
      WHEN 'act_as_target_invalid' THEN 'Target Act As tidak lagi valid (status/role berubah)'
      WHEN 'act_as_forbidden'      THEN 'Akun Anda tidak lagi berhak memakai Act As'
      WHEN 'act_as_mfa'            THEN 'Act As membutuhkan sesi MFA (aal2)'
      ELSE 'Sesi Act As tidak valid' END);
  END IF;
  RETURN r.o_ctx;
END $$;

CREATE OR REPLACE FUNCTION _eff_uid() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts := _act_as_ctx();
BEGIN
  RETURN CASE WHEN v.kind = 'user' THEN v.act_as_user_id ELSE auth.uid() END;
END $$;

CREATE OR REPLACE FUNCTION _act_as_active() RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN RETURN (_act_as_ctx()).id IS NOT NULL; END $$;

-- Target mode 'user' (NULL bila tidak Act As / mode role)
CREATE OR REPLACE FUNCTION _act_as_user() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts := _act_as_ctx();
BEGIN RETURN CASE WHEN v.kind = 'user' THEN v.act_as_user_id END; END $$;

CREATE OR REPLACE FUNCTION _assert_not_acting(p_what TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF _act_as_active() THEN
    PERFORM _deny('act_as_blocked', COALESCE(p_what, 'Aksi ini') || ' tidak tersedia saat mode Act As. Keluar dari Act As terlebih dahulu.');
  END IF;
END $$;

-- Sesi nyata (tanpa membaca header Act As) — dipakai RPC act_as_* agar tetap jalan walau token kedaluwarsa
CREATE OR REPLACE FUNCTION _assert_real_session() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_ds TEXT;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_uid AND status = 'active') THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;
  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;
  IF user_requires_mfa(v_uid) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;
  RETURN v_uid;
END $$;

-- ═════════════ IDENTITAS EFEKTIF DI HELPER OTORISASI ═════════════
CREATE OR REPLACE FUNCTION auth_is_active() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = (SELECT _eff_uid()) AND status = 'active')
$$;

CREATE OR REPLACE FUNCTION auth_is_wfrd() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = (SELECT _eff_uid()) AND status = 'active' AND contractor_id IS NULL)
$$;

CREATE OR REPLACE FUNCTION auth_contractor_id() RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT contractor_id FROM profiles WHERE id = (SELECT _eff_uid()) AND status = 'active'
$$;

-- Grant permission: mode role → hanya permission template (scope global) untuk aktor nyata;
-- mode user → grant milik target. Permission admin diblokir di kedua mode.
CREATE OR REPLACE FUNCTION _perm_grants(p_uid UUID, p_perm TEXT) RETURNS TABLE(scope_type TEXT, scope_id TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
#variable_conflict use_column
DECLARE v impersonation_contexts;
BEGIN
  IF p_uid IS NOT NULL AND COALESCE(request_header('x-comen-act-as'), '') <> '' THEN
    v := _act_as_ctx();
    IF v.kind = 'role' AND p_uid = v.real_actor_id THEN
      IF _act_as_perm_blocked(p_perm) THEN RETURN; END IF;
      RETURN QUERY
      SELECT 'global'::TEXT, NULL::TEXT
      FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
      WHERE r.key = v.act_as_role_key
        AND (rp.permission_key = p_perm
             OR (rp.permission_key = '*' AND EXISTS (SELECT 1 FROM permissions x WHERE x.key = p_perm AND x.audience <> 'contractor')))
      LIMIT 1;
      RETURN;
    END IF;
    IF v.kind = 'user' AND p_uid = v.act_as_user_id AND _act_as_perm_blocked(p_perm) THEN RETURN; END IF;
  END IF;
  RETURN QUERY
  SELECT ur.scope_type, ur.scope_id
  FROM user_roles ur
  JOIN profiles p          ON p.id = ur.user_id AND p.status = 'active'
  JOIN role_permissions rp ON rp.role_id = ur.role_id
  WHERE ur.user_id = p_uid
    AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
    AND (rp.permission_key = p_perm
         OR (rp.permission_key = '*' AND EXISTS (SELECT 1 FROM permissions x WHERE x.key = p_perm AND x.audience <> 'contractor')));
END $$;

CREATE OR REPLACE FUNCTION _user_has_role(p_uid UUID, p_role_key TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts;
BEGIN
  IF p_uid IS NOT NULL AND COALESCE(request_header('x-comen-act-as'), '') <> '' THEN
    v := _act_as_ctx();
    IF v.kind = 'role' AND p_uid = v.real_actor_id THEN RETURN p_role_key = v.act_as_role_key; END IF;
  END IF;
  RETURN EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN profiles p ON p.id = ur.user_id
                 WHERE ur.user_id = p_uid AND r.key = p_role_key AND p.status = 'active'
                   AND (ur.expires_at IS NULL OR ur.expires_at > NOW()));
END $$;

CREATE OR REPLACE FUNCTION has_permission(p_perm TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants((SELECT _eff_uid()), p_perm) g WHERE g.scope_type = 'global')
$$;

CREATE OR REPLACE FUNCTION has_any_permission(p_perm TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants((SELECT _eff_uid()), p_perm))
$$;

CREATE OR REPLACE FUNCTION has_contract_permission(p_perm TEXT, p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _uid_has_contract_permission((SELECT _eff_uid()), p_perm, p_contract)
$$;

CREATE OR REPLACE FUNCTION has_contractor_permission(p_perm TEXT, p_contractor UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM _perm_grants((SELECT _eff_uid()), p_perm) g
    WHERE g.scope_type = 'global'
       OR (g.scope_type = 'contractor' AND g.scope_id = p_contractor::TEXT)
       OR (g.scope_type = 'geozone'  AND EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND c.geozone = g.scope_id))
       OR (g.scope_type = 'contract' AND EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND c.id::TEXT = g.scope_id)))
$$;

CREATE OR REPLACE FUNCTION _has_geozone_permission(p_perm TEXT, p_geozone TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM _perm_grants((SELECT _eff_uid()), p_perm) g
                 WHERE g.scope_type = 'global' OR (g.scope_type = 'geozone' AND g.scope_id = p_geozone))
$$;

CREATE OR REPLACE FUNCTION can_view_contract(p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM contracts c
    WHERE c.id = p_contract AND (
         c.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND ((SELECT _eff_uid()) IN (c.process_owner_id, c.hse_reviewer_id)
                              OR has_contract_permission('contract.view', c.id)))))
$$;

CREATE OR REPLACE FUNCTION can_view_contractor(p_contractor UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_contractor IS NOT NULL AND (
       p_contractor = auth_contractor_id()
    OR (auth_is_wfrd() AND (
           has_contractor_permission('vendor.view', p_contractor)
        OR has_contractor_permission('contract.view', p_contractor)
        OR has_contractor_permission('task.view', p_contractor)
        OR EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND (SELECT _eff_uid()) IN (c.process_owner_id, c.hse_reviewer_id))
        OR EXISTS (SELECT 1 FROM tasks t WHERE t.contractor_id = p_contractor AND (SELECT _eff_uid()) IN (t.reviewer_id, t.assigned_to)))))
$$;

CREATE OR REPLACE FUNCTION can_view_task(p_task UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task AND (
         t.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND (
             (SELECT _eff_uid()) IN (t.reviewer_id, t.assigned_to)
          OR (t.contract_id IS NOT NULL AND (has_contract_permission('task.view', t.contract_id)
                                             OR EXISTS (SELECT 1 FROM contracts c WHERE c.id = t.contract_id
                                                        AND (SELECT _eff_uid()) IN (c.process_owner_id, c.hse_reviewer_id))))
          OR (t.contract_id IS NULL AND has_contractor_permission('task.view', t.contractor_id))))))
$$;

CREATE OR REPLACE FUNCTION can_read_contract_data(p_perm TEXT, p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM contracts c
    WHERE c.id = p_contract AND (
         c.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND ((SELECT _eff_uid()) IN (c.process_owner_id, c.hse_reviewer_id) OR has_contract_permission(p_perm, c.id)))))
$$;

-- Chat: di Realtime (WebSocket) header tidak ada → identitas nyata; di REST → identitas efektif
CREATE OR REPLACE FUNCTION is_chat_member(p_channel UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_channel IS NOT NULL AND auth_is_active() AND EXISTS (
    SELECT 1 FROM chat_members m WHERE m.channel_id = p_channel AND m.user_id = (SELECT _eff_uid()))
$$;

CREATE OR REPLACE FUNCTION can_see_chat_member(p_channel UUID, p_user UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT is_chat_member(p_channel) AND (
       auth_is_wfrd()
    OR p_user = (SELECT _eff_uid())
    OR EXISTS (SELECT 1 FROM profiles u WHERE u.id = p_user AND (u.contractor_id IS NULL OR u.contractor_id = auth_contractor_id())))
$$;

CREATE OR REPLACE FUNCTION can_broadcast_chat(p_channel UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_channel IS NOT NULL AND auth_is_active() AND EXISTS (
    SELECT 1 FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id
    WHERE m.channel_id = p_channel AND m.user_id = (SELECT _eff_uid()) AND m.member_role <> 'readonly' AND NOT c.is_archived)
$$;

CREATE OR REPLACE FUNCTION _assert_level(p_min contractor_user_level, p_msg TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_lvl contractor_user_level;
BEGIN
  IF auth.uid() IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_lvl := _contractor_level_of(_eff_uid());
  IF v_lvl IS NULL THEN RETURN; END IF;                                  -- user WFRD
  IF _level_rank(v_lvl) < _level_rank(p_min) THEN
    PERFORM _deny('insufficient_level', COALESCE(p_msg, 'Aksi ini membutuhkan level ' || upper(p_min::TEXT) || ' (level Anda: ' || upper(v_lvl::TEXT) || ')'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION _create_revision(v_t tasks, p_due DATE, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id UUID; v_tid TEXT; v_uid UUID := _eff_uid();
BEGIN
  IF v_t.revision >= 99 THEN RAISE EXCEPTION 'Batas revisi tercapai' USING ERRCODE = '22023'; END IF;
  v_tid := v_t.base_task_id || '-R' || (v_t.revision + 1);
  INSERT INTO tasks (task_id, revision, scope, contractor_id, contract_id, subcontractor_id, doc_type_code, kind, phase, title, description,
                     is_mandatory, is_blocker, source_ref, parent_task_id, renewal_of, assigned_to, reviewer_id, due_date, form_data, created_by)
  VALUES (v_tid, v_t.revision + 1, v_t.scope, v_t.contractor_id, v_t.contract_id, v_t.subcontractor_id, v_t.doc_type_code, v_t.kind,
          v_t.phase, v_t.title, v_t.description, v_t.is_mandatory, v_t.is_blocker, v_t.source_ref, v_t.id, v_t.renewal_of,
          v_t.assigned_to, v_t.reviewer_id, p_due, v_t.form_data, v_uid)
  RETURNING id INTO v_id;
  INSERT INTO checklist_items (task_id, item_no, category, label, owner_party, checked, checked_by, checked_at, evidence_ref, notes)
  SELECT v_id, item_no, category, label, owner_party, checked, checked_by, checked_at, evidence_ref, notes
  FROM checklist_items WHERE task_id = v_t.id;
  UPDATE audit_findings SET fndcls_task_id = v_id, status = 'open' WHERE fndcls_task_id = v_t.id;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (v_id, 'created', v_uid, jsonb_build_object('revision_of', v_t.task_id, 'reason', p_reason));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION _ensure_task_thread(p_task UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks; v_ch UUID; v_parent UUID;
BEGIN
  SELECT * INTO v_t FROM tasks WHERE id = p_task;
  IF v_t.contract_id IS NULL THEN RAISE EXCEPTION 'Thread hanya untuk task kontrak (task vendor: gunakan DM)' USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_ch FROM chat_channels WHERE task_id = p_task AND type = 'task';
  IF v_ch IS NOT NULL THEN RETURN v_ch; END IF;
  INSERT INTO chat_channels (type, name, task_id, contract_id, contractor_id, created_by)
  VALUES ('task', v_t.task_id || ' · ' || left(v_t.title, 80), p_task, v_t.contract_id, v_t.contractor_id, _eff_uid())
  ON CONFLICT DO NOTHING RETURNING id INTO v_ch;
  IF v_ch IS NULL THEN SELECT id INTO v_ch FROM chat_channels WHERE task_id = p_task AND type = 'task'; RETURN v_ch; END IF;
  SELECT id INTO v_parent FROM chat_channels WHERE contract_id = v_t.contract_id AND type = 'contract';
  INSERT INTO chat_members (channel_id, user_id, member_role)
  SELECT v_ch, m.user_id, m.member_role FROM chat_members m WHERE m.channel_id = v_parent
  ON CONFLICT DO NOTHING;
  RETURN v_ch;
END $$;

-- ═════════════ GERBANG OTORISASI ═════════════
CREATE OR REPLACE FUNCTION assert_access(
  p_perm       TEXT,
  p_contract   UUID    DEFAULT NULL,
  p_write      BOOLEAN DEFAULT TRUE,
  p_contractor UUID    DEFAULT NULL,
  p_geozone    TEXT    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_real UUID := auth.uid(); v_uid UUID; v_status account_status; v_cid UUID; v_ds TEXT; v_risk TEXT; v_ok BOOLEAN; v_owner UUID;
  v_min contractor_user_level; v_lvl contractor_user_level;
BEGIN
  IF v_real IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_uid := _eff_uid();

  SELECT status, contractor_id INTO v_status, v_cid FROM profiles WHERE id = v_uid;
  IF v_status IS DISTINCT FROM 'active' THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;

  v_ds := device_state();                                     -- perangkat & sesi: selalu aktor nyata
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;

  IF user_requires_mfa(v_real) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;

  SELECT risk_level INTO v_risk FROM permissions WHERE key = p_perm;
  IF v_risk IS NULL THEN RAISE EXCEPTION 'Permission tidak dikenal: %', p_perm USING ERRCODE = 'XX000'; END IF;
  IF (v_risk = 'critical' OR p_perm LIKE 'admin.%') AND auth_aal() <> 'aal2' THEN
    PERFORM _deny('mfa_required', 'Aksi ini membutuhkan MFA');
  END IF;
  IF _act_as_perm_blocked(p_perm) AND _act_as_active() THEN
    PERFORM _deny('act_as_blocked', 'Aksi Admin Console tidak tersedia saat mode Act As. Keluar dari Act As terlebih dahulu.');
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
    v_min := _perm_min_level(p_perm);
    IF v_min IS NOT NULL THEN
      v_lvl := _contractor_level_of(v_uid);
      IF _level_rank(v_lvl) < _level_rank(v_min) THEN
        PERFORM _deny('insufficient_level', 'Aksi ini khusus level ' || upper(v_min::TEXT) || ' perusahaan (level Anda: ' || upper(v_lvl::TEXT) || ')');
      END IF;
    END IF;
  END IF;

  IF p_write AND _setting_bool('read_only_mode', FALSE) AND NOT has_permission('admin.system.danger') THEN
    PERFORM _deny('read_only', 'Sistem dalam mode read-only');
  END IF;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION assert_session(p_write BOOLEAN DEFAULT TRUE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_real UUID := auth.uid(); v_uid UUID; v_ds TEXT;
BEGIN
  IF v_real IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_uid := _eff_uid();
  IF NOT auth_is_active() THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;
  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;
  IF user_requires_mfa(v_real) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;
  IF p_write AND _setting_bool('read_only_mode', FALSE) AND NOT has_permission('admin.system.danger') THEN
    PERFORM _deny('read_only', 'Sistem dalam mode read-only');
  END IF;
  RETURN v_uid;
END $$;

-- ═════════════ AUDIT (R40) ═════════════
-- Baris tanpa Act As memakai hash lama persis → rantai historis tetap terverifikasi.
CREATE OR REPLACE FUNCTION _audit_hash_v2(p_prev TEXT, p_table TEXT, p_record TEXT, p_action TEXT, p_old JSONB, p_new JSONB,
                                          p_actor UUID, p_at TIMESTAMPTZ, p_aa_ctx UUID, p_aa_user UUID, p_aa_role TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT CASE WHEN p_aa_ctx IS NULL AND p_aa_user IS NULL AND p_aa_role IS NULL
    THEN _audit_hash(p_prev, p_table, p_record, p_action, p_old, p_new, p_actor, p_at)
    ELSE encode(digest(_audit_hash(p_prev, p_table, p_record, p_action, p_old, p_new, p_actor, p_at) || '|act_as|' ||
                       COALESCE(p_aa_ctx::TEXT, '') || '|' || COALESCE(p_aa_user::TEXT, '') || '|' || COALESCE(p_aa_role, ''), 'sha256'), 'hex')
  END
$$;

CREATE OR REPLACE FUNCTION log_change() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_old JSONB; v_new JSONB; v_row JSONB; v_record TEXT := ''; v_head audit_chain_head;
  v_now TIMESTAMPTZ := clock_timestamp(); v_hash TEXT; v_id BIGINT; i INT;
  v_aa impersonation_contexts; v_aa_user UUID; v_aa_role TEXT;
  v_noise CONSTANT TEXT[] := ARRAY['updated_at','last_login_at','last_seen','last_ip_hmac','last_session_id','last_message_at'];
  v_secret CONSTANT TEXT[] := ARRAY['body_enc','prev_body_enc','phone_enc','primary_contact_phone_enc','auth_secret_enc'];
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN v_old := to_jsonb(OLD) - v_secret; END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN v_new := to_jsonb(NEW) - v_secret; END IF;
  IF TG_OP = 'UPDATE' AND (v_old - v_noise) = (v_new - v_noise) THEN RETURN NEW; END IF;   -- abaikan perubahan "noise"

  v_row := COALESCE(v_new, v_old);
  IF TG_NARGS = 0 THEN v_record := v_row ->> 'id';
  ELSE
    FOR i IN 0 .. TG_NARGS - 1 LOOP
      v_record := v_record || CASE WHEN i > 0 THEN ':' ELSE '' END || COALESCE(v_row ->> TG_ARGV[i], '');
    END LOOP;
  END IF;

  -- Non-raising: act_as_close dengan token kedaluwarsa tetap tercatat (tanpa label Act As)
  v_aa := (_act_as_check()).o_ctx;
  IF v_aa.id IS NOT NULL THEN
    v_aa_user := CASE WHEN v_aa.kind = 'user' THEN v_aa.act_as_user_id END;
    v_aa_role := CASE WHEN v_aa.kind = 'role' THEN v_aa.act_as_role_key END;
  END IF;

  SELECT * INTO v_head FROM audit_chain_head WHERE id = 1 FOR UPDATE;          -- serialisasi rantai
  v_id := nextval('audit_logs_id_seq');
  v_hash := _audit_hash_v2(v_head.last_hash, TG_TABLE_NAME, v_record, TG_OP, v_old, v_new, auth.uid(), v_now, v_aa.id, v_aa_user, v_aa_role);

  INSERT INTO audit_logs (id, table_name, record_id, action, old_data, new_data, actor_id, actor_role,
                          device_hash, prev_hash, row_hash, created_at, act_as_context_id, act_as_user_id, act_as_role_key)
  VALUES (v_id, TG_TABLE_NAME, v_record, TG_OP, v_old, v_new, auth.uid(),
          COALESCE(auth.jwt() ->> 'role', current_user), request_device_hash(), v_head.last_hash, v_hash, v_now,
          v_aa.id, v_aa_user, v_aa_role);
  UPDATE audit_chain_head SET last_id = v_id, last_hash = v_hash WHERE id = 1;
  RETURN COALESCE(NEW, OLD);
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
    IF r.row_hash <> _audit_hash_v2(r.prev_hash, r.table_name, r.record_id, r.action, r.old_data, r.new_data, r.actor_id, r.created_at,
                                    r.act_as_context_id, r.act_as_user_id, r.act_as_role_key) THEN
      RETURN jsonb_build_object('ok', FALSE, 'broken_at_id', r.id, 'reason', 'row_hash_mismatch', 'checked', v_n);
    END IF;
    v_prev := r.row_hash; v_first := FALSE; v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', TRUE, 'checked', v_n, 'last_hash', v_prev,
                            'head', (SELECT jsonb_build_object('id', last_id, 'hash', last_hash) FROM audit_chain_head WHERE id = 1));
END $$;

DROP TRIGGER IF EXISTS trg_audit ON impersonation_contexts;
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON impersonation_contexts FOR EACH ROW EXECUTE FUNCTION log_change('id');

-- ═════════════ NOTIFIKASI (R43) ═════════════
-- Notif untuk target yang dipicu aksi Act As → masuk inbox aktor nyata (target tidak menerima notif/email atas aksi yang tidak ia lakukan)
CREATE OR REPLACE FUNCTION _notify(p_user UUID, p_kind TEXT, p_title TEXT, p_body TEXT, p_link TEXT, p_severity TEXT DEFAULT 'info',
                                   p_template INT DEFAULT NULL, p_params JSONB DEFAULT '{}'::jsonb, p_dedupe TEXT DEFAULT NULL,
                                   p_send_after TIMESTAMPTZ DEFAULT NOW())
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id BIGINT; v_aa impersonation_contexts;
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;
  v_aa := (_act_as_check()).o_ctx;
  IF v_aa.kind = 'user' AND p_user = v_aa.act_as_user_id THEN
    p_user := v_aa.real_actor_id;
    p_title := '[Act As] ' || p_title;
    p_dedupe := CASE WHEN p_dedupe IS NOT NULL THEN 'aa:' || v_aa.id || ':' || p_dedupe END;
    p_template := NULL;
  END IF;
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

-- ═════════════ CHAT (R44) ═════════════
CREATE OR REPLACE FUNCTION _act_as_chat_actor() RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts;
BEGIN
  v := (_act_as_check()).o_ctx;
  RETURN CASE WHEN v.kind = 'user' THEN v.real_actor_id END;
END $$;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS act_as_actor_id UUID REFERENCES profiles(id);
ALTER TABLE chat_messages ALTER COLUMN act_as_actor_id SET DEFAULT _act_as_chat_actor();

-- Pesan asli target tidak boleh diedit/dihapus lewat Act As; penanda via_act_as immutable
CREATE OR REPLACE FUNCTION _act_as_chat_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts;
BEGIN
  IF NEW.act_as_actor_id IS DISTINCT FROM OLD.act_as_actor_id THEN
    RAISE EXCEPTION 'Penanda Act As pesan immutable' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(request_header('x-comen-act-as'), '') = '' THEN RETURN NEW; END IF;
  v := (_act_as_check()).o_ctx;
  IF v.kind = 'user' AND OLD.sender_id = v.act_as_user_id AND OLD.act_as_actor_id IS DISTINCT FROM v.real_actor_id
     AND (NEW.body_sha256 IS DISTINCT FROM OLD.body_sha256 OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at) THEN
    PERFORM _deny('act_as_blocked', 'Pesan asli user tidak bisa diedit/dihapus lewat Act As');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_act_as_chat_guard ON chat_messages;
CREATE TRIGGER trg_act_as_chat_guard BEFORE UPDATE ON chat_messages FOR EACH ROW EXECUTE FUNCTION _act_as_chat_guard();

-- ═════════════ DATA PRIBADI TARGET (R45) ═════════════
-- Mode user: tanda tangan, wajib-baca, reaksi, bookmark, perangkat, push, pesan terjadwal milik target tidak bisa ditulis.
-- TG_ARGV[0] = kolom pemilik, TG_ARGV[1] = nama aksi untuk pesan error.
CREATE OR REPLACE FUNCTION _act_as_personal_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts; v_owner_new TEXT; v_owner_old TEXT;
BEGIN
  IF COALESCE(request_header('x-comen-act-as'), '') = '' THEN RETURN COALESCE(NEW, OLD); END IF;
  v := (_act_as_check()).o_ctx;
  IF v.kind IS DISTINCT FROM 'user' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_owner_new := to_jsonb(NEW) ->> TG_ARGV[0]; END IF;
  IF TG_OP <> 'INSERT' THEN v_owner_old := to_jsonb(OLD) ->> TG_ARGV[0]; END IF;
  IF v.act_as_user_id::TEXT IN (v_owner_new, v_owner_old) THEN
    PERFORM _deny('act_as_blocked', TG_ARGV[1] || ' atas nama user lain tidak diizinkan saat Act As');
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('signatures', 'signer_id', 'Tanda tangan'), ('chat_acks', 'user_id', 'Konfirmasi wajib-baca'),
    ('chat_reactions', 'user_id', 'Reaksi pesan'), ('chat_saved', 'user_id', 'Simpan pesan'),
    ('trusted_devices', 'user_id', 'Mengubah perangkat'), ('push_subscriptions', 'user_id', 'Mengubah push notification'),
    ('chat_scheduled', 'sender_id', 'Pesan terjadwal')) v(t, col, what)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_act_as_personal ON %I', r.t);
    EXECUTE format('CREATE TRIGGER trg_act_as_personal BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW '
                   'EXECUTE FUNCTION _act_as_personal_guard(%L, %L)', r.t, r.col, r.what);
  END LOOP;
END $$;

-- Keanggotaan chat target: hanya last_read_seq (efek kirim pesan) yang boleh berubah
CREATE OR REPLACE FUNCTION _act_as_member_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v impersonation_contexts;
BEGIN
  IF COALESCE(request_header('x-comen-act-as'), '') = '' THEN RETURN COALESCE(NEW, OLD); END IF;
  v := (_act_as_check()).o_ctx;
  IF v.kind IS DISTINCT FROM 'user' OR OLD.user_id IS DISTINCT FROM v.act_as_user_id THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'last_read_seq') IS DISTINCT FROM (to_jsonb(OLD) - 'last_read_seq') THEN
    PERFORM _deny('act_as_blocked', 'Pengaturan/keanggotaan chat user lain tidak bisa diubah saat Act As');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_act_as_member_guard ON chat_members;
CREATE TRIGGER trg_act_as_member_guard BEFORE UPDATE OR DELETE ON chat_members FOR EACH ROW EXECUTE FUNCTION _act_as_member_guard();

-- ═════════════ PRIVILEGE ═════════════
-- Semua helper baru internal (_xxx): tidak executable oleh klien (default privileges migration 16).
REVOKE ALL ON FUNCTION _act_as_role_allowed(TEXT), _act_as_perm_blocked(TEXT), _can_act_as(UUID), _act_as_target_ok(UUID, UUID),
  _act_as_check(), _act_as_ctx(), _eff_uid(), _act_as_active(), _act_as_user(), _assert_not_acting(TEXT), _assert_real_session(),
  _audit_hash_v2(TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, UUID, TIMESTAMPTZ, UUID, UUID, TEXT), _act_as_chat_actor(),
  _act_as_chat_guard(), _act_as_personal_guard(), _act_as_member_guard()
FROM PUBLIC, anon, authenticated, service_role;
