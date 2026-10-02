-- ═════════════ HELPER ═════════════
CREATE OR REPLACE FUNCTION is_chat_member(p_channel UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_channel IS NOT NULL AND auth_is_active() AND EXISTS (
    SELECT 1 FROM chat_members m WHERE m.channel_id = p_channel AND m.user_id = auth.uid())
$$;

CREATE OR REPLACE FUNCTION _topic_channel(p_topic TEXT) RETURNS UUID
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_topic ~ '^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN substr(p_topic, 6)::UUID END
$$;

CREATE OR REPLACE FUNCTION can_broadcast_chat(p_channel UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_channel IS NOT NULL AND auth_is_active() AND EXISTS (
    SELECT 1 FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id
    WHERE m.channel_id = p_channel AND m.user_id = auth.uid() AND m.member_role <> 'readonly' AND NOT c.is_archived)
$$;

-- Contractor di announcement/channel tidak boleh melihat user contractor perusahaan lain
CREATE OR REPLACE FUNCTION can_see_chat_member(p_channel UUID, p_user UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT is_chat_member(p_channel) AND (
       auth_is_wfrd()
    OR p_user = auth.uid()
    OR EXISTS (SELECT 1 FROM profiles u WHERE u.id = p_user AND (u.contractor_id IS NULL OR u.contractor_id = auth_contractor_id())))
$$;

CREATE OR REPLACE FUNCTION _member_role(p_channel UUID, p_user UUID) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT member_role FROM chat_members WHERE channel_id = p_channel AND user_id = p_user
$$;

CREATE OR REPLACE FUNCTION _assert_chat_member(p_channel UUID, p_write BOOLEAN DEFAULT FALSE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, p_write); v_role TEXT := _member_role(p_channel, v_uid);
BEGIN
  IF v_role IS NULL THEN PERFORM _deny('forbidden', 'Anda bukan anggota percakapan ini'); END IF;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION _is_channel_mod(p_channel UUID, p_uid UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT _member_role(p_channel, p_uid) IN ('owner','moderator') OR has_permission('chat.moderate')
$$;

CREATE OR REPLACE FUNCTION _add_member(p_channel UUID, p_user UUID, p_role TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  INSERT INTO chat_members (channel_id, user_id, member_role) VALUES (p_channel, p_user, p_role)
  ON CONFLICT (channel_id, user_id) DO UPDATE SET member_role = EXCLUDED.member_role
    WHERE chat_members.member_role <> EXCLUDED.member_role;
END $$;

-- ═════════════ POSTING INTI (user & bot) ═════════════
CREATE OR REPLACE FUNCTION _post_message(p_channel UUID, p_sender UUID, p_body TEXT, p_kind TEXT DEFAULT 'text',
  p_priority TEXT DEFAULT 'normal', p_requires_ack BOOLEAN DEFAULT FALSE, p_reply_to UUID DEFAULT NULL, p_thread_root UUID DEFAULT NULL,
  p_mentions UUID[] DEFAULT '{}', p_client_msg_id UUID DEFAULT NULL, p_task_refs TEXT[] DEFAULT '{}') RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_body TEXT := _clean_text(p_body, 4000, TRUE); v_ch chat_channels; v_id UUID; v_seq BIGINT; v_ver SMALLINT := _active_key_ver('chat');
        v_mentions UUID[]; v_refs TEXT[]; v_members INT; v_m RECORD; v_ex RECORD;
BEGIN
  IF p_sender IS NOT NULL AND p_client_msg_id IS NOT NULL THEN
    SELECT id, seq INTO v_ex FROM chat_messages WHERE sender_id = p_sender AND client_msg_id = p_client_msg_id;
    IF FOUND THEN RETURN jsonb_build_object('id', v_ex.id, 'seq', v_ex.seq, 'duplicate', TRUE); END IF;
  END IF;
  SELECT * INTO v_ch FROM chat_channels WHERE id = p_channel;
  IF p_reply_to IS NOT NULL AND NOT EXISTS (SELECT 1 FROM chat_messages WHERE id = p_reply_to AND channel_id = p_channel) THEN
    RAISE EXCEPTION 'Pesan yang dibalas tidak ada di channel ini' USING ERRCODE = '22023'; END IF;
  IF p_thread_root IS NOT NULL AND NOT EXISTS (SELECT 1 FROM chat_messages WHERE id = p_thread_root AND channel_id = p_channel AND thread_root IS NULL) THEN
    RAISE EXCEPTION 'Thread tidak valid' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(array_agg(DISTINCT m.user_id), '{}') INTO v_mentions
  FROM chat_members m WHERE m.channel_id = p_channel AND m.user_id = ANY((COALESCE(p_mentions, '{}'::UUID[]))[1:50])
    AND m.user_id IS DISTINCT FROM p_sender;
  SELECT COALESCE(array_agg(DISTINCT r), '{}') INTO v_refs FROM (
    SELECT (regexp_matches(v_body, 'CMN-(?:V\d{5}|\d{5}(?:S\d{2})?)-[A-Z0-9]{6}-\d{3}(?:-R\d{1,2})?', 'g'))[1] AS r
    UNION SELECT unnest(COALESCE(p_task_refs, '{}'))) x
  WHERE r IS NOT NULL;
  v_refs := v_refs[1:10];

  INSERT INTO chat_messages (channel_id, sender_id, client_msg_id, kind, body_enc, body_sha256, key_ver, priority, requires_ack,
                             reply_to, thread_root, mentions, task_refs)
  VALUES (p_channel, p_sender, p_client_msg_id, p_kind, _encrypt(v_body, 'chat', v_ver), encode(digest(v_body, 'sha256'), 'hex'), v_ver,
          p_priority, COALESCE(p_requires_ack, FALSE), p_reply_to, p_thread_root, v_mentions, v_refs)
  RETURNING id, seq INTO v_id, v_seq;
  UPDATE chat_channels SET last_message_at = NOW() WHERE id = p_channel;
  IF p_sender IS NOT NULL THEN
    UPDATE chat_members SET last_read_seq = v_seq WHERE channel_id = p_channel AND user_id = p_sender;
  END IF;

  PERFORM _rt_send('chat:' || p_channel, 'message_created', jsonb_build_object('id', v_id, 'seq', v_seq, 'channel', p_channel, 'thread_root', p_thread_root));
  SELECT count(*) INTO v_members FROM chat_members WHERE channel_id = p_channel;

  FOR v_m IN SELECT m.user_id, m.notify_level, m.muted_until FROM chat_members m JOIN profiles p ON p.id = m.user_id AND p.status = 'active'
             WHERE m.channel_id = p_channel AND m.user_id IS DISTINCT FROM p_sender LOOP
    IF v_members <= 200 THEN
      PERFORM _rt_send('user:' || v_m.user_id, 'chat_activity', jsonb_build_object('channel', p_channel, 'seq', v_seq));
    END IF;
    IF p_priority = 'urgent' THEN
      PERFORM _notify(v_m.user_id, 'chat_urgent', '🔴 Pesan URGENT', NULL, '/chat/' || p_channel, 'critical', NULL, '{}'::jsonb, 'urg:' || v_id || ':' || v_m.user_id);
      INSERT INTO notification_outbox (channel, template_id, to_user, params, dedupe_key)
      VALUES ('push', 6002, v_m.user_id, jsonb_build_object('channel', p_channel, 'message', v_id), 'push:urg:' || v_id || ':' || v_m.user_id || ':0')
      ON CONFLICT (dedupe_key) DO NOTHING;
    ELSIF COALESCE(v_m.muted_until, '-infinity') < NOW() AND (
            (v_m.user_id = ANY(v_mentions) AND v_m.notify_level IN ('all','mentions'))
         OR (v_ch.type = 'direct' AND v_m.notify_level = 'all')) THEN
      IF v_m.user_id = ANY(v_mentions) THEN
        PERFORM _notify(v_m.user_id, 'chat_mention', 'Anda disebut dalam percakapan', NULL, '/chat/' || p_channel, 'info', NULL, '{}'::jsonb, 'men:' || v_id || ':' || v_m.user_id);
      END IF;
      INSERT INTO notification_outbox (channel, template_id, to_user, params, dedupe_key)
      VALUES ('push', 6001, v_m.user_id, jsonb_build_object('channel', p_channel, 'message', v_id), 'push:' || v_id || ':' || v_m.user_id)
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
    IF COALESCE(p_requires_ack, FALSE) THEN
      PERFORM _notify(v_m.user_id, 'chat_ack_required', 'Pesan wajib dibaca', NULL, '/chat/' || p_channel, 'warning',
                      CASE WHEN v_ch.type = 'announcement' THEN 6003 END, jsonb_build_object('channel_name', v_ch.name), 'ack:' || v_id || ':' || v_m.user_id);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('id', v_id, 'seq', v_seq, 'duplicate', FALSE);
END $$;

-- Bot: kegagalan chat tidak boleh membatalkan transaksi bisnis
CREATE OR REPLACE FUNCTION _bot_contract(p_contract UUID, p_kind TEXT, p_text TEXT, p_priority TEXT DEFAULT 'normal', p_task_refs TEXT[] DEFAULT '{}')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ch UUID;
BEGIN
  SELECT id INTO v_ch FROM chat_channels WHERE contract_id = p_contract AND type = 'contract' AND NOT is_archived;
  IF v_ch IS NULL THEN RETURN; END IF;
  BEGIN
    PERFORM _post_message(v_ch, NULL, p_text, p_kind, p_priority, FALSE, NULL, NULL, '{}', NULL, p_task_refs);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO security_events (event, severity, detail) VALUES ('bot_error', 'warning', jsonb_build_object('contract', p_contract, 'error', SQLERRM));
  END;
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
  VALUES ('task', v_t.task_id || ' · ' || left(v_t.title, 80), p_task, v_t.contract_id, v_t.contractor_id, auth.uid())
  ON CONFLICT DO NOTHING RETURNING id INTO v_ch;
  IF v_ch IS NULL THEN SELECT id INTO v_ch FROM chat_channels WHERE task_id = p_task AND type = 'task'; RETURN v_ch; END IF;
  SELECT id INTO v_parent FROM chat_channels WHERE contract_id = v_t.contract_id AND type = 'contract';
  INSERT INTO chat_members (channel_id, user_id, member_role)
  SELECT v_ch, m.user_id, m.member_role FROM chat_members m WHERE m.channel_id = v_parent
  ON CONFLICT DO NOTHING;
  RETURN v_ch;
END $$;

CREATE OR REPLACE FUNCTION _bot_task_thread(p_task UUID, p_kind TEXT, p_text TEXT, p_priority TEXT DEFAULT 'normal') RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ch UUID; v_tid TEXT;
BEGIN
  BEGIN
    v_ch := _ensure_task_thread(p_task);
    SELECT task_id INTO v_tid FROM tasks WHERE id = p_task;
    PERFORM _post_message(v_ch, NULL, p_text, p_kind, p_priority, FALSE, NULL, NULL, '{}', NULL, ARRAY[v_tid]);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO security_events (event, severity, detail) VALUES ('bot_error', 'warning', jsonb_build_object('task', p_task, 'error', SQLERRM));
  END;
END $$;

-- ═════════════ SINKRON KEANGGOTAAN ═════════════
CREATE OR REPLACE FUNCTION _sync_contract_channel(p_contract UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts; v_ch UUID; v_t RECORD; v_target UUID;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  IF NOT FOUND THEN RETURN; END IF;
  INSERT INTO chat_channels (type, name, contract_id, contractor_id, created_by)
  VALUES ('contract', v_k.contract_no || ' · ' || left(v_k.title, 80), p_contract, v_k.contractor_id, v_k.created_by)
  ON CONFLICT (contract_id) WHERE type = 'contract' DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_ch;
  UPDATE chat_channels SET is_archived = (v_k.status IN ('closed','terminated')) WHERE contract_id = p_contract AND type IN ('contract','task');

  FOR v_target IN SELECT v_ch UNION ALL SELECT id FROM chat_channels WHERE contract_id = p_contract AND type = 'task' LOOP
    -- buang user contractor yang bukan milik contractor ini / tidak aktif
    DELETE FROM chat_members m USING profiles p
    WHERE m.channel_id = v_target AND p.id = m.user_id
      AND ((p.contractor_id IS NOT NULL AND p.contractor_id <> v_k.contractor_id) OR p.status <> 'active');
    -- buang WFRD yang tidak lagi punya akses kontrak (role scope dicabut/kedaluwarsa)
    DELETE FROM chat_members m USING profiles p
    WHERE m.channel_id = v_target AND p.id = m.user_id AND p.contractor_id IS NULL AND NOT p.is_root_admin
      AND m.user_id NOT IN (v_k.process_owner_id, v_k.hse_reviewer_id)
      AND NOT _uid_has_contract_permission(m.user_id, 'contract.view', p_contract);
    -- turunkan owner/moderator lama
    UPDATE chat_members SET member_role = 'member'
    WHERE channel_id = v_target AND member_role IN ('owner','moderator')
      AND user_id NOT IN (v_k.process_owner_id, v_k.hse_reviewer_id)
      AND user_id NOT IN (SELECT id FROM profiles WHERE is_root_admin);
    PERFORM _add_member(v_target, v_k.process_owner_id, 'owner');
    IF v_k.hse_reviewer_id <> v_k.process_owner_id THEN PERFORM _add_member(v_target, v_k.hse_reviewer_id, 'moderator'); END IF;
    INSERT INTO chat_members (channel_id, user_id, member_role)
    SELECT v_target, p.id, 'moderator' FROM profiles p WHERE p.is_root_admin AND p.status = 'active'
    ON CONFLICT (channel_id, user_id) DO UPDATE SET member_role = 'moderator' WHERE chat_members.member_role = 'member';
    INSERT INTO chat_members (channel_id, user_id, member_role)
    SELECT v_target, p.id, CASE WHEN has_rep.ok THEN 'member' ELSE 'readonly' END
    FROM profiles p
    CROSS JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM user_roles ur JOIN role_permissions rp ON rp.role_id = ur.role_id
                                       WHERE ur.user_id = p.id AND rp.permission_key = 'record.submit'
                                         AND (ur.expires_at IS NULL OR ur.expires_at > NOW())) AS ok) has_rep
    WHERE p.contractor_id = v_k.contractor_id AND p.status = 'active'
    ON CONFLICT (channel_id, user_id) DO UPDATE SET member_role = EXCLUDED.member_role;
    INSERT INTO chat_members (channel_id, user_id, member_role)
    SELECT DISTINCT v_target, ur.user_id, 'member' FROM user_roles ur JOIN profiles p ON p.id = ur.user_id AND p.status = 'active'
    WHERE ur.scope_type = 'contract' AND ur.scope_id = p_contract::TEXT AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

-- audience: {"all_contractors":true} | {"contractor_ids":[…]} | {"contract_ids":[…]} | {"wfrd":true} (boleh dikombinasikan)
-- Semua penerima readonly; PO kontrak yang ditarget = member (bisa membalas). Tanpa temp table (aman untuk SECURITY DEFINER).
CREATE OR REPLACE FUNCTION _announcement_audience(p_a JSONB) RETURNS TABLE (user_id UUID, member_role TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  WITH k AS (SELECT c.id, c.contractor_id, c.process_owner_id FROM contracts c
             WHERE c.id::TEXT IN (SELECT jsonb_array_elements_text(COALESCE(p_a -> 'contract_ids', '[]'::jsonb)))),
  base AS (
    SELECT p.id AS user_id, 'readonly'::TEXT AS member_role FROM profiles p
    WHERE p.status = 'active' AND (
         (COALESCE((p_a ->> 'all_contractors')::BOOLEAN, FALSE) AND p.contractor_id IS NOT NULL)
      OR p.contractor_id::TEXT IN (SELECT jsonb_array_elements_text(COALESCE(p_a -> 'contractor_ids', '[]'::jsonb)))
      OR p.contractor_id IN (SELECT contractor_id FROM k)
      OR (COALESCE((p_a ->> 'wfrd')::BOOLEAN, FALSE) AND p.contractor_id IS NULL))
    UNION ALL
    SELECT k.process_owner_id, 'member' FROM k JOIN profiles p ON p.id = k.process_owner_id AND p.status = 'active')
  SELECT user_id, CASE WHEN bool_or(member_role = 'member') THEN 'member' ELSE 'readonly' END FROM base GROUP BY user_id
$$;

CREATE OR REPLACE FUNCTION _sync_announcement(p_channel UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_a JSONB;
BEGIN
  SELECT audience INTO v_a FROM chat_channels WHERE id = p_channel AND type = 'announcement';
  IF NOT FOUND THEN RETURN; END IF;
  DELETE FROM chat_members m WHERE m.channel_id = p_channel AND m.member_role NOT IN ('owner','moderator')
    AND NOT EXISTS (SELECT 1 FROM _announcement_audience(v_a) a WHERE a.user_id = m.user_id);
  INSERT INTO chat_members (channel_id, user_id, member_role)
  SELECT p_channel, a.user_id, a.member_role FROM _announcement_audience(v_a) a
  ON CONFLICT (channel_id, user_id) DO UPDATE SET member_role = EXCLUDED.member_role
    WHERE chat_members.member_role NOT IN ('owner','moderator') AND chat_members.member_role <> EXCLUDED.member_role;
END $$;

-- ═════════════ RPC PESAN ═════════════
CREATE OR REPLACE FUNCTION send_message(p_channel UUID, p_body TEXT, p_client_msg_id UUID, p_reply_to UUID DEFAULT NULL,
  p_thread_root UUID DEFAULT NULL, p_mentions UUID[] DEFAULT '{}', p_priority TEXT DEFAULT 'normal', p_requires_ack BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, TRUE); v_m chat_members; v_ch chat_channels;
BEGIN
  SELECT * INTO v_m FROM chat_members WHERE channel_id = p_channel AND user_id = v_uid;
  SELECT * INTO v_ch FROM chat_channels WHERE id = p_channel;
  IF v_ch.is_archived OR v_ch.is_locked THEN RAISE EXCEPTION 'Percakapan dikunci/diarsipkan' USING ERRCODE = '22023'; END IF;
  IF v_m.member_role = 'readonly' THEN PERFORM _deny('forbidden', 'Anda hanya bisa membaca percakapan ini'); END IF;
  IF v_m.silenced_until > NOW() THEN PERFORM _deny('forbidden', 'Anda dibungkam moderator sampai ' || v_m.silenced_until); END IF;
  IF p_priority NOT IN ('normal','important','urgent') THEN RAISE EXCEPTION 'Prioritas tidak valid' USING ERRCODE = '22023'; END IF;
  IF (p_priority <> 'normal' OR p_requires_ack) AND NOT auth_is_wfrd() THEN PERFORM _deny('forbidden', 'Prioritas & wajib-baca hanya untuk WFRD'); END IF;
  IF p_client_msg_id IS NULL THEN RAISE EXCEPTION 'client_msg_id wajib' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM chat_messages WHERE sender_id = v_uid AND client_msg_id = p_client_msg_id) THEN
    PERFORM hit_rate_limit('chat:' || v_uid, _setting_int('rate_chat_per_min', 30), INTERVAL '1 minute');
    IF p_priority = 'urgent' THEN PERFORM hit_rate_limit('chat_urgent:' || v_uid, 5, INTERVAL '1 hour'); END IF;
  END IF;
  RETURN _post_message(p_channel, v_uid, p_body, 'text', p_priority, p_requires_ack, p_reply_to, p_thread_root, p_mentions, p_client_msg_id, '{}');
END $$;

CREATE OR REPLACE FUNCTION get_messages(p_channel UUID, p_before_seq BIGINT DEFAULT NULL, p_limit INT DEFAULT 50, p_thread_root UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
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
      'saved', EXISTS (SELECT 1 FROM chat_saved s WHERE s.message_id = m.id AND s.user_id = v_uid)) AS x
    FROM chat_messages m
    WHERE m.channel_id = p_channel
      AND (p_before_seq IS NULL OR m.seq < p_before_seq)
      AND CASE WHEN p_thread_root IS NULL THEN m.thread_root IS NULL ELSE (m.thread_root = p_thread_root OR m.id = p_thread_root) END
    ORDER BY m.seq DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 100)) q);
END $$;

CREATE OR REPLACE FUNCTION list_my_channels() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x) ORDER BY x.last_message_at DESC NULLS LAST), '[]'::jsonb) FROM (
    SELECT c.id, c.type, c.is_archived, c.is_locked, c.contract_id, c.task_id, c.last_message_at, m.member_role, m.notify_level, m.muted_until,
           CASE WHEN c.type = 'direct' THEN (SELECT p.full_name FROM chat_members o JOIN profiles p ON p.id = o.user_id
                                             WHERE o.channel_id = c.id AND o.user_id <> v_uid LIMIT 1) ELSE c.name END AS name,
           CASE WHEN c.type = 'direct' THEN (SELECT o.user_id FROM chat_members o WHERE o.channel_id = c.id AND o.user_id <> v_uid LIMIT 1) END AS peer_id,
           (SELECT count(*) FROM (SELECT 1 FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.seq > m.last_read_seq
                                    AND cm.sender_id IS DISTINCT FROM v_uid AND cm.deleted_at IS NULL LIMIT 99) u) AS unread,
           (SELECT count(*) FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.seq > m.last_read_seq AND v_uid = ANY(cm.mentions)) AS unread_mentions,
           (SELECT count(*) FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.requires_ack AND cm.deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM chat_acks a WHERE a.message_id = cm.id AND a.user_id = v_uid)
              AND cm.sender_id IS DISTINCT FROM v_uid) AS pending_acks
    FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id
    WHERE m.user_id = v_uid) x);
