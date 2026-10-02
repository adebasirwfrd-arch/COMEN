-- ═════════════ HELPER POLICY (di-GRANT ke authenticated) ═════════════
-- Gerbang dasar semua policy: akun aktif + perangkat ok + (role MFA-wajib ⇒ aal2)
CREATE OR REPLACE FUNCTION rls_ok() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT device_ok() AND auth_is_active() AND (auth_aal() = 'aal2' OR NOT user_requires_mfa(auth.uid()))
$$;

-- Baca data admin: WFRD + aal2 + permission global (selaras assert_access untuk admin.*)
CREATE OR REPLACE FUNCTION rls_admin(p_perm TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT auth_is_wfrd() AND auth_aal() = 'aal2' AND has_permission(p_perm)
$$;

-- Data turunan kontrak: contractor pemilik · PO/reviewer kontrak · WFRD dengan permission ber-scope
CREATE OR REPLACE FUNCTION can_read_contract_data(p_perm TEXT, p_contract UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
    SELECT 1 FROM contracts c
    WHERE c.id = p_contract AND (
         c.contractor_id = auth_contractor_id()
      OR (auth_is_wfrd() AND (auth.uid() IN (c.process_owner_id, c.hse_reviewer_id) OR has_contract_permission(p_perm, c.id)))))
$$;

CREATE OR REPLACE FUNCTION can_view_contractor(p_contractor UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT p_contractor IS NOT NULL AND (
       p_contractor = auth_contractor_id()
    OR (auth_is_wfrd() AND (
           has_contractor_permission('vendor.view', p_contractor)
        OR has_contractor_permission('contract.view', p_contractor)
        OR has_contractor_permission('task.view', p_contractor)
        OR EXISTS (SELECT 1 FROM contracts c WHERE c.contractor_id = p_contractor AND auth.uid() IN (c.process_owner_id, c.hse_reviewer_id))
        OR EXISTS (SELECT 1 FROM tasks t WHERE t.contractor_id = p_contractor AND auth.uid() IN (t.reviewer_id, t.assigned_to)))))
$$;

-- Presence (siapa online) tidak diizinkan di announcement → identitas contractor lain tidak bocor (dipakai 14.17)
CREATE OR REPLACE FUNCTION can_presence_chat(p_channel UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT is_chat_member(p_channel) AND EXISTS (
    SELECT 1 FROM chat_channels c WHERE c.id = p_channel AND c.type <> 'announcement' AND NOT c.is_archived)
$$;

-- ═════════════ RPC BACA PELENGKAP ═════════════
-- Perangkat milik sendiri (device_hash tidak pernah dikirim ke klien)
CREATE OR REPLACE FUNCTION list_my_devices() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_hash TEXT := request_device_hash();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'first_seen', d.first_seen, 'last_seen', d.last_seen,
                       'revoked_at', d.revoked_at, 'revoke_reason', d.revoke_reason, 'is_current', d.device_hash = v_hash,
                       'push_enabled', EXISTS (SELECT 1 FROM push_subscriptions s WHERE s.device_id = d.id))
                     ORDER BY d.revoked_at NULLS FIRST, d.last_seen DESC)
    FROM trusted_devices d WHERE d.user_id = v_uid), '[]'::jsonb);
END $$;

