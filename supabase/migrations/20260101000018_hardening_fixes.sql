-- ═════════════ HARDENING FIXES ═════════════
-- CREATE OR REPLACE mempertahankan ACL (allowlist v_client di migration 16 tetap berlaku).

CREATE OR REPLACE FUNCTION finalize_meeting(p_meeting UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m meetings; v_k contracts;
BEGIN
  SELECT * INTO v_m FROM meetings WHERE id = p_meeting FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MoM tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM assert_access('meeting.manage', v_m.contract_id);
  IF v_m.status <> 'draft' THEN RAISE EXCEPTION 'MoM sudah final' USING ERRCODE = '22023'; END IF;
  UPDATE meetings SET status = 'final', finalized_at = NOW() WHERE id = p_meeting;
  SELECT * INTO v_k FROM contracts WHERE id = v_m.contract_id;
  PERFORM _notify_contractor(v_k.contractor_id, 'mom_ready', 'MoM siap ditandatangani: ' || v_m.mom_no, v_k.contract_no,
                             '/contracts/' || v_k.id || '/meetings/' || p_meeting, 'info', 4002,
                             jsonb_build_object('mom_no', v_m.mom_no, 'contract_no', v_k.contract_no), 'mom:' || p_meeting);
END $$;

CREATE OR REPLACE FUNCTION set_vendor_status(p_contractor UUID, p_status vendor_status, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('vendor.suspend', NULL, TRUE, p_contractor); v_reason TEXT := _require_reason(p_reason); v_c contractors;
        v_k RECORD;
BEGIN
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vendor tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF p_status NOT IN ('suspended','blacklisted','asl_approved','asl_conditional') THEN
    RAISE EXCEPTION 'Status hanya suspended/blacklisted/reinstate' USING ERRCODE = '22023'; END IF;
  IF p_status IN ('asl_approved','asl_conditional')
     AND (v_c.status <> 'suspended' OR v_c.asl_expires_on IS NULL OR v_c.asl_expires_on < CURRENT_DATE) THEN
    RAISE EXCEPTION 'Reinstate hanya dari suspended dengan ASL belum kedaluwarsa' USING ERRCODE = '22023'; END IF;
  UPDATE contractors SET status = p_status, status_reason = v_reason, updated_at = NOW() WHERE id = p_contractor;
  IF p_status IN ('suspended','blacklisted') THEN
    FOR v_k IN SELECT id, process_owner_id FROM contracts WHERE contractor_id = p_contractor AND status NOT IN ('closed','terminated') LOOP
      PERFORM _notify(v_k.process_owner_id, 'vendor_suspended', 'Vendor ' || p_status || ': pertimbangkan hold kontrak', v_reason,
                      '/contracts/' || v_k.id, 'critical', NULL, '{}'::jsonb, 'vsusp:' || v_k.id || ':' || extract(epoch FROM NOW())::BIGINT);
    END LOOP;
  END IF;
  PERFORM _notify_contractor(p_contractor, 'vendor_status', 'Status vendor: ' || p_status, v_reason, '/my-company', 'warning');
END $$;

CREATE OR REPLACE FUNCTION save_push_subscription(p_endpoint TEXT, p_p256dh TEXT, p_auth TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(TRUE); v_dev UUID; v_ver SMALLINT := _active_key_ver('data');
BEGIN
  SELECT id INTO v_dev FROM trusted_devices WHERE user_id = v_uid AND device_hash = request_device_hash() AND revoked_at IS NULL;
  IF v_dev IS NULL THEN RAISE EXCEPTION 'Perangkat belum terdaftar' USING ERRCODE = '42501', HINT = 'device_unregistered'; END IF;
  IF p_endpoint !~ '^https://' OR length(p_endpoint) > 1000 OR p_p256dh !~ '^[A-Za-z0-9_-]{40,200}$' OR p_auth !~ '^[A-Za-z0-9_-]{10,100}$' THEN
    RAISE EXCEPTION 'Subscription tidak valid' USING ERRCODE = '22023';
  END IF;
  INSERT INTO push_subscriptions (user_id, device_id, endpoint, p256dh, auth_secret_enc, enc_key_ver)
  VALUES (v_uid, v_dev, p_endpoint, p_p256dh, _encrypt(p_auth, 'data', v_ver), v_ver)
  ON CONFLICT (endpoint) DO UPDATE SET user_id = EXCLUDED.user_id, device_id = EXCLUDED.device_id, p256dh = EXCLUDED.p256dh,
                                        auth_secret_enc = EXCLUDED.auth_secret_enc, enc_key_ver = EXCLUDED.enc_key_ver;
END $$;

-- Event chat (message_created dsb.) hanya dikirim server via realtime.send; klien cuma boleh broadcast 'typing'.
DROP POLICY IF EXISTS comen_rt_send ON realtime.messages;
CREATE POLICY comen_rt_send ON realtime.messages FOR INSERT TO authenticated WITH CHECK (
     (realtime.messages.extension = 'broadcast' AND realtime.messages.event = 'typing'
      AND public.can_broadcast_chat(public._topic_channel(realtime.topic())))
  OR (realtime.messages.extension = 'presence'  AND public.can_presence_chat(public._topic_channel(realtime.topic()))));
