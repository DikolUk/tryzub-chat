package models

import (
	"time"
)

type User struct {
	ID          int       `json:"id"`
	Username    string    `json:"username"`
	DisplayName string    `json:"display_name"`
	Role        string    `json:"role"`
	AvatarURL   string    `json:"avatar_url"`
	IsActive    bool      `json:"is_active"`
	CreatedAt   time.Time `json:"created_at"`
}

type Invite struct {
	ID         int        `json:"id"`
	Token      string     `json:"token"`
	Role       string     `json:"role"`
	MaxUses    int        `json:"max_uses"`
	UsesCount  int        `json:"uses_count"`
	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
	CreatedBy  *int       `json:"created_by,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	IsRevoked  bool       `json:"is_revoked"`
	Note       string     `json:"note"`
}

type Device struct {
	ID             int       `json:"id"`
	UserID         int       `json:"user_id"`
	DeviceID       string    `json:"device_id"`
	DeviceName     string    `json:"device_name"`
	IdentityKey    string    `json:"identity_key"`
	SignedPreKey   string    `json:"signed_prekey"`
	SignedPreKeySig string   `json:"signed_prekey_sig"`
	RegistrationID int       `json:"registration_id"`
	PushToken      string    `json:"push_token,omitempty"`
	PushPlatform   string    `json:"push_platform,omitempty"`
	LastSeen       time.Time `json:"last_seen"`
	CreatedAt      time.Time `json:"created_at"`
}

type PreKeyBundle struct {
	UserID         int     `json:"user_id"`
	DeviceID       string  `json:"device_id"`
	IdentityKey    string  `json:"identity_key"`
	SignedPreKey   string  `json:"signed_prekey"`
	SignedPreKeySig string `json:"signed_prekey_sig"`
	RegistrationID int     `json:"registration_id"`
	OneTimeKeyID   *int    `json:"one_time_key_id,omitempty"`
	OneTimePreKey  *string `json:"one_time_prekey,omitempty"`
}

type MessageEnvelope struct {
	ID                int64     `json:"id"`
	MessageID         string    `json:"message_id"`
	SenderUserID      int       `json:"sender_user_id"`
	SenderDeviceID    string    `json:"sender_device_id"`
	RecipientUserID   int       `json:"recipient_user_id"`
	RecipientDeviceID string    `json:"recipient_device_id"`
	Ciphertext        string    `json:"ciphertext"` // Base64 E2EE blob
	Type              string    `json:"type"`       // 'signal', 'prekey', 'receipt'
	CreatedAt         time.Time `json:"created_at"`
}

type RegisterRequest struct {
	InviteToken string `json:"invite_token"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
	Password    string `json:"password"`
	DeviceID    string `json:"device_id"`
	DeviceName  string `json:"device_name"`
	// Initial cryptographic keys for this device
	IdentityKey    string   `json:"identity_key"`
	SignedPreKey   string   `json:"signed_prekey"`
	SignedPreKeySig string  `json:"signed_prekey_sig"`
	RegistrationID int      `json:"registration_id"`
	OneTimePreKeys []OTKDTO `json:"one_time_prekeys"`
}

type OTKDTO struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
}

type LoginRequest struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
}

type AuthResponse struct {
	Token  string `json:"token"`
	User   User   `json:"user"`
	Device Device `json:"device"`
}