-- Detail vendor: telepon didekripsi; internal_notes & evaluasi hanya WFRD vendor.view
CREATE OR REPLACE FUNCTION get_contractor_detail(p_contractor UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_c contractors; v_wfrd BOOLEAN := auth_is_wfrd(); v_vendor BOOLEAN; v_full BOOLEAN;
BEGIN
  IF NOT can_view_contractor(p_contractor) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor;
  v_vendor := v_wfrd AND has_contractor_permission('vendor.view', p_contractor);
  v_full := (NOT v_wfrd) OR v_vendor;
  RETURN (to_jsonb(v_c) - 'primary_contact_phone_enc' - 'enc_key_ver' - 'internal_notes') || jsonb_build_object(
    'vendor_ref', _vendor_ref(p_contractor),
    'primary_contact_phone', CASE WHEN v_full THEN _decrypt(v_c.primary_contact_phone_enc, 'data', v_c.enc_key_ver) END,
    'internal_notes', CASE WHEN v_vendor THEN v_c.internal_notes END,
    'self_assessments', CASE WHEN v_full THEN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'year', s.period_year, 'status', s.status, 'computed', s.computed,
                                                     'submitted_at', s.submitted_at) ORDER BY s.period_year DESC), '[]'::jsonb)
        FROM self_assessments s WHERE s.contractor_id = p_contractor) END,
    'evaluations', CASE WHEN v_vendor THEN (
        SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.screened_at DESC), '[]'::jsonb)
        FROM vendor_evaluations e WHERE e.contractor_id = p_contractor) END,
    'contracts', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', k.id, 'contract_no', k.contract_no, 'title', k.title,
                                  'status', k.status, 'health_flag', k.health_flag) ORDER BY k.contract_seq DESC), '[]'::jsonb)
                  FROM contracts k WHERE k.contractor_id = p_contractor AND can_view_contract(k.id)),
    'can_manage', v_wfrd AND auth_aal() = 'aal2' AND has_permission('admin.contractors.manage'),
    'can_screen', v_wfrd AND has_contractor_permission('vendor.screen', p_contractor),
    'can_decide_asl', v_wfrd AND has_contractor_permission('vendor.asl.decide', p_contractor));
END $$;

-- Ringkasan dashboard. SECURITY INVOKER (sengaja): RLS pemanggil menyaring semua angka.
CREATE OR REPLACE FUNCTION get_dashboard() RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, extensions AS $$
  SELECT jsonb_build_object(
    'tasks_open',      (SELECT count(*) FROM tasks WHERE status IN ('open','awaiting_email','file_issue')),
    'tasks_overdue',   (SELECT count(*) FROM tasks WHERE status IN ('open','awaiting_email','file_issue') AND due_date < business_today()),
    'tasks_due_7d',    (SELECT count(*) FROM tasks WHERE status IN ('open','awaiting_email','file_issue')
                          AND due_date BETWEEN business_today() AND business_today() + 7),
    'tasks_in_review', (SELECT count(*) FROM tasks WHERE status IN ('submitted','under_review')),
    'review_overdue',  (SELECT count(*) FROM tasks WHERE status IN ('submitted','under_review') AND review_due_at < NOW()),
    'contracts_by_status', (SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb)
                            FROM (SELECT status, count(*) AS n FROM contracts GROUP BY status) s),
    'contracts_red',   (SELECT count(*) FROM contracts WHERE health_flag = 'red' AND status NOT IN ('closed','terminated')),
    'incidents_open',  (SELECT count(*) FROM incidents WHERE status <> 'closed'),
    'findings_open',   (SELECT count(*) FROM audit_findings WHERE status IN ('open','closure_submitted')),
    'kpi_latest',      (SELECT COALESCE(jsonb_agg(jsonb_build_object('contract_id', k.contract_id, 'period', k.period_month,
                                         'score', k.score, 'color', k.color)), '[]'::jsonb)
                        FROM (SELECT DISTINCT ON (contract_id) contract_id, period_month, score, color
                              FROM kpi_snapshots ORDER BY contract_id, period_month DESC) k),
    'unread_notifications', (SELECT count(*) FROM notifications WHERE user_id = auth.uid() AND read_at IS NULL))
$$;

-- ═════════════ RLS: ENABLE SEMUA TABEL (default deny) ═════════════
-- TIDAK memakai FORCE: fungsi SECURITY DEFINER (owner postgres) harus melewati RLS.
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('r','p') LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP;
END $$;

-- ═════════════ POLICY SELECT (tidak ada policy tulis — semua tulis via RPC) ═════════════
-- Pola: (SELECT fn()) → dievaluasi sekali per query (initplan)

