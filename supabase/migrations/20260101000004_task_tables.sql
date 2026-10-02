CREATE TABLE task_sequences (
  scope_key     TEXT NOT NULL,
  doc_type_code TEXT NOT NULL REFERENCES doc_type_catalog(code),
  current_seq   INT NOT NULL CHECK (current_seq BETWEEN 1 AND 999),
  PRIMARY KEY (scope_key, doc_type_code)
);

CREATE TABLE tasks (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id              TEXT UNIQUE NOT NULL
                         CHECK (task_id ~ '^CMN-(V\d{5}|\d{5}(S\d{2})?)-[A-Z0-9]{6}-\d{3}(-R\d{1,2})?$'),
  base_task_id         TEXT GENERATED ALWAYS AS (regexp_replace(task_id, '-R\d+$', '')) STORED,
  revision             INT NOT NULL DEFAULT 0 CHECK (revision BETWEEN 0 AND 99),

  scope                task_scope NOT NULL,
  contractor_id        UUID NOT NULL REFERENCES contractors(id),
  contract_id          UUID REFERENCES contracts(id),
  subcontractor_id     UUID REFERENCES subcontractors(id),
  doc_type_code        TEXT NOT NULL REFERENCES doc_type_catalog(code),
  kind                 task_kind NOT NULL,
  phase                lifecycle_phase NOT NULL,
  title                TEXT NOT NULL CHECK (length(title) <= 200),
  description          TEXT CHECK (length(description) <= 4000),
  is_mandatory         BOOLEAN NOT NULL DEFAULT TRUE,
  is_blocker           BOOLEAN NOT NULL DEFAULT FALSE,
  source_ref           TEXT CHECK (length(source_ref) <= 200),  -- mis. 'MOM:…', 'FND-00042-007', 'MONRPT:2026-10'
  parent_task_id       UUID REFERENCES tasks(id),               -- revisi sebelumnya
  renewal_of           UUID REFERENCES tasks(id),
  superseded_by        UUID REFERENCES tasks(id),

  assigned_to          UUID REFERENCES profiles(id),            -- NULL = semua user contractor; WFRD untuk action WFRD
  reviewer_id          UUID REFERENCES profiles(id),
  due_date             DATE,
  review_due_at        TIMESTAMPTZ,
  status               task_status NOT NULL DEFAULT 'open',
  status_reason        TEXT CHECK (length(status_reason) <= 1000),

  upload_link_id       UUID,                                    -- FK di bawah
  uploaded_file_name   TEXT CHECK (length(uploaded_file_name) <= 255),
  file_sha256          TEXT CHECK (file_sha256 IS NULL OR file_sha256 ~ '^[a-f0-9]{64}$'),
  evidence_ref         TEXT CHECK (length(evidence_ref) <= 500),
  integrity_attested   BOOLEAN NOT NULL DEFAULT FALSE,
  upload_confirmed_at  TIMESTAMPTZ,
  upload_confirmed_by  UUID REFERENCES profiles(id),

  confirm_code         TEXT CHECK (confirm_code IS NULL OR confirm_code ~ '^[A-F0-9]{4}-[A-F0-9]{4}$'),
  email_claimed_at     TIMESTAMPTZ,
  email_verified       BOOLEAN NOT NULL DEFAULT FALSE,
  email_verified_via   TEXT CHECK (email_verified_via IN ('inbound_parsed','reviewer_confirmed')),
  email_from           TEXT,

  doc_number           TEXT CHECK (length(doc_number) <= 120),
  issuer               TEXT CHECK (length(issuer) <= 200),
  issue_date           DATE,
  expiry_date          DATE,

  review_started_at    TIMESTAMPTZ,
  reviewed_by          UUID REFERENCES profiles(id),
  reviewed_at          TIMESTAMPTZ,
  review_notes         TEXT CHECK (length(review_notes) <= 4000),
  approved_snapshot    TEXT CHECK (length(approved_snapshot) <= 1000),
  fingerprint_verified BOOLEAN,

  form_data            JSONB,
  created_by           UUID REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CHECK (
    (scope = 'vendor'        AND contract_id IS NULL     AND subcontractor_id IS NULL) OR
    (scope = 'contract'      AND contract_id IS NOT NULL AND subcontractor_id IS NULL) OR
    (scope = 'subcontractor' AND contract_id IS NOT NULL AND subcontractor_id IS NOT NULL)
  ),
  CHECK (issue_date IS NULL OR expiry_date IS NULL OR expiry_date > issue_date)
);
ALTER TABLE tasks        ADD CONSTRAINT fk_tasks_upload_link FOREIGN KEY (upload_link_id) REFERENCES upload_links(id);
ALTER TABLE upload_links ADD CONSTRAINT fk_upload_links_task FOREIGN KEY (task_id) REFERENCES tasks(id);

CREATE INDEX idx_tasks_contract   ON tasks(contract_id);
CREATE INDEX idx_tasks_contractor ON tasks(contractor_id);
CREATE INDEX idx_tasks_status_due ON tasks(status, due_date);
CREATE INDEX idx_tasks_base       ON tasks(base_task_id, revision DESC);
CREATE INDEX idx_tasks_expiry     ON tasks(expiry_date) WHERE status = 'approved';
CREATE UNIQUE INDEX uq_tasks_source ON tasks(contract_id, doc_type_code, source_ref)
  WHERE source_ref IS NOT NULL AND revision = 0 AND status <> 'cancelled';

CREATE TABLE task_events (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  task_id    UUID NOT NULL REFERENCES tasks(id),
  event      TEXT NOT NULL,   -- created, link_opened, upload_confirmed, email_claimed, email_verified,
                              -- review_started, approved, revise, rejected, file_issue, reopened, expired,
                              -- renewal_created, waived, cancelled, superseded, due_changed, nudged, auto_reminder
  actor_id   UUID REFERENCES profiles(id),
  payload    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_task_events_task ON task_events(task_id, created_at);

CREATE TABLE task_emails (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id           UUID REFERENCES tasks(id),
  direction         TEXT NOT NULL CHECK (direction IN ('outbound','inbound')),
  template_id       INT,
  provider_msg_id   TEXT,
  from_email        TEXT,
  subject           TEXT CHECK (length(subject) <= 500),
  code_matched      BOOLEAN,
  sender_verified   BOOLEAN,
  attachments_count INT,                                       -- dihitung, TIDAK disimpan
  status            TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE checklist_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id      UUID NOT NULL REFERENCES tasks(id),
  item_no      SMALLINT NOT NULL CHECK (item_no BETWEEN 1 AND 99),
  category     TEXT,
  label        TEXT NOT NULL,
  owner_party  TEXT NOT NULL DEFAULT 'contractor' CHECK (owner_party IN ('contractor','wfrd')),
  checked      BOOLEAN NOT NULL DEFAULT FALSE,
  checked_by   UUID REFERENCES profiles(id),
  checked_at   TIMESTAMPTZ,
  evidence_ref TEXT CHECK (length(evidence_ref) <= 500),
  notes        TEXT CHECK (length(notes) <= 1000),
  verified     BOOLEAN NOT NULL DEFAULT FALSE,
  verified_by  UUID REFERENCES profiles(id),
  verified_at  TIMESTAMPTZ,
  UNIQUE (task_id, item_no)
);