END $$;

CREATE OR REPLACE FUNCTION get_channel_members(p_channel UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'role', m.member_role, 'silenced_until', m.silenced_until)), '[]'::jsonb)
          FROM chat_members m WHERE m.channel_id = p_channel AND can_see_chat_member(p_channel, m.user_id));
END $$;

-- Kartu profil minimal (nama, foto, jabatan, perusahaan) dengan aturan visibilitas
CREATE OR REPLACE FUNCTION get_user_cards(p_ids UUID[]) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_wfrd BOOLEAN := auth_is_wfrd(); v_cid UUID := auth_contractor_id();
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
            'job_title', p.job_title, 'is_wfrd', p.contractor_id IS NULL, 'company', COALESCE(c.legal_name, 'Weatherford'),
            'active', p.status = 'active')), '[]'::jsonb)
    FROM profiles p LEFT JOIN contractors c ON c.id = p.contractor_id
    WHERE p.id = ANY(p_ids[1:200]) AND (v_wfrd OR p.contractor_id IS NULL OR p.contractor_id = v_cid));
END $$;

CREATE OR REPLACE FUNCTION create_direct_channel(p_user UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use'); v_me profiles; v_o profiles; v_key TEXT; v_ch UUID; v_shared BOOLEAN;
BEGIN
  IF p_user = v_uid THEN RAISE EXCEPTION 'Tidak bisa DM diri sendiri' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_me FROM profiles WHERE id = v_uid;
  SELECT * INTO v_o FROM profiles WHERE id = p_user AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak aktif' USING ERRCODE = '22023'; END IF;
  v_shared := EXISTS (SELECT 1 FROM chat_members a JOIN chat_members b ON b.channel_id = a.channel_id
                      JOIN chat_channels c ON c.id = a.channel_id AND c.type = 'contract' AND NOT c.is_archived
                      WHERE a.user_id = v_uid AND b.user_id = p_user);
  IF v_me.contractor_id IS NULL AND v_o.contractor_id IS NULL THEN NULL;                         -- WFRD ↔ WFRD
  ELSIF v_me.contractor_id IS NOT NULL AND v_me.contractor_id = v_o.contractor_id THEN NULL;     -- rekan satu perusahaan
  ELSIF v_me.contractor_id IS NOT NULL AND v_o.contractor_id IS NULL THEN                         -- contractor → WFRD
    IF NOT v_shared THEN PERFORM _deny('forbidden', 'Anda hanya bisa DM WFRD yang terlibat di kontrak Anda'); END IF;
  ELSIF v_me.contractor_id IS NULL AND v_o.contractor_id IS NOT NULL THEN                         -- WFRD → contractor
    IF NOT v_shared AND NOT has_permission('chat.dm.contractor') THEN PERFORM _deny('forbidden'); END IF;
  ELSE
    PERFORM _deny('forbidden', 'Contractor tidak bisa DM contractor lain');
  END IF;
  v_key := LEAST(v_uid::TEXT, p_user::TEXT) || ':' || GREATEST(v_uid::TEXT, p_user::TEXT);
  INSERT INTO chat_channels (type, direct_key, contractor_id, created_by)
  VALUES ('direct', v_key, COALESCE(v_me.contractor_id, v_o.contractor_id), v_uid)
  ON CONFLICT (direct_key) DO NOTHING RETURNING id INTO v_ch;
  IF v_ch IS NULL THEN SELECT id INTO v_ch FROM chat_channels WHERE direct_key = v_key; END IF;
  PERFORM _add_member(v_ch, v_uid, 'owner');
  PERFORM _add_member(v_ch, p_user, 'owner');
  RETURN v_ch;
END $$;

CREATE OR REPLACE FUNCTION create_group_channel(p_name TEXT, p_members UUID[], p_topic TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.group.create'); v_ch UUID; v_cids UUID[];
BEGIN
  IF cardinality(p_members) > 49 THEN RAISE EXCEPTION 'Grup maksimal 50 anggota' USING ERRCODE = '22023'; END IF;
  SELECT array_agg(DISTINCT contractor_id) INTO v_cids FROM profiles WHERE id = ANY(p_members) AND contractor_id IS NOT NULL;
  IF cardinality(v_cids) > 1 THEN RAISE EXCEPTION 'Grup maksimal berisi 1 perusahaan contractor' USING ERRCODE = '22023'; END IF;
  INSERT INTO chat_channels (type, name, topic, contractor_id, created_by)
  VALUES ('group', _clean_text(p_name, 120, TRUE), _clean_text(p_topic, 500), v_cids[1], v_uid) RETURNING id INTO v_ch;
  PERFORM _add_member(v_ch, v_uid, 'owner');
  INSERT INTO chat_members (channel_id, user_id, member_role)
  SELECT v_ch, p.id, 'member' FROM profiles p WHERE p.id = ANY(p_members) AND p.status = 'active' AND p.id <> v_uid
  ON CONFLICT DO NOTHING;
  RETURN v_ch;
END $$;

CREATE OR REPLACE FUNCTION get_or_create_task_thread(p_task UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use');
BEGIN
  IF NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  RETURN _ensure_task_thread(p_task);
END $$;

CREATE OR REPLACE FUNCTION create_announcement(p_name TEXT, p_audience JSONB, p_body TEXT, p_requires_ack BOOLEAN, p_priority TEXT DEFAULT 'important')
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.announce'); v_ch UUID;
BEGIN
  IF jsonb_typeof(p_audience) <> 'object' OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_audience) k
       WHERE k NOT IN ('all_contractors','contractor_ids','contract_ids','wfrd')) OR p_audience = '{}'::jsonb THEN
    RAISE EXCEPTION 'Audience tidak valid' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each(p_audience) e
             WHERE (e.key IN ('all_contractors','wfrd') AND jsonb_typeof(e.value) <> 'boolean')
                OR (e.key IN ('contractor_ids','contract_ids') AND (jsonb_typeof(e.value) <> 'array' OR jsonb_array_length(e.value) > 500))) THEN
    RAISE EXCEPTION 'Format audience tidak valid' USING ERRCODE = '22023'; END IF;
  INSERT INTO chat_channels (type, name, audience, created_by) VALUES ('announcement', _clean_text(p_name, 120, TRUE), p_audience, v_uid)
  RETURNING id INTO v_ch;
  PERFORM _add_member(v_ch, v_uid, 'owner');
  PERFORM _sync_announcement(v_ch);
  PERFORM _post_message(v_ch, v_uid, p_body, 'announcement', COALESCE(p_priority, 'important'), COALESCE(p_requires_ack, FALSE),
                        NULL, NULL, '{}', gen_random_uuid(), '{}');
  RETURN v_ch;