-- Identitas & admin
CREATE POLICY sel_profiles ON profiles FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (id = (SELECT auth.uid()) OR (SELECT rls_admin('admin.users.view'))));
CREATE POLICY sel_user_roles ON user_roles FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (user_id = (SELECT auth.uid()) OR (SELECT rls_admin('admin.users.view'))));
CREATE POLICY sel_roles ON roles FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND ((SELECT rls_admin('admin.users.view')) OR (SELECT rls_admin('admin.users.approve'))
                                OR (SELECT rls_admin('admin.invites.manage'))));
CREATE POLICY sel_permissions ON permissions FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND ((SELECT rls_admin('admin.users.view')) OR (SELECT rls_admin('admin.roles.manage'))));
CREATE POLICY sel_role_permissions ON role_permissions FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND ((SELECT rls_admin('admin.users.view')) OR (SELECT rls_admin('admin.roles.manage'))));
CREATE POLICY sel_user_invites ON user_invites FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (SELECT rls_admin('admin.invites.manage')));
CREATE POLICY sel_trusted_devices ON trusted_devices FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND ((SELECT rls_admin('admin.security.manage')) OR (SELECT rls_admin('admin.sessions.revoke'))));
CREATE POLICY sel_security_events ON security_events FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (SELECT rls_admin('admin.security.manage')));
CREATE POLICY sel_app_settings ON app_settings FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (is_public OR rls_admin(required_permission)));
CREATE POLICY sel_notifications ON notifications FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND user_id = (SELECT auth.uid()));
CREATE POLICY sel_outbox ON notification_outbox FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (SELECT rls_admin('admin.templates.manage')));

-- Referensi (semua user aktif)
CREATE POLICY sel_geozones ON geozones FOR SELECT TO authenticated USING ((SELECT rls_ok()));
CREATE POLICY sel_holidays ON holidays FOR SELECT TO authenticated USING ((SELECT rls_ok()));
CREATE POLICY sel_doc_type_catalog ON doc_type_catalog FOR SELECT TO authenticated USING ((SELECT rls_ok()));

-- Vendor & kontrak
CREATE POLICY sel_contractors ON contractors FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contractor(id));
CREATE POLICY sel_contracts ON contracts FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(id));
CREATE POLICY sel_subcontractors ON subcontractors FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_contract_requirements ON contract_requirements FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_self_assessments ON self_assessments FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (contractor_id = (SELECT auth_contractor_id())
         OR ((SELECT auth_is_wfrd()) AND has_contractor_permission('vendor.view', contractor_id))));
CREATE POLICY sel_vendor_evaluations ON vendor_evaluations FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (SELECT auth_is_wfrd()) AND has_contractor_permission('vendor.view', contractor_id));

-- Link OneDrive: hanya WFRD ber-permission (contractor menerima link via get_task_detail)
CREATE POLICY sel_upload_links ON upload_links FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (SELECT auth_is_wfrd()) AND CASE scope_type
    WHEN 'global' THEN has_permission('upload_link.view')
    WHEN 'vendor' THEN has_contractor_permission('upload_link.view', contractor_id)
    WHEN 'task'   THEN has_any_permission('upload_link.view') AND can_view_task(task_id)
    ELSE has_contract_permission('upload_link.view', contract_id) END);

-- Task
CREATE POLICY sel_tasks ON tasks FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (contractor_id = (SELECT auth_contractor_id()) OR ((SELECT auth_is_wfrd()) AND can_view_task(id))));
CREATE POLICY sel_task_emails ON task_emails FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND (
         (task_id IS NOT NULL AND (SELECT auth_is_wfrd()) AND can_view_task(task_id))
      OR (SELECT rls_admin('admin.templates.manage'))));

