-- ═════════════ AUTH ═════════════
CREATE OR REPLACE FUNCTION handle_user_email_changed() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  UPDATE profiles SET email = lower(NEW.email) WHERE id = NEW.id AND anonymized_at IS NULL AND email <> lower(NEW.email);
  RETURN NEW;
EXCEPTION WHEN unique_violation THEN
  INSERT INTO security_events (user_id, event, severity, detail) VALUES (NEW.id, 'email_conflict', 'warning', jsonb_build_object('email', NEW.email));
  RETURN NEW;
END $$;

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
CREATE TRIGGER on_auth_user_confirmed AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_confirmed();
CREATE TRIGGER on_auth_user_email_changed AFTER UPDATE OF email ON auth.users
  FOR EACH ROW WHEN (OLD.email IS DISTINCT FROM NEW.email AND NEW.email IS NOT NULL)
  EXECUTE FUNCTION public.handle_user_email_changed();

-- ═════════════ UTILITAS ═════════════
CREATE OR REPLACE FUNCTION _touch_updated_at() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END $$;

DO $$ DECLARE t TEXT; BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','roles','app_settings','contractors','contracts','upload_links','tasks',
                           'self_assessments','risk_items','manning','incidents','opr_reviews'] LOOP
    EXECUTE format('CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION _touch_updated_at()', t);
  END LOOP;
END $$;

-- Hanya svc_retention (SET LOCAL comen.retention_purge = 'on', konteks sistem) yang boleh menghapus
CREATE OR REPLACE FUNCTION _append_only() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND auth.uid() IS NULL AND current_setting('comen.retention_purge', TRUE) = 'on' THEN RETURN OLD; END IF;
  RAISE EXCEPTION '% bersifat append-only', TG_TABLE_NAME USING ERRCODE = '42501';
END $$;
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON task_events        FOR EACH ROW EXECUTE FUNCTION _append_only();
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON signatures         FOR EACH ROW EXECUTE FUNCTION _append_only();
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON chat_message_edits FOR EACH ROW EXECUTE FUNCTION _append_only();
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON vendor_evaluations FOR EACH ROW EXECUTE FUNCTION _append_only();
-- Nomor kontrak: CTR-{tahun award}-{seq 5 digit}
CREATE OR REPLACE FUNCTION _contract_no() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.contract_no := 'CTR-' || to_char(NEW.awarded_at, 'YYYY') || '-' || lpad(NEW.contract_seq::TEXT, 5, '0');
  RETURN NEW;
END $$;
CREATE TRIGGER trg_contract_no BEFORE INSERT ON contracts FOR EACH ROW EXECUTE FUNCTION _contract_no();

CREATE OR REPLACE FUNCTION _contracts_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_no IS DISTINCT FROM OLD.contract_no OR NEW.contract_seq <> OLD.contract_seq OR NEW.contractor_id <> OLD.contractor_id THEN
    RAISE EXCEPTION 'Nomor & contractor kontrak immutable' USING ERRCODE = '42501'; END IF;
  IF OLD.status IN ('closed','terminated') AND auth.uid() IS NOT NULL
     AND (to_jsonb(NEW) - ARRAY['updated_at','health_flag']) <> (to_jsonb(OLD) - ARRAY['updated_at','health_flag']) THEN
    RAISE EXCEPTION 'Kontrak final tidak bisa diubah' USING ERRCODE = '42501'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_contracts_guard BEFORE UPDATE ON contracts FOR EACH ROW EXECUTE FUNCTION _contracts_guard();