END $$;

CREATE OR REPLACE FUNCTION chat_add_members(p_channel UUID, p_users UUID[]) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, TRUE); v_ch chat_channels; v_n INT;
BEGIN
  SELECT * INTO v_ch FROM chat_channels WHERE id = p_channel;
  IF v_ch.type NOT IN ('group','contract') THEN RAISE EXCEPTION 'Anggota channel ini dikelola otomatis' USING ERRCODE = '22023'; END IF;
  IF NOT _is_channel_mod(p_channel, v_uid) THEN PERFORM _deny('forbidden'); END IF;
  IF v_ch.type = 'contract' AND EXISTS (SELECT 1 FROM profiles WHERE id = ANY(p_users) AND contractor_id IS NOT NULL) THEN
    RAISE EXCEPTION 'User contractor ditambahkan otomatis' USING ERRCODE = '22023'; END IF;
  IF v_ch.type = 'contract' AND EXISTS (SELECT 1 FROM unnest(p_users) u
       WHERE NOT _uid_has_contract_permission(u, 'contract.view', v_ch.contract_id)) THEN
    RAISE EXCEPTION 'User belum memiliki akses ke kontrak ini (beri role ber-scope kontrak dulu)' USING ERRCODE = '22023'; END IF;
  IF v_ch.type = 'group' AND (SELECT count(*) FROM chat_members WHERE channel_id = p_channel) + cardinality(p_users) > 50 THEN
    RAISE EXCEPTION 'Grup maksimal 50 anggota' USING ERRCODE = '22023'; END IF;
  INSERT INTO chat_members (channel_id, user_id, member_role)
  SELECT p_channel, p.id, 'member' FROM profiles p WHERE p.id = ANY(p_users) AND p.status = 'active'
  ON CONFLICT DO NOTHING;                                              -- trg_chat_isolation menolak campuran perusahaan
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION chat_remove_member(p_channel UUID, p_user UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, TRUE); v_ch chat_channels;
BEGIN
  SELECT * INTO v_ch FROM chat_channels WHERE id = p_channel;
  IF v_ch.type NOT IN ('group','contract') THEN RAISE EXCEPTION 'Anggota channel ini dikelola otomatis' USING ERRCODE = '22023'; END IF;
  IF NOT _is_channel_mod(p_channel, v_uid) THEN PERFORM _deny('forbidden'); END IF;
  IF _member_role(p_channel, p_user) = 'owner' THEN RAISE EXCEPTION 'Owner tidak bisa dikeluarkan' USING ERRCODE = '22023'; END IF;
  IF v_ch.type = 'contract' AND EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND (contractor_id IS NOT NULL OR is_root_admin)) THEN
    RAISE EXCEPTION 'Anggota ini dikelola otomatis' USING ERRCODE = '22023'; END IF;
  DELETE FROM chat_members WHERE channel_id = p_channel AND user_id = p_user;