-- Domain kontrak
CREATE POLICY sel_meetings ON meetings FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_meeting_attendees ON meeting_attendees FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND EXISTS (SELECT 1 FROM meetings m WHERE m.id = meeting_id));        -- RLS meetings berlaku
CREATE POLICY sel_signatures ON signatures FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND CASE entity
    WHEN 'meeting'    THEN EXISTS (SELECT 1 FROM meetings m WHERE m.id = entity_id)
    WHEN 'opr_review' THEN EXISTS (SELECT 1 FROM opr_reviews o WHERE o.id = entity_id)
    WHEN 'jra'        THEN can_view_task(entity_id)
    ELSE FALSE END);
CREATE POLICY sel_risk_items ON risk_items FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_audits ON audits FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id) AND ((SELECT auth_is_wfrd()) OR status = 'final'));
CREATE POLICY sel_inspections ON inspections FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_audit_findings ON audit_findings FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id));
CREATE POLICY sel_manning ON manning FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('record.view', contract_id));
CREATE POLICY sel_daily_briefings ON daily_briefings FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('record.view', contract_id));
CREATE POLICY sel_bbs ON bbs_observations FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('record.view', contract_id));
CREATE POLICY sel_stop_work ON stop_work_events FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('record.view', contract_id));
CREATE POLICY sel_incidents ON incidents FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('incident.view', contract_id));
CREATE POLICY sel_kpi ON kpi_snapshots FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_read_contract_data('kpi.view', contract_id));
CREATE POLICY sel_opr ON opr_reviews FOR SELECT TO authenticated
  USING ((SELECT rls_ok()) AND can_view_contract(contract_id) AND ((SELECT auth_is_wfrd()) OR status <> 'draft'));

-- ═════════════ PRIVILEGE TABEL & SEQUENCE ═════════════
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES    FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;
REVOKE USAGE ON SCHEMA public FROM anon;              -- anon tidak punya kebutuhan data apa pun (login = GoTrue)
GRANT  USAGE ON SCHEMA public TO authenticated, service_role;

-- Tabel tanpa kolom rahasia
GRANT SELECT ON geozones, holidays, doc_type_catalog, user_roles, roles, permissions, role_permissions, user_invites,
                security_events, app_settings, notifications, contracts, subcontractors, contract_requirements, upload_links,
                task_emails, self_assessments, vendor_evaluations, meetings, meeting_attendees, signatures, risk_items, audits,
                inspections, audit_findings, manning, daily_briefings, bbs_observations, stop_work_events, incidents,
                kpi_snapshots, opr_reviews
  TO authenticated;

-- GRANT per kolom (kolom terenkripsi/internal/rahasia tidak pernah keluar)
GRANT SELECT (id, email, full_name, avatar_url, status, status_reason, is_root_admin, contractor_id, geozone, job_title, locale,
              privacy_accepted_at, approved_by, approved_at, last_login_at, anonymized_at, created_at, updated_at)
  ON profiles TO authenticated;                                            -- tanpa phone_enc, sessions_valid_after
GRANT SELECT (id, vendor_seq, legal_name, trading_name, registration_no, tax_id, country, address, website, email_domain,
              primary_contact_name, primary_contact_email, hse_manager_name, hse_manager_email, status, submitted_at,
              asl_expires_on, asl_conditions, asl_decided_by, asl_decided_at, status_reason, registered_by, created_at, updated_at)
  ON contractors TO authenticated;                                         -- tanpa telepon terenkripsi & internal_notes
GRANT SELECT (id, task_id, base_task_id, revision, scope, contractor_id, contract_id, subcontractor_id, doc_type_code, kind, phase,
              title, description, is_mandatory, is_blocker, source_ref, parent_task_id, renewal_of, superseded_by, assigned_to,
              reviewer_id, due_date, review_due_at, status, status_reason, upload_link_id, uploaded_file_name, file_sha256,
              evidence_ref, integrity_attested, upload_confirmed_at, upload_confirmed_by, email_claimed_at, email_verified,
              email_verified_via, email_from, doc_number, issuer, issue_date, expiry_date, review_started_at, reviewed_by,
              reviewed_at, review_notes, approved_snapshot, fingerprint_verified, form_data, created_by, created_at, updated_at)
  ON tasks TO authenticated;                                               -- tanpa confirm_code (hanya via get_task_detail)