-- ═════════════ GUARD IDENTITAS & RBAC ═════════════
CREATE OR REPLACE FUNCTION _profiles_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_actor UUID := auth.uid();
BEGIN
  IF NEW.is_root_admin AND NOT EXISTS (SELECT 1 FROM admin_allowlist WHERE email = NEW.email) THEN
    RAISE EXCEPTION 'Root admin hanya untuk email allowlist' USING ERRCODE = '42501'; END IF;
  IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;

  IF NEW.id <> OLD.id THEN RAISE EXCEPTION 'ID profil immutable' USING ERRCODE = '42501'; END IF;
  IF v_actor IS NOT NULL THEN
    IF NEW.email <> OLD.email AND NEW.anonymized_at IS NULL THEN
      RAISE EXCEPTION 'Email dikelola oleh Supabase Auth' USING ERRCODE = '42501'; END IF;
    IF OLD.anonymized_at IS NOT NULL THEN
      RAISE EXCEPTION 'Profil teranonimkan tidak bisa diubah' USING ERRCODE = '42501'; END IF;
    IF OLD.is_root_admin THEN
      IF NOT NEW.is_root_admin OR NEW.status <> 'active' OR NEW.contractor_id IS NOT NULL OR NEW.anonymized_at IS NOT NULL THEN
        RAISE EXCEPTION 'Root admin tidak bisa dilemahkan dari aplikasi' USING ERRCODE = '42501'; END IF;
      IF NEW.sessions_valid_after <> OLD.sessions_valid_after
         AND NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_actor AND is_root_admin) THEN
        RAISE EXCEPTION 'Hanya root admin yang bisa me-logout root admin' USING ERRCODE = '42501'; END IF;
    END IF;
  END IF;

  IF NEW.contractor_id IS DISTINCT FROM OLD.contractor_id THEN
    IF NEW.contractor_id IS NOT NULL AND EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                                 WHERE ur.user_id = NEW.id AND r.is_wfrd) THEN
      RAISE EXCEPTION 'User ber-role WFRD tidak bisa dijadikan user contractor' USING ERRCODE = '22023'; END IF;
    IF NEW.contractor_id IS NULL AND EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                             WHERE ur.user_id = NEW.id AND NOT r.is_wfrd) THEN
      RAISE EXCEPTION 'Cabut role contractor sebelum melepas perusahaan' USING ERRCODE = '22023'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_profiles_guard BEFORE INSERT OR UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION _profiles_guard();

-- Setelah status/perusahaan berubah: keluarkan dari percakapan perusahaan lama + sinkron chat
CREATE OR REPLACE FUNCTION _profiles_after() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k UUID; v_a UUID;
BEGIN
  IF NEW.contractor_id IS DISTINCT FROM OLD.contractor_id AND OLD.contractor_id IS NOT NULL THEN
    DELETE FROM chat_members m USING chat_channels c
    WHERE m.user_id = NEW.id AND c.id = m.channel_id AND c.type <> 'announcement' AND c.contractor_id = OLD.contractor_id;
  END IF;
  FOR v_k IN
    SELECT id FROM contracts WHERE contractor_id IN (OLD.contractor_id, NEW.contractor_id) AND status NOT IN ('closed','terminated')
    UNION
    SELECT c.contract_id FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id AND c.type = 'contract' AND NOT c.is_archived
    WHERE m.user_id = NEW.id
  LOOP
    PERFORM _sync_contract_channel(v_k);
  END LOOP;
  FOR v_a IN SELECT id FROM chat_channels WHERE type = 'announcement' AND NOT is_archived LOOP
    PERFORM _sync_announcement(v_a);
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_profiles_after AFTER UPDATE OF status, contractor_id ON profiles
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.contractor_id IS DISTINCT FROM NEW.contractor_id)
  EXECUTE FUNCTION _profiles_after();