END $$;

CREATE OR REPLACE FUNCTION leave_channel(p_channel UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE); v_ch chat_channels; v_next UUID;
BEGIN
  SELECT * INTO v_ch FROM chat_channels WHERE id = p_channel;
  IF v_ch.type <> 'group' THEN RAISE EXCEPTION 'Hanya grup yang bisa ditinggalkan (gunakan mute)' USING ERRCODE = '22023'; END IF;
  IF _member_role(p_channel, v_uid) = 'owner' THEN
    SELECT user_id INTO v_next FROM chat_members WHERE channel_id = p_channel AND user_id <> v_uid
      AND user_id IN (SELECT id FROM profiles WHERE contractor_id IS NULL AND status = 'active')
    ORDER BY (member_role = 'moderator') DESC, joined_at LIMIT 1;
    IF v_next IS NULL THEN UPDATE chat_channels SET is_archived = TRUE WHERE id = p_channel;
    ELSE UPDATE chat_members SET member_role = 'owner' WHERE channel_id = p_channel AND user_id = v_next; END IF;
  END IF;
  DELETE FROM chat_members WHERE channel_id = p_channel AND user_id = v_uid;
END $$;

CREATE OR REPLACE FUNCTION edit_message(p_message UUID, p_body TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID; v_body TEXT := _clean_text(p_body, 4000, TRUE); v_ver SMALLINT := _active_key_ver('chat');
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pesan tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_uid := _assert_chat_member(v_m.channel_id, TRUE);
  IF v_m.sender_id IS DISTINCT FROM v_uid OR v_m.kind <> 'text' OR v_m.deleted_at IS NOT NULL THEN PERFORM _deny('forbidden'); END IF;
  IF v_m.created_at < NOW() - INTERVAL '24 hours' THEN RAISE EXCEPTION 'Pesan hanya bisa diedit ≤ 24 jam' USING ERRCODE = '22023'; END IF;
  INSERT INTO chat_message_edits (message_id, prev_body_enc, key_ver) VALUES (p_message, v_m.body_enc, v_m.key_ver);
  UPDATE chat_messages SET body_enc = _encrypt(v_body, 'chat', v_ver), key_ver = v_ver, body_sha256 = encode(digest(v_body, 'sha256'), 'hex'),
                           edited_at = NOW() WHERE id = p_message;
  PERFORM _rt_send('chat:' || v_m.channel_id, 'message_updated', jsonb_build_object('id', p_message, 'seq', v_m.seq));
END $$;

CREATE OR REPLACE FUNCTION delete_message(p_message UUID, p_reason TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID; v_mod BOOLEAN;
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message FOR UPDATE;
  IF NOT FOUND OR v_m.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Pesan tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_uid := _assert_chat_member(v_m.channel_id, TRUE);
  v_mod := _is_channel_mod(v_m.channel_id, v_uid);
  IF v_m.sender_id IS DISTINCT FROM v_uid AND NOT v_mod THEN PERFORM _deny('forbidden'); END IF;
  IF v_m.sender_id IS DISTINCT FROM v_uid THEN PERFORM _require_reason(p_reason); END IF;
  UPDATE chat_messages SET deleted_at = NOW(), deleted_by = v_uid, delete_reason = _clean_text(p_reason, 500) WHERE id = p_message;
  PERFORM _rt_send('chat:' || v_m.channel_id, 'message_deleted', jsonb_build_object('id', p_message, 'seq', v_m.seq));
END $$;

CREATE OR REPLACE FUNCTION react_message(p_message UUID, p_emoji TEXT, p_on BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ch UUID; v_uid UUID;
BEGIN
  SELECT channel_id INTO v_ch FROM chat_messages WHERE id = p_message AND deleted_at IS NULL;
  v_uid := _assert_chat_member(v_ch, TRUE);
  IF p_emoji IS NULL OR length(p_emoji) NOT BETWEEN 1 AND 16 OR p_emoji ~ '[\x01-\x1F\x7F<>]' THEN RAISE EXCEPTION 'Emoji tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_on THEN
    IF (SELECT count(DISTINCT emoji) FROM chat_reactions WHERE message_id = p_message) >= 20 THEN RAISE EXCEPTION 'Terlalu banyak reaksi' USING ERRCODE = '22023'; END IF;
    INSERT INTO chat_reactions (message_id, user_id, emoji) VALUES (p_message, v_uid, p_emoji) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM chat_reactions WHERE message_id = p_message AND user_id = v_uid AND emoji = p_emoji;
  END IF;
  PERFORM _rt_send('chat:' || v_ch, 'reaction_changed', jsonb_build_object('id', p_message));
END $$;

CREATE OR REPLACE FUNCTION mark_read(p_channel UUID, p_seq BIGINT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
BEGIN
  UPDATE chat_members SET last_read_seq = GREATEST(last_read_seq, LEAST(p_seq, (SELECT COALESCE(max(seq), 0) FROM chat_messages WHERE channel_id = p_channel)))
  WHERE channel_id = p_channel AND user_id = v_uid;
  PERFORM _rt_send('user:' || v_uid, 'chat_read', jsonb_build_object('channel', p_channel, 'seq', p_seq));
END $$;

CREATE OR REPLACE FUNCTION ack_message(p_message UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID;
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message;
  v_uid := _assert_chat_member(v_m.channel_id, FALSE);
  IF NOT v_m.requires_ack THEN RAISE EXCEPTION 'Pesan ini tidak wajib dibaca' USING ERRCODE = '22023'; END IF;
  INSERT INTO chat_acks (message_id, user_id) VALUES (p_message, v_uid) ON CONFLICT DO NOTHING;
  UPDATE notifications SET read_at = NOW() WHERE user_id = v_uid AND dedupe_key = 'ack:' || p_message || ':' || v_uid;
END $$;

CREATE OR REPLACE FUNCTION get_ack_report(p_message UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID;
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message;
  v_uid := _assert_chat_member(v_m.channel_id, FALSE);
  IF v_m.sender_id IS DISTINCT FROM v_uid AND NOT _is_channel_mod(v_m.channel_id, v_uid) THEN PERFORM _deny('forbidden'); END IF;
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', cm.user_id, 'name', p.full_name, 'acked_at', a.acked_at) ORDER BY a.acked_at NULLS FIRST), '[]'::jsonb)
          FROM chat_members cm JOIN profiles p ON p.id = cm.user_id
          LEFT JOIN chat_acks a ON a.message_id = p_message AND a.user_id = cm.user_id
          WHERE cm.channel_id = v_m.channel_id AND cm.user_id IS DISTINCT FROM v_m.sender_id);
END $$;

CREATE OR REPLACE FUNCTION get_read_receipts(p_message UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID; v_type chat_channel_type;
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message;
  v_uid := _assert_chat_member(v_m.channel_id, FALSE);
  SELECT type INTO v_type FROM chat_channels WHERE id = v_m.channel_id;
  IF v_type NOT IN ('direct','group') AND v_m.sender_id IS DISTINCT FROM v_uid AND NOT _is_channel_mod(v_m.channel_id, v_uid) THEN
    PERFORM _deny('forbidden'); END IF;
  RETURN (SELECT COALESCE(jsonb_agg(cm.user_id), '[]'::jsonb) FROM chat_members cm
          WHERE cm.channel_id = v_m.channel_id AND cm.last_read_seq >= v_m.seq AND cm.user_id IS DISTINCT FROM v_m.sender_id
            AND can_see_chat_member(v_m.channel_id, cm.user_id));
END $$;

CREATE OR REPLACE FUNCTION pin_message(p_message UUID, p_on BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m chat_messages; v_uid UUID; v_type chat_channel_type;
BEGIN
  SELECT * INTO v_m FROM chat_messages WHERE id = p_message AND deleted_at IS NULL;
  v_uid := _assert_chat_member(v_m.channel_id, TRUE);
  SELECT type INTO v_type FROM chat_channels WHERE id = v_m.channel_id;
  IF v_type <> 'direct' AND NOT _is_channel_mod(v_m.channel_id, v_uid) THEN PERFORM _deny('forbidden'); END IF;
  IF p_on THEN
    IF (SELECT count(*) FROM chat_pins WHERE channel_id = v_m.channel_id) >= 50 THEN RAISE EXCEPTION 'Maksimal 50 pin' USING ERRCODE = '22023'; END IF;
    INSERT INTO chat_pins (channel_id, message_id, pinned_by) VALUES (v_m.channel_id, p_message, v_uid) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM chat_pins WHERE channel_id = v_m.channel_id AND message_id = p_message;
  END IF;
  PERFORM _rt_send('chat:' || v_m.channel_id, 'pins_changed', jsonb_build_object('id', p_message));
END $$;

CREATE OR REPLACE FUNCTION save_message(p_message UUID, p_on BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ch UUID; v_uid UUID;
BEGIN
  SELECT channel_id INTO v_ch FROM chat_messages WHERE id = p_message;
  v_uid := _assert_chat_member(v_ch, FALSE);
  IF p_on THEN INSERT INTO chat_saved (user_id, message_id) VALUES (v_uid, p_message) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM chat_saved WHERE user_id = v_uid AND message_id = p_message; END IF;
END $$;

CREATE OR REPLACE FUNCTION list_saved_messages() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', m.id, 'channel_id', m.channel_id, 'seq', m.seq, 'sender_id', m.sender_id,
            'body', CASE WHEN m.deleted_at IS NULL THEN _decrypt(m.body_enc, 'chat', m.key_ver) END, 'created_at', m.created_at,
            'saved_at', s.saved_at) ORDER BY s.saved_at DESC), '[]'::jsonb)
    FROM chat_saved s JOIN chat_messages m ON m.id = s.message_id
    JOIN chat_members cm ON cm.channel_id = m.channel_id AND cm.user_id = v_uid
    WHERE s.user_id = v_uid);
END $$;

CREATE OR REPLACE FUNCTION list_pins(p_channel UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', m.id, 'seq', m.seq, 'sender_id', m.sender_id,
            'body', CASE WHEN m.deleted_at IS NULL THEN _decrypt(m.body_enc, 'chat', m.key_ver) END, 'pinned_at', p.pinned_at)
            ORDER BY p.pinned_at DESC), '[]'::jsonb)
    FROM chat_pins p JOIN chat_messages m ON m.id = p.message_id WHERE p.channel_id = p_channel);
END $$;

-- ═════════════ TERJADWAL & BERULANG ═════════════
CREATE OR REPLACE FUNCTION schedule_message(p_channel UUID, p_body TEXT, p_send_at TIMESTAMPTZ, p_priority TEXT, p_requires_ack BOOLEAN,
  p_recur_freq TEXT, p_recur_dow SMALLINT[], p_recur_time TIME, p_recur_tz TEXT, p_recur_until DATE, p_task UUID DEFAULT NULL) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, TRUE); v_id UUID; v_ver SMALLINT := _active_key_ver('chat');
