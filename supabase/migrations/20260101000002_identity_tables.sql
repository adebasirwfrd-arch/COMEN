CREATE TABLE admin_allowlist (
  email    TEXT PRIMARY KEY CHECK (email = lower(email)),
  note     TEXT,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO admin_allowlist (email, note) VALUES ('ade.basirwfrd@gmail.com', 'Root super admin');

CREATE TABLE geozones (
  code           TEXT PRIMARY KEY CHECK (code ~ '^[A-Z]{2,10}$'),
  name           TEXT NOT NULL,
  review_mailbox TEXT NOT NULL CHECK (review_mailbox ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  timezone       TEXT NOT NULL DEFAULT 'Asia/Jakarta',
  active         BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE profiles (
  id                   UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                TEXT NOT NULL UNIQUE CHECK (email = lower(email)),
  full_name            TEXT NOT NULL CHECK (length(full_name) BETWEEN 1 AND 120),
  avatar_url           TEXT CHECK (avatar_url IS NULL OR avatar_url ~ '^https://'),
  status               account_status NOT NULL DEFAULT 'pending',
  status_reason        TEXT,
  is_root_admin        BOOLEAN NOT NULL DEFAULT FALSE,
  contractor_id        UUID,                                    -- FK di 14.3
  geozone              TEXT REFERENCES geozones(code),
  job_title            TEXT CHECK (length(job_title) <= 120),
  phone_enc            BYTEA,                                   -- AES-256
  enc_key_ver          SMALLINT NOT NULL DEFAULT 1,
  locale               TEXT NOT NULL DEFAULT 'id' CHECK (locale IN ('id','en')),
  sessions_valid_after TIMESTAMPTZ NOT NULL DEFAULT '-infinity',
  privacy_accepted_at  TIMESTAMPTZ,
  approved_by          UUID REFERENCES profiles(id),
  approved_at          TIMESTAMPTZ,
  last_login_at        TIMESTAMPTZ,
  anonymized_at        TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (NOT is_root_admin OR contractor_id IS NULL)
);
CREATE INDEX idx_profiles_contractor ON profiles(contractor_id);
CREATE INDEX idx_profiles_status ON profiles(status);

CREATE TABLE roles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key         TEXT UNIQUE NOT NULL CHECK (key ~ '^[a-z_]{3,40}$'),
  name        TEXT NOT NULL,
  description TEXT,
  is_system   BOOLEAN NOT NULL DEFAULT FALSE,
  is_wfrd     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE permissions (
  key         TEXT PRIMARY KEY CHECK (key ~ '^([a-z_]+(\.[a-z_]+)*|\*)$'),
  module      TEXT NOT NULL,
  description TEXT NOT NULL,
  risk_level  TEXT NOT NULL CHECK (risk_level IN ('low','medium','high','critical')),
  audience    TEXT NOT NULL CHECK (audience IN ('wfrd','contractor','any'))
);

CREATE TABLE role_permissions (
  role_id        UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_key TEXT NOT NULL REFERENCES permissions(key),
  PRIMARY KEY (role_id, permission_key)
);

CREATE TABLE user_roles (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role_id    UUID NOT NULL REFERENCES roles(id),
  scope_type TEXT NOT NULL DEFAULT 'global' CHECK (scope_type IN ('global','geozone','contract','contractor')),
  scope_id   TEXT,
  scope_key  TEXT GENERATED ALWAYS AS (COALESCE(scope_id, '')) STORED,
  granted_by UUID REFERENCES profiles(id),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  reason     TEXT NOT NULL,
  CHECK ((scope_type = 'global') = (scope_id IS NULL)),
  UNIQUE (user_id, role_id, scope_type, scope_key)
);
CREATE INDEX idx_user_roles_user ON user_roles(user_id);

CREATE TABLE user_invites (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email           TEXT NOT NULL CHECK (email = lower(email) AND email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role_id         UUID NOT NULL REFERENCES roles(id),
  scope_type      TEXT NOT NULL DEFAULT 'global' CHECK (scope_type IN ('global','geozone','contract','contractor')),
  scope_id        TEXT,
  contractor_id   UUID,                                         -- FK di 14.3
  role_expires_at TIMESTAMPTZ,
  note            TEXT,
  invited_by      UUID NOT NULL REFERENCES profiles(id),
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '14 days',
  accepted_at     TIMESTAMPTZ,
  accepted_by     UUID REFERENCES profiles(id),
  revoked_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((scope_type = 'global') = (scope_id IS NULL))
);
CREATE UNIQUE INDEX uq_invite_active ON user_invites(email) WHERE accepted_at IS NULL AND revoked_at IS NULL;

CREATE TABLE trusted_devices (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  device_hash     TEXT NOT NULL CHECK (device_hash ~ '^[a-f0-9]{64}$'),
  label           TEXT CHECK (length(label) <= 80),
  first_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_ip_hmac    TEXT,
  last_session_id UUID,
  revoked_at      TIMESTAMPTZ,
  revoked_by      UUID REFERENCES profiles(id),
  revoke_reason   TEXT,
  UNIQUE (user_id, device_hash)
);

CREATE TABLE security_events (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     UUID,
  event       TEXT NOT NULL,      -- login, new_device, device_revoked, force_logout, role_changed, user_status,
                                  -- export, onboarding_error, new_pending_user, anomaly, settings_changed
  severity    TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  device_hash TEXT,
  ip_hmac     TEXT,
  detail      JSONB,
  handled_at  TIMESTAMPTZ,
  handled_by  UUID REFERENCES profiles(id),
  handle_note TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_security_events_open ON security_events(created_at DESC) WHERE handled_at IS NULL;

CREATE TABLE rate_limits (
  key          TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  hits         INT NOT NULL,
  limit_value  INT NOT NULL,
  PRIMARY KEY (key, window_start)
);

CREATE TABLE app_settings (
  key                 TEXT PRIMARY KEY,
  value               JSONB NOT NULL,
  is_public           BOOLEAN NOT NULL DEFAULT FALSE,      -- boleh dibaca semua user aktif
  required_permission TEXT NOT NULL DEFAULT 'admin.settings.manage' REFERENCES permissions(key),
  description         TEXT,
  updated_by          UUID REFERENCES profiles(id),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE holidays (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  holiday_date DATE NOT NULL,
  geozone      TEXT REFERENCES geozones(code),                -- NULL = berlaku semua geozone
  name         TEXT NOT NULL
);
CREATE UNIQUE INDEX uq_holiday ON holidays(holiday_date, COALESCE(geozone, '*'));

CREATE TABLE notifications (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  title      TEXT NOT NULL,
  body       TEXT,
  link       TEXT CHECK (link IS NULL OR link ~ '^/'),
  severity   TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  dedupe_key TEXT UNIQUE,
  read_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_notifications_user ON notifications(user_id, created_at DESC);

CREATE TABLE push_subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  device_id       UUID NOT NULL REFERENCES trusted_devices(id) ON DELETE CASCADE,
  endpoint        TEXT NOT NULL UNIQUE CHECK (endpoint ~ '^https://'),
  p256dh          TEXT NOT NULL,
  auth_secret_enc BYTEA NOT NULL,                              -- AES-256
  enc_key_ver     SMALLINT NOT NULL DEFAULT 1,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE notification_outbox (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel          TEXT NOT NULL DEFAULT 'email' CHECK (channel IN ('email','push')),
  template_id      INT NOT NULL,
  to_user          UUID REFERENCES profiles(id),
  to_email         TEXT,
  params           JSONB NOT NULL DEFAULT '{}'::jsonb,
  dedupe_key       TEXT UNIQUE,
  status           TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sending','sent','failed','skipped')),
  attempts         INT NOT NULL DEFAULT 0,
  last_error       TEXT,
  provider_msg_id  TEXT,
  send_after       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  locked_until     TIMESTAMPTZ,
  sent_at          TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (to_user IS NOT NULL OR to_email IS NOT NULL)
);
CREATE INDEX idx_outbox_queue ON notification_outbox(send_after) WHERE status = 'queued';

CREATE TABLE record_sequences (                               -- INC, FND, MOM per kontrak
  scope_key   TEXT NOT NULL,
  kind        TEXT NOT NULL,
  current_seq INT NOT NULL,
  PRIMARY KEY (scope_key, kind)
);