CREATE OR REPLACE FUNCTION _user_roles_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_role roles; v_p profiles; v_actor UUID := auth.uid();
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT * INTO v_role FROM roles WHERE id = OLD.role_id;
    SELECT * INTO v_p FROM profiles WHERE id = OLD.user_id;
    IF v_actor IS NOT NULL AND v_role.key = 'super_admin' AND v_p.is_root_admin
       AND (TG_OP = 'DELETE' OR NEW.expires_at IS NOT NULL) THEN
      RAISE EXCEPTION 'Role root admin tidak bisa dicabut' USING ERRCODE = '42501'; END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    IF NEW.user_id <> OLD.user_id OR NEW.role_id <> OLD.role_id OR NEW.scope_type <> OLD.scope_type
       OR NEW.scope_id IS DISTINCT FROM OLD.scope_id THEN
      RAISE EXCEPTION 'Penugasan role immutable (cabut & beri ulang)' USING ERRCODE = '42501'; END IF;
  END IF;

  SELECT * INTO v_role FROM roles WHERE id = NEW.role_id;
  SELECT * INTO v_p FROM profiles WHERE id = NEW.user_id;
  IF v_role.key = 'super_admin' AND NOT (v_p.is_root_admin AND NEW.scope_type = 'global' AND NEW.expires_at IS NULL
       AND EXISTS (SELECT 1 FROM admin_allowlist WHERE email = v_p.email)) THEN
    RAISE EXCEPTION 'super_admin hanya untuk root admin (allowlist)' USING ERRCODE = '42501'; END IF;
  IF v_role.is_wfrd AND v_p.contractor_id IS NOT NULL THEN
    RAISE EXCEPTION 'Role WFRD tidak bisa diberikan ke user contractor' USING ERRCODE = '22023'; END IF;
  IF NOT v_role.is_wfrd THEN
    IF v_p.contractor_id IS NULL THEN RAISE EXCEPTION 'Role contractor butuh user yang terhubung ke perusahaan' USING ERRCODE = '22023'; END IF;
    IF NEW.scope_type <> 'global' THEN       -- Part 4.1 aturan 1: isolasi contractor via contractor_id, bukan scope
      RAISE EXCEPTION 'Role contractor selalu ber-scope global' USING ERRCODE = '22023'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_user_roles_guard BEFORE INSERT OR UPDATE OR DELETE ON user_roles FOR EACH ROW EXECUTE FUNCTION _user_roles_guard();

CREATE OR REPLACE FUNCTION _user_roles_after() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r user_roles; v_k UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  IF r.scope_type = 'contract' THEN PERFORM _sync_contract_channel(r.scope_id::UUID); END IF;   -- cast hanya untuk scope kontrak
  FOR v_k IN
    SELECT c.id FROM contracts c JOIN profiles p ON p.contractor_id = c.contractor_id
    WHERE p.id = r.user_id AND c.status NOT IN ('closed','terminated')
    UNION
    SELECT ch.contract_id FROM chat_members m JOIN chat_channels ch ON ch.id = m.channel_id AND ch.type = 'contract' AND NOT ch.is_archived
    WHERE m.user_id = r.user_id AND TG_OP <> 'INSERT'
  LOOP
    PERFORM _sync_contract_channel(v_k);
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_user_roles_after AFTER INSERT OR UPDATE OR DELETE ON user_roles FOR EACH ROW EXECUTE FUNCTION _user_roles_after();

CREATE OR REPLACE FUNCTION _roles_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF OLD.is_system THEN RAISE EXCEPTION 'Role sistem tidak bisa dihapus' USING ERRCODE = '42501'; END IF;
    IF EXISTS (SELECT 1 FROM user_roles WHERE role_id = OLD.id) OR EXISTS (SELECT 1 FROM user_invites WHERE role_id = OLD.id AND accepted_at IS NULL AND revoked_at IS NULL) THEN
      RAISE EXCEPTION 'Role masih dipakai user/undangan' USING ERRCODE = '22023'; END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.is_system OR NEW.key = 'super_admin' THEN RAISE EXCEPTION 'Role sistem hanya dari seed' USING ERRCODE = '42501'; END IF;
    RETURN NEW;
  END IF;
  IF NEW.key <> OLD.key AND OLD.is_system THEN RAISE EXCEPTION 'Key role sistem immutable' USING ERRCODE = '42501'; END IF;
  IF NEW.is_system <> OLD.is_system THEN RAISE EXCEPTION 'Flag sistem immutable' USING ERRCODE = '42501'; END IF;
  IF NEW.is_wfrd <> OLD.is_wfrd AND (EXISTS (SELECT 1 FROM user_roles WHERE role_id = OLD.id)
                                     OR EXISTS (SELECT 1 FROM role_permissions WHERE role_id = OLD.id)) THEN
    RAISE EXCEPTION 'Audience role tidak bisa diubah selagi punya user/permission' USING ERRCODE = '22023'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_roles_guard BEFORE INSERT OR UPDATE OR DELETE ON roles FOR EACH ROW EXECUTE FUNCTION _roles_guard();