BEGIN
  IF _member_role(p_channel, v_uid) = 'readonly' THEN PERFORM _deny('forbidden'); END IF;
  IF (COALESCE(p_priority, 'normal') <> 'normal' OR p_requires_ack) AND NOT auth_is_wfrd() THEN PERFORM _deny('forbidden'); END IF;
  IF p_send_at IS NULL OR p_send_at <= NOW() OR p_send_at > NOW() + INTERVAL '1 year' THEN
    RAISE EXCEPTION 'Waktu kirim harus di masa depan (≤ 1 tahun)' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = COALESCE(p_recur_tz, 'Asia/Jakarta')) THEN
    RAISE EXCEPTION 'Zona waktu tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_recur_until IS NOT NULL AND p_recur_until < p_send_at::DATE THEN
    RAISE EXCEPTION 'Tanggal akhir pengulangan sebelum waktu kirim pertama' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM chat_scheduled WHERE sender_id = v_uid AND status = 'scheduled') >= 50 THEN
    RAISE EXCEPTION 'Maksimal 50 pesan terjadwal aktif' USING ERRCODE = '22023'; END IF;
  IF p_task IS NOT NULL AND NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  INSERT INTO chat_scheduled (channel_id, sender_id, body_enc, key_ver, priority, requires_ack, send_at, recur_freq, recur_dow, recur_time,
                              recur_tz, recur_until, task_id)
  VALUES (p_channel, v_uid, _encrypt(_clean_text(p_body, 4000, TRUE), 'chat', v_ver), v_ver, COALESCE(p_priority, 'normal'),
          COALESCE(p_requires_ack, FALSE), p_send_at, COALESCE(p_recur_freq, 'none'), p_recur_dow, p_recur_time,
          COALESCE(p_recur_tz, 'Asia/Jakarta'), p_recur_until, p_task)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION cancel_scheduled(p_id UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_s chat_scheduled; v_uid UUID := assert_access('chat.use');
BEGIN
  SELECT * INTO v_s FROM chat_scheduled WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR (v_s.sender_id <> v_uid AND NOT _is_channel_mod(v_s.channel_id, v_uid)) THEN PERFORM _deny('forbidden'); END IF;
  UPDATE chat_scheduled SET status = 'cancelled' WHERE id = p_id AND status = 'scheduled';
END $$;

CREATE OR REPLACE FUNCTION list_my_scheduled() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'channel_id', channel_id, 'send_at', send_at, 'recur_freq', recur_freq,
            'recur_dow', recur_dow, 'recur_time', recur_time, 'recur_tz', recur_tz, 'recur_until', recur_until, 'priority', priority,
            'requires_ack', requires_ack, 'status', status, 'body', _decrypt(body_enc, 'chat', key_ver)) ORDER BY send_at), '[]'::jsonb)
    FROM chat_scheduled WHERE sender_id = v_uid AND status = 'scheduled');
