-- ============================================================================
-- Varta Messenger Schema v1.0
-- Zero-Knowledge E2EE Relay & Closed Community CMS
-- ============================================================================

-- 1. Users
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    display_name VARCHAR(100) NOT NULL DEFAULT '',
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'member', -- 'admin', 'moderator', 'member'
    avatar_url TEXT DEFAULT '',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Registration Invites (strictly controlled, no phone/email required)
CREATE TABLE IF NOT EXISTS invites (
    id SERIAL PRIMARY KEY,
    token VARCHAR(64) UNIQUE NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'member',
    max_uses INT NOT NULL DEFAULT 1,
    uses_count INT NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ,
    created_by INT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_revoked BOOLEAN NOT NULL DEFAULT FALSE,
    note VARCHAR(255) DEFAULT ''
);

-- 3. Devices (multi-device per user with individual E2EE identity & signed prekeys)
CREATE TABLE IF NOT EXISTS devices (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id VARCHAR(64) NOT NULL,
    device_name VARCHAR(100) NOT NULL DEFAULT 'Phone',
    identity_key TEXT NOT NULL,       -- Base64 Curve25519/Ed25519 public key
    signed_prekey TEXT NOT NULL,      -- Base64 signed prekey
    signed_prekey_sig TEXT NOT NULL,  -- Signature of signed prekey
    registration_id INT NOT NULL DEFAULT 0,
    push_token TEXT DEFAULT '',
    push_platform VARCHAR(20) DEFAULT '', -- 'apns', 'fcm', 'unifiedpush'
    last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, device_id)
);

-- 4. One-Time PreKeys (OTKs for X3DH / Double Ratchet initial handshake)
CREATE TABLE IF NOT EXISTS one_time_prekeys (
    id SERIAL PRIMARY KEY,
    device_id INT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    key_id INT NOT NULL,
    public_key TEXT NOT NULL, -- Base64 public key
    consumed BOOLEAN NOT NULL DEFAULT FALSE,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(device_id, key_id)
);

-- 5. Sessions (User-Device Auth Tokens)
CREATE TABLE IF NOT EXISTS sessions (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id VARCHAR(64) NOT NULL,
    token_hash VARCHAR(64) UNIQUE NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. Messages (Store-and-forward mailbox for E2EE ciphertext packets)
CREATE TABLE IF NOT EXISTS messages (
    id BIGSERIAL PRIMARY KEY,
    message_id VARCHAR(64) UNIQUE NOT NULL,
    sender_user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_device_id VARCHAR(64) NOT NULL,
    recipient_user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_device_id VARCHAR(64) NOT NULL,
    ciphertext TEXT NOT NULL, -- Base64 E2EE encrypted blob
    type VARCHAR(20) NOT NULL DEFAULT 'signal', -- 'signal', 'prekey', 'receipt'
    delivered BOOLEAN NOT NULL DEFAULT FALSE,
    delivered_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_queue ON messages(recipient_user_id, recipient_device_id, delivered);

-- 7. Audit Logs (for CMS security events: logins, invite generation, revocation, etc.)
CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id) ON DELETE SET NULL,
    action VARCHAR(64) NOT NULL,
    ip_address VARCHAR(45) NOT NULL DEFAULT '',
    user_agent TEXT DEFAULT '',
    details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