-- '*' hanya untuk super_admin; audience permission wajib cocok dengan audience role; super_admin terkunci
CREATE OR REPLACE FUNCTION _role_permissions_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_role roles; v_aud TEXT; r role_permissions;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  SELECT * INTO v_role FROM roles WHERE id = r.role_id;
  IF v_role.key = 'super_admin' AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'Permission super_admin terkunci' USING ERRCODE = '42501'; END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'Gunakan hapus + tambah' USING ERRCODE = '42501'; END IF;
  IF NEW.permission_key = '*' AND v_role.key <> 'super_admin' THEN
    RAISE EXCEPTION 'Wildcard hanya untuk super_admin' USING ERRCODE = '42501'; END IF;
  SELECT audience INTO v_aud FROM permissions WHERE key = NEW.permission_key;
  IF NEW.permission_key <> '*' AND ((v_role.is_wfrd AND v_aud = 'contractor') OR (NOT v_role.is_wfrd AND v_aud = 'wfrd')) THEN
    RAISE EXCEPTION 'Permission % (audience %) tidak cocok untuk role ini', NEW.permission_key, v_aud USING ERRCODE = '22023'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_role_permissions_guard BEFORE INSERT OR UPDATE OR DELETE ON role_permissions
  FOR EACH ROW EXECUTE FUNCTION _role_permissions_guard();

-- ═════════════ TASK ═════════════
CREATE OR REPLACE FUNCTION _tasks_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Task tidak bisa dihapus (gunakan cancel/waive)' USING ERRCODE = '42501'; END IF;
  IF (NEW.id, NEW.task_id, NEW.revision, NEW.scope, NEW.contractor_id, NEW.contract_id, NEW.subcontractor_id, NEW.doc_type_code,
      NEW.kind, NEW.phase, NEW.parent_task_id, NEW.renewal_of, NEW.created_by, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.task_id, OLD.revision, OLD.scope, OLD.contractor_id, OLD.contract_id, OLD.subcontractor_id, OLD.doc_type_code,
      OLD.kind, OLD.phase, OLD.parent_task_id, OLD.renewal_of, OLD.created_by, OLD.created_at) THEN
    RAISE EXCEPTION 'Identitas task immutable' USING ERRCODE = '42501'; END IF;

  IF NEW.status = OLD.status THEN
    IF OLD.status IN ('approved','expired','revise','superseded','waived','cancelled')
       AND (to_jsonb(NEW) - ARRAY['updated_at','base_task_id']) <> (to_jsonb(OLD) - ARRAY['updated_at','base_task_id']) THEN
      RAISE EXCEPTION 'Task % berstatus % tidak bisa diubah', OLD.task_id, OLD.status USING ERRCODE = '42501'; END IF;
    RETURN NEW;
  END IF;

  v_ok := CASE OLD.status
    WHEN 'open'           THEN NEW.status IN ('awaiting_email','submitted','waived','cancelled','approved')
    WHEN 'awaiting_email' THEN NEW.status IN ('submitted','waived','cancelled')
    WHEN 'file_issue'     THEN NEW.status IN ('awaiting_email','submitted','waived','cancelled')
    WHEN 'submitted'      THEN NEW.status IN ('under_review','approved','revise','rejected','file_issue','waived','cancelled')
    WHEN 'under_review'   THEN NEW.status IN ('approved','revise','rejected','file_issue','waived','cancelled')
    WHEN 'rejected'       THEN NEW.status IN ('revise','waived','cancelled')
    WHEN 'approved'       THEN NEW.status IN ('expired','superseded')
    WHEN 'expired'        THEN NEW.status = 'superseded'
    ELSE FALSE END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transisi task % → % tidak diizinkan', OLD.status, NEW.status USING ERRCODE = '22023'; END IF;
  IF OLD.status = 'open' AND NEW.status = 'approved' AND NEW.kind <> 'action' THEN
    RAISE EXCEPTION 'Hanya action WFRD yang bisa langsung selesai' USING ERRCODE = '22023'; END IF;
  IF NEW.status = 'superseded' AND NEW.superseded_by IS NULL THEN
    RAISE EXCEPTION 'superseded_by wajib' USING ERRCODE = '22023'; END IF;
  IF NEW.doc_type_code = 'FNDCLS' THEN
    IF NEW.status = 'waived' THEN
      RAISE EXCEPTION 'Penutupan finding tidak bisa di-waive — gunakan Cancel Finding' USING ERRCODE = '22023'; END IF;
    IF NEW.status = 'cancelled'
       AND NOT EXISTS (SELECT 1 FROM audit_findings f WHERE f.contract_id = NEW.contract_id AND f.finding_no = NEW.source_ref AND f.status = 'cancelled')
       AND NOT EXISTS (SELECT 1 FROM contracts k WHERE k.id = NEW.contract_id AND k.status = 'terminated') THEN
      RAISE EXCEPTION 'Penutupan finding hanya batal lewat Cancel Finding' USING ERRCODE = '22023'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_tasks_immutable BEFORE UPDATE OR DELETE ON tasks FOR EACH ROW EXECUTE FUNCTION _tasks_guard();