GRANT SELECT (id, user_id, label, first_seen, last_seen, revoked_at, revoked_by, revoke_reason)
  ON trusted_devices TO authenticated;                                     -- tanpa device_hash, IP HMAC, session id
GRANT SELECT (id, channel, template_id, to_user, to_email, dedupe_key, status, attempts, last_error, provider_msg_id,
              send_after, sent_at, created_at)
  ON notification_outbox TO authenticated;                                 -- tanpa params (bisa memuat data pribadi)

-- View (security_invoker → RLS & GRANT kolom pemanggil berlaku)
GRANT SELECT ON v_task_tracking, v_task_latest TO authenticated;

-- ═════════════ PRIVILEGE FUNGSI: DEFAULT DENY + ALLOWLIST ═════════════
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;
-- EXECUTE untuk PUBLIC adalah default bawaan global → hanya bisa dicabut TANPA "IN SCHEMA"
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Default Supabase (per schema public) untuk anon/authenticated/service_role
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;

-- Nama fungsi unik (tanpa overload) → GRANT tanpa signature. Generator DILARANG membuat overload (diuji pgTAP).
DO $$
DECLARE f TEXT;
  v_client TEXT[] := ARRAY[
    -- helper policy & realtime
    'rls_ok','rls_admin','device_ok','auth_is_active','auth_contractor_id','auth_is_wfrd','has_permission','has_any_permission',
    'has_contract_permission','has_contractor_permission','can_view_contract','can_view_task','can_view_contractor',
    'can_read_contract_data','business_today','is_chat_member','can_broadcast_chat','can_presence_chat','_topic_channel',
    -- sesi, profil, perangkat, notifikasi, registrasi
    'register_device','my_session_state','list_my_devices','revoke_my_device','rename_my_device','update_my_profile',
    'get_my_profile','mark_notifications_read','save_push_subscription','delete_push_subscription',
    'save_registration_draft','submit_registration','get_my_registration',
    -- admin console
    'admin_overview','admin_approve_user','admin_reject_user','admin_grant_role','admin_revoke_role','admin_set_user_status',
    'admin_force_logout','admin_revoke_device','admin_set_user_contractor','admin_authorize_action',
    'admin_user_effective_permissions','admin_list_users','admin_create_invite','admin_revoke_invite','admin_upsert_role',
    'admin_preview_role_change','admin_set_role_permissions','admin_delete_role','admin_upsert_setting','admin_upsert_holiday',
    'admin_delete_holiday','admin_upsert_geozone','admin_upsert_doc_type','admin_audit_search','admin_verify_audit_chain',
    'admin_handle_security_event','admin_export_user_data','admin_anonymize_user','admin_set_read_only','admin_global_logout',
    'admin_set_email_otp','admin_retry_outbox','admin_upsert_contractor','admin_upsert_upload_link',
    'admin_deactivate_upload_link','admin_chat_set_channel','admin_list_channels',
    -- vendor & kontrak
    'get_contractor_detail','update_my_company','vendor_request_info','save_self_assessment','submit_self_assessment',
    'screen_vendor','decide_asl','set_vendor_status','create_contract','update_contract','save_premob_questionnaire',
    'mobilization_blockers','demob_blockers','transition_contract','request_go_live','approve_go_live','add_subcontractor',
    'decide_subcontractor','upsert_risk_item','delete_risk_item','approve_residual_risk','create_meeting','update_meeting',
    'finalize_meeting','sign_entity','save_audit','record_inspection','create_finding','cancel_finding','save_opr_review',
    -- task & link
    'create_adhoc_task','link_coverage','get_task_detail','get_review_queue','log_link_opened','get_task_email_context',
    'confirm_upload','claim_confirmation_email','start_review','review_task','reopen_rejected_task','waive_task','cancel_task',
    'supersede_task','edit_task_due','nudge_task','checklist_set_item','checklist_verify_item','complete_wfrd_action',
    -- record & dashboard
    'report_incident','submit_incident_report','manage_incident','submit_daily_briefing','submit_bbs','submit_stop_work',
    'upsert_manning','get_dashboard',
    -- chat
    'send_message','get_messages','list_my_channels','get_channel_members','get_user_cards','create_direct_channel',
    'create_group_channel','get_or_create_task_thread','create_announcement','chat_add_members','chat_remove_member',
    'leave_channel','edit_message','delete_message','react_message','mark_read','ack_message','get_ack_report',
    'get_read_receipts','pin_message','save_message','list_saved_messages','list_pins','schedule_message','cancel_scheduled',
    'list_my_scheduled','search_messages','chat_set_notify','chat_moderate_member','chat_export'];
  -- Hanya yang dipanggil Edge Function dengan service role key (job pg_cron berjalan sebagai postgres)
  v_service TEXT[] := ARRAY['verify_confirmation_email_inbound','svc_claim_outbox','svc_mark_outbox',
                            'svc_delete_push_subscription','svc_email_event','svc_audit_anchor'];
  v_bad TEXT;
