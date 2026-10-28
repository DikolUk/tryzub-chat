-- ============================================================================
-- Varta Migration 000002: Encrypted Media Vault, Reactions, Receipts & Message States
-- ============================================================================

-- 1. Zero-Knowledge Encrypted Media Vault
CREATE TABLE IF NOT EXISTS media_blobs (
    id VARCHAR(64) PRIMARY KEY,
    uploader_user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    file_size BIGINT NOT NULL,
    mime_type VARCHAR(100) NOT NULL DEFAULT 'application/octet-stream',
    file_path TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_media_uploader ON media_blobs(uploader_user_id);

-- 2. Message enhancements: Read receipts, tombstone deletion, reply reference
ALTER TABLE messages ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id VARCHAR(64);

-- 3. Reactions (Emoji responses attached to E2EE messages)
CREATE TABLE IF NOT EXISTS message_reactions (
    id SERIAL PRIMARY KEY,
    message_id VARCHAR(64) NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji VARCHAR(16) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_reactions_msg ON message_reactions(message_id);