CREATE OR REPLACE FUNCTION _task_side_effects() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NEW.status = 'approved' THEN
    IF NEW.doc_type_code = 'FNDCLS' THEN
      UPDATE audit_findings SET status = 'closed', verified_by = NEW.reviewed_by, verified_at = NOW()
      WHERE fndcls_task_id = NEW.id AND status IN ('open','closure_submitted');
    END IF;
    IF NEW.renewal_of IS NOT NULL THEN
      UPDATE tasks SET status = 'superseded', superseded_by = NEW.id, status_reason = 'Diperbarui oleh ' || NEW.task_id
      WHERE id = NEW.renewal_of AND status IN ('approved','expired');
    END IF;
  ELSIF NEW.status IN ('rejected','file_issue') AND NEW.doc_type_code = 'FNDCLS' THEN
    UPDATE audit_findings SET status = 'open' WHERE fndcls_task_id = NEW.id AND status = 'closure_submitted';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_task_side_effects AFTER UPDATE OF status ON tasks
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION _task_side_effects();

-- ═════════════ CHAT ═════════════
CREATE OR REPLACE FUNCTION _chat_isolation() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ch chat_channels; v_cid UUID;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.channel_id <> OLD.channel_id OR NEW.user_id <> OLD.user_id) THEN
    RAISE EXCEPTION 'Keanggotaan immutable' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_ch FROM chat_channels WHERE id = NEW.channel_id FOR UPDATE;
  SELECT contractor_id INTO v_cid FROM profiles WHERE id = NEW.user_id;
  IF v_cid IS NULL THEN RETURN NEW; END IF;
  IF v_ch.type = 'announcement' THEN NEW.member_role := 'readonly'; RETURN NEW; END IF;
  IF v_ch.contractor_id IS NOT NULL AND v_ch.contractor_id <> v_cid THEN
    RAISE EXCEPTION 'Channel ini milik perusahaan contractor lain' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM chat_members m JOIN profiles p ON p.id = m.user_id
             WHERE m.channel_id = NEW.channel_id AND p.contractor_id IS NOT NULL AND p.contractor_id <> v_cid) THEN
    RAISE EXCEPTION 'Satu percakapan maksimal berisi 1 perusahaan contractor' USING ERRCODE = '42501'; END IF;
  IF v_ch.contractor_id IS NULL THEN UPDATE chat_channels SET contractor_id = v_cid WHERE id = NEW.channel_id; END IF;
  IF v_ch.type <> 'direct' AND NEW.member_role IN ('owner','moderator') THEN NEW.member_role := 'member'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_chat_isolation BEFORE INSERT OR UPDATE ON chat_members FOR EACH ROW EXECUTE FUNCTION _chat_isolation();

