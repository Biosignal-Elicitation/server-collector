-- #############################################################################
-- ### 拡張機能の有効化
-- #############################################################################
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- #############################################################################
-- ### 基本構造 (テナント, ユーザー, デバイス, セッション)
-- #############################################################################

CREATE TABLE tenants (
    tenant_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(tenant_id),
    -- 外部認証プロバイダ（Firebase Auth, Auth0など）のIDを保存する
    external_auth_id TEXT UNIQUE,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    device_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(user_id), -- デバイスを特定のユーザーに紐付ける
    model TEXT,
    firmware_version TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE recording_sessions (
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id),
    device_id UUID NOT NULL REFERENCES devices(device_id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    sampling_rate_hz INT NOT NULL,
    notes TEXT
);

CREATE TABLE channels (
    channel_id SERIAL PRIMARY KEY,
    -- デバイスモデルごとにチャンネル設定を共通化する想定
    device_model TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT DEFAULT 'EEG',
    unit TEXT DEFAULT 'uV',
    UNIQUE (device_model, name)
);


-- #############################################################################
-- ### 時系列データ (TimescaleDB Hypertables)
-- #############################################################################

-- 1分単位のエポック
CREATE TABLE epochs (
    epoch_id BIGINT NOT NULL, -- floor(unix_timestamp_ms / 60000)
    session_id UUID NOT NULL REFERENCES recording_sessions(session_id),
    epoch_start_time TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (session_id, epoch_id)
);

-- EEG生データ
CREATE TABLE bio_signal_raw (
    time TIMESTAMPTZ NOT NULL,
    session_id UUID NOT NULL, -- FK制約はパフォーマンスのため外す場合がある
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    channel_name TEXT NOT NULL,
    value REAL NOT NULL,
    -- マイコンからのタイムスタンプ
    device_timestamp_us BIGINT
);
-- TimescaleDBハイパーテーブル化
SELECT create_hypertable('bio_signal_raw', by_range('time'), if_not_exists => TRUE);
-- クエリ最適化のためのインデックス
CREATE INDEX ON bio_signal_raw (user_id, session_id, time DESC);
CREATE INDEX ON bio_signal_raw (channel_name, time DESC);


-- #############################################################################
-- ### マルチモーダルデータとイベント (NEW: 会話ログとラベル)
-- #############################################################################

-- 音声・画像データへの参照
-- URIには "s3://<bucket>/<object_key>" のような形式で保存する。
-- オブジェクトキー自体はBIDS命名規則に準拠させる。
CREATE TABLE audio_chunks (
    session_id UUID NOT NULL,
    epoch_id BIGINT NOT NULL,
    uri TEXT NOT NULL UNIQUE, -- 例: s3://my-bucket/sub-xxx/ses-yyy/..._audio.wav
    codec TEXT NOT NULL,
    sample_rate INT NOT NULL,
    duration_sec REAL NOT NULL,
    PRIMARY KEY (session_id, epoch_id),
    FOREIGN KEY (session_id, epoch_id) REFERENCES epochs(session_id, epoch_id)
);

CREATE TABLE epoch_images (
    session_id UUID NOT NULL,
    epoch_id BIGINT NOT NULL,
    uri TEXT NOT NULL UNIQUE, -- 例: s3://my-bucket/sub-xxx/ses-yyy/..._photo.jpg
    meta JSONB,
    PRIMARY KEY (session_id, epoch_id),
    FOREIGN KEY (session_id, epoch_id) REFERENCES epochs(session_id, epoch_id)
);

-- SignalLabによって検出された特異イベント
CREATE TABLE detected_events (
    event_id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id),
    session_id UUID NOT NULL REFERENCES recording_sessions(session_id),
    epoch_id BIGINT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    trigger_type TEXT NOT NULL, -- 例: 'alpha_power_drop'
    details JSONB, -- 変化量などの詳細情報
    FOREIGN KEY (session_id, epoch_id) REFERENCES epochs(session_id, epoch_id)
);
CREATE INDEX ON detected_events (user_id, occurred_at DESC);

-- ★ NEW: AIとユーザーの会話
CREATE TABLE conversations (
    conversation_id BIGSERIAL PRIMARY KEY,
    -- この会話がどの特異イベントによって始まったか
    trigger_event_id BIGINT NOT NULL REFERENCES detected_events(event_id),
    user_id UUID NOT NULL REFERENCES users(user_id),
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status TEXT NOT NULL DEFAULT 'ongoing' -- 'ongoing', 'completed', 'aborted'
);

-- ★ NEW: 会話内の個々のメッセージ
CREATE TABLE conversation_messages (
    message_id BIGSERIAL PRIMARY KEY,
    conversation_id BIGINT NOT NULL REFERENCES conversations(conversation_id),
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sender_type TEXT NOT NULL, -- 'user' or 'ai'
    content TEXT NOT NULL
);
CREATE INDEX ON conversation_messages (conversation_id, sent_at ASC);

-- ★ NEW: 会話から得られた、特異イベントに対するラベル
CREATE TABLE anomaly_labels (
    label_id BIGSERIAL PRIMARY KEY,
    -- どの特異イベントに対するラベルか
    event_id BIGINT NOT NULL REFERENCES detected_events(event_id),
    -- どの会話からこのラベルが生成されたか
    source_conversation_id BIGINT REFERENCES conversations(conversation_id),
    user_id UUID NOT NULL REFERENCES users(user_id),
    -- ラベルの内容（例：「コーヒーをこぼして驚いた」）
    label_text TEXT NOT NULL,
    -- ラベリング手法（例：'user_report', 'ai_summary'）
    method TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- (オプション) ラベルを付けた人/システム
    annotator_id TEXT
);
CREATE INDEX ON anomaly_labels (event_id);
