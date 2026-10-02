CREATE SEQUENCE audit_logs_id_seq;
CREATE TABLE audit_logs (
  id          BIGINT NOT NULL DEFAULT nextval('audit_logs_id_seq'),
  table_name  TEXT NOT NULL,
  record_id   TEXT,
  action      TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_data    JSONB,
  new_data    JSONB,
  actor_id    UUID,
  actor_role  TEXT,
  device_hash TEXT,
  prev_hash   TEXT,
  row_hash    TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE audit_logs_2026    PARTITION OF audit_logs FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE audit_logs_2027    PARTITION OF audit_logs FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;
CREATE INDEX idx_audit_logs_record ON audit_logs (table_name, record_id);
CREATE INDEX idx_audit_logs_actor  ON audit_logs (actor_id, created_at);

CREATE TABLE audit_chain_head (
  id        SMALLINT PRIMARY KEY CHECK (id = 1),
  last_id   BIGINT,
  last_hash TEXT
);
INSERT INTO audit_chain_head VALUES (1, NULL, NULL);

-- Kanonik: hash dihitung dari nilai yang tidak bergantung setting sesi
CREATE OR REPLACE FUNCTION _audit_hash(p_prev TEXT, p_table TEXT, p_record TEXT, p_action TEXT,
  p_old JSONB, p_new JSONB, p_actor UUID, p_at TIMESTAMPTZ) RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT encode(digest(
    COALESCE(p_prev, 'GENESIS') || '|' || p_table || '|' || COALESCE(p_record, '') || '|' || p_action || '|' ||
    COALESCE(p_old::TEXT, '') || '|' || COALESCE(p_new::TEXT, '') || '|' || COALESCE(p_actor::TEXT, 'system') || '|' ||
    (EXTRACT(EPOCH FROM p_at) * 1000000)::BIGINT::TEXT, 'sha256'), 'hex')
$$;

-- Trigger generik. Argumen trigger = kolom PK (default 'id'), mis. log_change('role_id','permission_key')
CREATE OR REPLACE FUNCTION log_change() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_old JSONB; v_new JSONB; v_row JSONB; v_record TEXT := ''; v_head audit_chain_head;
  v_now TIMESTAMPTZ := clock_timestamp(); v_hash TEXT; v_id BIGINT; i INT;
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

  SELECT * INTO v_head FROM audit_chain_head WHERE id = 1 FOR UPDATE;          -- serialisasi rantai
  v_id := nextval('audit_logs_id_seq');
  v_hash := _audit_hash(v_head.last_hash, TG_TABLE_NAME, v_record, TG_OP, v_old, v_new, auth.uid(), v_now);

  INSERT INTO audit_logs (id, table_name, record_id, action, old_data, new_data, actor_id, actor_role,
                          device_hash, prev_hash, row_hash, created_at)
  VALUES (v_id, TG_TABLE_NAME, v_record, TG_OP, v_old, v_new, auth.uid(),
          COALESCE(auth.jwt() ->> 'role', current_user), request_device_hash(), v_head.last_hash, v_hash, v_now);
  UPDATE audit_chain_head SET last_id = v_id, last_hash = v_hash WHERE id = 1;
  RETURN COALESCE(NEW, OLD);
END $$;

-- Append-only: tidak ada role aplikasi yang boleh mengubah/menghapus
CREATE OR REPLACE FUNCTION _audit_immutable() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'audit_logs bersifat append-only' USING ERRCODE = '42501'; END $$;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION _audit_immutable();