CREATE OR REPLACE FUNCTION _chat_channels_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type <> OLD.type OR NEW.direct_key IS DISTINCT FROM OLD.direct_key OR NEW.contract_id IS DISTINCT FROM OLD.contract_id
     OR NEW.task_id IS DISTINCT FROM OLD.task_id
     OR (OLD.contractor_id IS NOT NULL AND NEW.contractor_id IS DISTINCT FROM OLD.contractor_id) THEN
    RAISE EXCEPTION 'Identitas channel immutable' USING ERRCODE = '42501'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_chat_channels_guard BEFORE UPDATE ON chat_channels FOR EACH ROW EXECUTE FUNCTION _chat_channels_guard();

CREATE OR REPLACE FUNCTION _chat_messages_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF auth.uid() IS NOT NULL OR current_setting('comen.retention_purge', TRUE) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'Pesan hanya dihapus lunak' USING ERRCODE = '42501'; END IF;
    RETURN OLD;
  END IF;
  IF NEW.channel_id <> OLD.channel_id OR NEW.sender_id IS DISTINCT FROM OLD.sender_id OR NEW.seq <> OLD.seq
     OR NEW.created_at <> OLD.created_at OR NEW.kind <> OLD.kind OR NEW.thread_root IS DISTINCT FROM OLD.thread_root THEN
    RAISE EXCEPTION 'Metadata pesan immutable' USING ERRCODE = '42501'; END IF;
  IF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
    RAISE EXCEPTION 'Pesan terhapus tidak bisa dipulihkan' USING ERRCODE = '42501'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_chat_messages_guard BEFORE UPDATE OR DELETE ON chat_messages FOR EACH ROW EXECUTE FUNCTION _chat_messages_guard();

-- ═════════════ AUDIT (hash chain) ═════════════
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('admin_allowlist', 'email'), ('geozones', 'code'), ('profiles', 'id'), ('roles', 'id'), ('permissions', 'key'),
    ('role_permissions', 'role_id,permission_key'), ('user_roles', 'id'), ('user_invites', 'id'), ('trusted_devices', 'id'),
    ('app_settings', 'key'), ('holidays', 'id'), ('contractors', 'id'), ('contracts', 'id'), ('subcontractors', 'id'),
    ('doc_type_catalog', 'code'), ('contract_requirements', 'contract_id,doc_type_code'), ('upload_links', 'id'),
    ('tasks', 'id'), ('checklist_items', 'id'), ('self_assessments', 'id'), ('vendor_evaluations', 'id'), ('meetings', 'id'),
    ('meeting_attendees', 'id'), ('signatures', 'id'), ('risk_items', 'id'), ('audits', 'id'), ('inspections', 'id'),
    ('audit_findings', 'id'), ('manning', 'id'), ('daily_briefings', 'id'), ('bbs_observations', 'id'),
    ('stop_work_events', 'id'), ('incidents', 'id'), ('opr_reviews', 'id'), ('chat_channels', 'id'),
    ('chat_members', 'channel_id,user_id'), ('chat_pins', 'channel_id,message_id'), ('chat_scheduled', 'id')) v(t, pk)
  LOOP
    EXECUTE format('CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION log_change(%s)',
                   r.t, (SELECT string_agg(quote_literal(x), ',') FROM unnest(string_to_array(r.pk, ',')) x));
  END LOOP;
END $$;
-- Pesan chat: hanya edit/hapus/moderasi yang diaudit (INSERT terlalu sering; integritas via body_sha256)
CREATE TRIGGER trg_audit AFTER UPDATE ON chat_messages FOR EACH ROW EXECUTE FUNCTION log_change('id');
