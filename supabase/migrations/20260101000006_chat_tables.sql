CREATE TABLE chat_channels (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type            chat_channel_type NOT NULL,
  name            TEXT CHECK (length(name) <= 120),
  topic           TEXT CHECK (length(topic) <= 500),
  contract_id     UUID REFERENCES contracts(id),
  task_id         UUID REFERENCES tasks(id),
  contractor_id   UUID REFERENCES contractors(id),
  direct_key      TEXT UNIQUE,                                -- "uuidA:uuidB" terurut
  audience        JSONB,                                      -- announcement: {"all_contractors":true} | {"contractor_ids":[…]} | {"contract_ids":[…]} | {"wfrd":true}
  is_locked       BOOLEAN NOT NULL DEFAULT FALSE,
  is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
  legal_hold      BOOLEAN NOT NULL DEFAULT FALSE,
  retention_days  INT NOT NULL DEFAULT 2555 CHECK (retention_days >= 30),
  created_by      UUID REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_message_at TIMESTAMPTZ,
  CHECK ((type = 'direct') = (direct_key IS NOT NULL)),
  CHECK (type <> 'contract' OR contract_id IS NOT NULL),
  CHECK (type <> 'task' OR task_id IS NOT NULL),
  CHECK (type <> 'announcement' OR audience IS NOT NULL)
);
CREATE UNIQUE INDEX uq_contract_channel ON chat_channels(contract_id) WHERE type = 'contract';
CREATE UNIQUE INDEX uq_task_channel ON chat_channels(task_id) WHERE type = 'task';

CREATE TABLE chat_members (
  channel_id     UUID NOT NULL REFERENCES chat_channels(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES profiles(id),
  member_role    TEXT NOT NULL DEFAULT 'member' CHECK (member_role IN ('owner','moderator','member','readonly')),
  notify_level   TEXT NOT NULL DEFAULT 'all' CHECK (notify_level IN ('all','mentions','none')),
  muted_until    TIMESTAMPTZ,                                 -- mute notifikasi (oleh user)
  silenced_until TIMESTAMPTZ,                                 -- bungkam kirim (oleh moderator)
  last_read_seq  BIGINT NOT NULL DEFAULT 0,
  joined_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (channel_id, user_id)
);
CREATE INDEX idx_chat_members_user ON chat_members(user_id);

CREATE SEQUENCE chat_message_seq;
CREATE TABLE chat_messages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seq           BIGINT NOT NULL DEFAULT nextval('chat_message_seq') UNIQUE,
  channel_id    UUID NOT NULL REFERENCES chat_channels(id),
  sender_id     UUID REFERENCES profiles(id),                -- NULL = COMEN Bot
  client_msg_id UUID,
  kind          TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','system','task_card','reminder','announcement','security')),
  body_enc      BYTEA NOT NULL,
  body_sha256   TEXT NOT NULL CHECK (body_sha256 ~ '^[a-f0-9]{64}$'),
  key_ver       SMALLINT NOT NULL DEFAULT 1,
  priority      TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','important','urgent')),
  requires_ack  BOOLEAN NOT NULL DEFAULT FALSE,
  reply_to      UUID REFERENCES chat_messages(id),
  thread_root   UUID REFERENCES chat_messages(id),
  mentions      UUID[] NOT NULL DEFAULT '{}',
  task_refs     TEXT[] NOT NULL DEFAULT '{}',
  edited_at     TIMESTAMPTZ,
  deleted_at    TIMESTAMPTZ,
  deleted_by    UUID REFERENCES profiles(id),
  delete_reason TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (sender_id, client_msg_id)
);
CREATE INDEX idx_chat_messages_channel ON chat_messages(channel_id, seq DESC);
CREATE INDEX idx_chat_messages_thread  ON chat_messages(thread_root, seq) WHERE thread_root IS NOT NULL;

CREATE TABLE chat_message_edits (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  message_id    UUID NOT NULL REFERENCES chat_messages(id),
  prev_body_enc BYTEA NOT NULL,
  key_ver       SMALLINT NOT NULL,
  edited_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE chat_reactions (
  message_id UUID NOT NULL REFERENCES chat_messages(id),
  user_id    UUID NOT NULL REFERENCES profiles(id),
  emoji      TEXT NOT NULL CHECK (length(emoji) BETWEEN 1 AND 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (message_id, user_id, emoji)
);
CREATE TABLE chat_acks (
  message_id UUID NOT NULL REFERENCES chat_messages(id),
  user_id    UUID NOT NULL REFERENCES profiles(id),
  acked_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (message_id, user_id)
);
CREATE TABLE chat_pins (
  channel_id UUID NOT NULL REFERENCES chat_channels(id),
  message_id UUID NOT NULL REFERENCES chat_messages(id),
  pinned_by  UUID NOT NULL REFERENCES profiles(id),
  pinned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (channel_id, message_id)
);
CREATE TABLE chat_saved (
  user_id    UUID NOT NULL REFERENCES profiles(id),
  message_id UUID NOT NULL REFERENCES chat_messages(id),
  saved_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, message_id)
);
CREATE TABLE chat_scheduled (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id   UUID NOT NULL REFERENCES chat_channels(id),
  sender_id    UUID NOT NULL REFERENCES profiles(id),
  body_enc     BYTEA NOT NULL,
  key_ver      SMALLINT NOT NULL DEFAULT 1,
  priority     TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','important','urgent')),
  requires_ack BOOLEAN NOT NULL DEFAULT FALSE,
  send_at      TIMESTAMPTZ NOT NULL,
  recur_freq   TEXT NOT NULL DEFAULT 'none' CHECK (recur_freq IN ('none','daily','weekly','monthly')),
  recur_dow    SMALLINT[] CHECK (recur_dow <@ ARRAY[1,2,3,4,5,6,7]::SMALLINT[]),
  recur_time   TIME,
  recur_tz     TEXT NOT NULL DEFAULT 'Asia/Jakarta',
  recur_until  DATE,
  task_id      UUID REFERENCES tasks(id),
  status       TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','sent','cancelled','failed')),
  last_sent_at TIMESTAMPTZ,
  last_error   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (recur_freq = 'none' OR recur_time IS NOT NULL),
  CHECK (recur_freq <> 'weekly' OR cardinality(recur_dow) > 0)
);
CREATE INDEX idx_chat_scheduled_due ON chat_scheduled(send_at) WHERE status = 'scheduled';