END $$;

-- ═════════════ PENCARIAN & NOTIFIKASI ═════════════
CREATE OR REPLACE FUNCTION search_messages(p_query TEXT, p_channel UUID DEFAULT NULL, p_limit INT DEFAULT 50) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, FALSE); v_q TEXT := _clean_text(p_query, 100, TRUE);
BEGIN
  IF length(v_q) < 2 THEN RAISE EXCEPTION 'Kata kunci minimal 2 karakter' USING ERRCODE = '22023'; END IF;
  PERFORM hit_rate_limit('chat_search:' || v_uid, 20, INTERVAL '1 minute');
  RETURN (SELECT COALESCE(jsonb_agg(r ORDER BY (r ->> 'seq')::BIGINT DESC), '[]'::jsonb) FROM (
    SELECT jsonb_build_object('id', id, 'channel_id', channel_id, 'seq', seq, 'sender_id', sender_id, 'created_at', created_at,
                              'snippet', left(body, 200)) AS r
    FROM (SELECT m.id, m.channel_id, m.seq, m.sender_id, m.created_at, _decrypt(m.body_enc, 'chat', m.key_ver) AS body
          FROM chat_messages m JOIN chat_members cm ON cm.channel_id = m.channel_id AND cm.user_id = v_uid
          WHERE m.deleted_at IS NULL AND m.created_at > NOW() - INTERVAL '90 days' AND (p_channel IS NULL OR m.channel_id = p_channel)
          ORDER BY m.seq DESC LIMIT 5000) d
    WHERE body ILIKE '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
    LIMIT LEAST(GREATEST(p_limit, 1), 50)) z);