BEGIN
  FOREACH f IN ARRAY v_client LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I TO authenticated', f);
  END LOOP;
  FOREACH f IN ARRAY v_service LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I TO service_role', f);
  END LOOP;

  -- ── Asersi: migration GAGAL jika allowlist tidak persis ──
  SELECT string_agg(p.proname, ', ') INTO v_bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Fungsi executable oleh anon/PUBLIC: %', v_bad; END IF;

  SELECT string_agg(p.proname, ', ') INTO v_bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT (p.proname = ANY(v_client))
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Fungsi di luar allowlist authenticated: %', v_bad; END IF;

  SELECT string_agg(proname, ', ') INTO v_bad FROM (
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' GROUP BY p.proname HAVING count(*) > 1) x;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Overload terdeteksi (dilarang): %', v_bad; END IF;

  SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Tabel tanpa RLS: %', v_bad; END IF;

  SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
    AND (has_table_privilege('authenticated', c.oid, 'INSERT') OR has_table_privilege('authenticated', c.oid, 'UPDATE')
      OR has_table_privilege('authenticated', c.oid, 'DELETE') OR has_table_privilege('authenticated', c.oid, 'TRUNCATE'));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Tabel dengan privilege tulis klien: %', v_bad; END IF;
END $$;

-- Helper is_chat_member · can_broadcast_chat · can_presence_chat · _topic_channel sudah di-GRANT di 14.16
-- Terima: broadcast di user:{me} (notifikasi, chat_activity) & chat:{id} (anggota); presence di chat non-announcement
DROP POLICY IF EXISTS comen_rt_receive ON realtime.messages;
CREATE POLICY comen_rt_receive ON realtime.messages FOR SELECT TO authenticated USING (
     (realtime.messages.extension = 'broadcast' AND (
          realtime.topic() = 'user:' || (SELECT auth.uid())::TEXT
       OR public.is_chat_member(public._topic_channel(realtime.topic()))))
  OR (realtime.messages.extension = 'presence' AND public.can_presence_chat(public._topic_channel(realtime.topic()))));

-- Kirim (typing/presence): anggota non-readonly di channel aktif. Topic user:* TIDAK bisa ditulis klien (anti-spoof notifikasi).
DROP POLICY IF EXISTS comen_rt_send ON realtime.messages;
CREATE POLICY comen_rt_send ON realtime.messages FOR INSERT TO authenticated WITH CHECK (
     (realtime.messages.extension = 'broadcast' AND public.can_broadcast_chat(public._topic_channel(realtime.topic())))
  OR (realtime.messages.extension = 'presence'  AND public.can_presence_chat(public._topic_channel(realtime.topic()))));