END $$;

CREATE OR REPLACE FUNCTION chat_set_notify(p_channel UUID, p_level TEXT, p_muted_until TIMESTAMPTZ) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_chat_member(p_channel, FALSE);
BEGIN
  IF p_level NOT IN ('all','mentions','none') THEN RAISE EXCEPTION 'Level notifikasi tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE chat_members SET notify_level = p_level, muted_until = p_muted_until WHERE channel_id = p_channel AND user_id = v_uid;
END $$;

-- ═════════════ MODERASI & ADMIN CHAT ═════════════
CREATE OR REPLACE FUNCTION chat_moderate_member(p_channel UUID, p_user UUID, p_silenced_until TIMESTAMPTZ, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE); v_reason TEXT := _require_reason(p_reason);
BEGIN
  IF NOT _is_channel_mod(p_channel, v_uid) THEN PERFORM _deny('forbidden'); END IF;
  IF _member_role(p_channel, p_user) IN ('owner') THEN RAISE EXCEPTION 'Owner tidak bisa dibungkam' USING ERRCODE = '22023'; END IF;
  UPDATE chat_members SET silenced_until = p_silenced_until WHERE channel_id = p_channel AND user_id = p_user;
  PERFORM _security_event(p_user, 'chat_moderation', 'info', jsonb_build_object('channel', p_channel, 'until', p_silenced_until, 'reason', v_reason, 'by', v_uid));
END $$;

-- p_patch keys: is_locked, is_archived, legal_hold, retention_days, name, topic
CREATE OR REPLACE FUNCTION admin_chat_set_channel(p_channel UUID, p_patch JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.chat.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_patch) k WHERE k NOT IN ('is_locked','is_archived','legal_hold','retention_days','name','topic')) THEN
    RAISE EXCEPTION 'Field tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE chat_channels SET
    is_locked = COALESCE((p_patch ->> 'is_locked')::BOOLEAN, is_locked), is_archived = COALESCE((p_patch ->> 'is_archived')::BOOLEAN, is_archived),
    legal_hold = COALESCE((p_patch ->> 'legal_hold')::BOOLEAN, legal_hold), retention_days = COALESCE((p_patch ->> 'retention_days')::INT, retention_days),
    name = COALESCE(_clean_text(p_patch ->> 'name', 120), name),
    topic = CASE WHEN p_patch ? 'topic' THEN _clean_text(p_patch ->> 'topic', 500) ELSE topic END
  WHERE id = p_channel;
  IF NOT FOUND THEN RAISE EXCEPTION 'Channel tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(v_uid, 'chat_admin', 'info', jsonb_build_object('channel', p_channel, 'patch', p_patch, 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_list_channels(p_search TEXT DEFAULT NULL, p_limit INT DEFAULT 100) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_access('admin.chat.manage', NULL, FALSE);
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) FROM (
    SELECT c.id, c.type, c.name, c.contract_id, c.is_locked, c.is_archived, c.legal_hold, c.retention_days, c.last_message_at,
           (SELECT count(*) FROM chat_members m WHERE m.channel_id = c.id) AS members
    FROM chat_channels c
    WHERE c.type <> 'direct' AND (p_search IS NULL OR c.name ILIKE '%' || _clean_text(p_search, 100) || '%')
    ORDER BY c.last_message_at DESC NULLS LAST LIMIT LEAST(GREATEST(p_limit, 1), 500)) x);
END $$;

CREATE OR REPLACE FUNCTION chat_export(p_channel UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.export'); v_reason TEXT := _require_reason(p_reason); v_data JSONB;
BEGIN
  PERFORM hit_rate_limit('export:' || v_uid, 3, INTERVAL '1 hour');
  SELECT jsonb_build_object(
    'channel', (SELECT jsonb_build_object('id', id, 'type', type, 'name', name) FROM chat_channels WHERE id = p_channel),
    'from', p_from, 'to', p_to, 'exported_by', v_uid, 'exported_at', NOW(),
    'messages', COALESCE(jsonb_agg(jsonb_build_object('seq', m.seq, 'at', m.created_at, 'sender', COALESCE(p.full_name, 'COMEN Bot'),
                  'body', _decrypt(m.body_enc, 'chat', m.key_ver), 'deleted_at', m.deleted_at, 'edited_at', m.edited_at,
                  'sha256', m.body_sha256) ORDER BY m.seq), '[]'::jsonb))
  INTO v_data
  FROM chat_messages m LEFT JOIN profiles p ON p.id = m.sender_id
  WHERE m.channel_id = p_channel AND m.created_at >= p_from AND m.created_at < p_to;
  PERFORM _security_event(v_uid, 'export', 'warning', jsonb_build_object('kind', 'chat', 'channel', p_channel, 'reason', v_reason,
                          'manifest_sha256', encode(digest(v_data::TEXT, 'sha256'), 'hex')));
  RETURN jsonb_build_object('data', v_data, 'manifest_sha256', encode(digest(v_data::TEXT, 'sha256'), 'hex'));
END $$;
