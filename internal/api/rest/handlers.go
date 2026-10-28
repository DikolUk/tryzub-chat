package rest

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"varta/internal/api/middleware"
	"varta/internal/api/ws"
	"varta/internal/auth"
	"varta/internal/database"
	"varta/internal/models"
)

type API struct {
	db  *database.DB
	hub *ws.Hub
}

func New(db *database.DB, hub *ws.Hub) *API {
	return &API{db: db, hub: hub}
}

func (a *API) Routes(r chi.Router) {
	// Public
	r.Get("/health", a.HandleHealth)
	r.Post("/auth/invite/check", a.HandleCheckInvite)
	r.Post("/auth/register", a.HandleRegister)
	r.Post("/auth/login", a.HandleLogin)

	// Authenticated
	r.Group(func(authR chi.Router) {
		authR.Use(middleware.AuthMiddleware(a.db))

		authR.Get("/users/me", a.HandleGetMe)
		authR.Get("/users", a.HandleListUsers)
		authR.Get("/users/{id}", a.HandleGetUser)

		// E2EE Keys management
		authR.Get("/keys/{userId}", a.HandleGetPreKeyBundle)
		authR.Post("/keys/prekeys", a.HandleUploadPreKeys)

		// Messages queue & history
		authR.Get("/messages/pending", a.HandleGetPendingMessages)
		authR.Get("/messages/history", a.HandleGetConversationHistory)
		authR.Post("/messages/send", a.HandleSendMessage)
		authR.Post("/messages/ack", a.HandleAckMessages)
		authR.Post("/messages/read", a.HandleMarkMessagesRead)
		authR.Post("/messages/delete", a.HandleDeleteMessage)
		authR.Post("/messages/reaction", a.HandleAddReaction)

		// Encrypted Media Vault
		authR.Post("/media/upload", a.HandleUploadMedia)
		authR.Get("/media/{id}", a.HandleGetMedia)
	})
}

func (a *API) HandleHealth(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"status":   "ok",
		"service":  "varta-server",
		"version":  "1.0.0",
		"protocol": "varta/1.0",
		"time":     time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *API) HandleCheckInvite(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(r, &req); err != nil || req.Token == "" {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	var invite models.Invite
	err := a.db.QueryRow(`
		SELECT id, token, role, max_uses, uses_count, expires_at, is_revoked, note
		FROM invites
		WHERE token = $1
	`, req.Token).Scan(
		&invite.ID, &invite.Token, &invite.Role, &invite.MaxUses, &invite.UsesCount,
		&invite.ExpiresAt, &invite.IsRevoked, &invite.Note,
	)

	if err != nil {
		http.Error(w, `{"error":"запрошення не знайдено або недійсне"}`, http.StatusNotFound)
		return
	}

	if invite.IsRevoked {
		http.Error(w, `{"error":"це запрошення було відкликано"}`, http.StatusForbidden)
		return
	}

	if invite.ExpiresAt != nil && time.Now().After(*invite.ExpiresAt) {
		http.Error(w, `{"error":"строк дії запрошення закінчився"}`, http.StatusGone)
		return
	}

	if invite.UsesCount >= invite.MaxUses {
		http.Error(w, `{"error":"ліміт використань цього запрошення вичерпано"}`, http.StatusGone)
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"valid": true,
		"role":  invite.Role,
	})
}

func (a *API) HandleRegister(w http.ResponseWriter, r *http.Request) {
	var req models.RegisterRequest
	if err := decodeJSON(r, &req); err != nil {
		http.Error(w, `{"error":"невірний формат запиту"}`, http.StatusBadRequest)
		return
	}

	if req.Username == "" || len(req.Password) < 8 || req.InviteToken == "" || req.DeviceID == "" {
		http.Error(w, `{"error":"необхідно заповнити всі поля, пароль мінімум 8 символів"}`, http.StatusBadRequest)
		return
	}

	// Begin atomic transaction
	tx, err := a.db.Begin()
	if err != nil {
		http.Error(w, `{"error":"помилка бази даних"}`, http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	// 1. Verify & Lock Invite
	var inviteID int
	var inviteRole string
	var maxUses, usesCount int
	var expiresAt *time.Time
	var isRevoked bool

	err = tx.QueryRow(`
		SELECT id, role, max_uses, uses_count, expires_at, is_revoked
		FROM invites
		WHERE token = $1
		FOR UPDATE
	`, req.InviteToken).Scan(&inviteID, &inviteRole, &maxUses, &usesCount, &expiresAt, &isRevoked)

	if err != nil || isRevoked || (expiresAt != nil && time.Now().After(*expiresAt)) || usesCount >= maxUses {
		http.Error(w, `{"error":"запрошення недійсне або вже вичерпане"}`, http.StatusBadRequest)
		return
	}

	// 2. Hash Password with Argon2id
	pwdHash, err := auth.HashPassword(req.Password)
	if err != nil {
		http.Error(w, `{"error":"помилка безпеки хешування"}`, http.StatusInternalServerError)
		return
	}

	displayName := req.DisplayName
	if displayName == "" {
		displayName = req.Username
	}

	// 3. Create User
	var userID int
	err = tx.QueryRow(`
		INSERT INTO users (username, display_name, password_hash, role)
		VALUES ($1, $2, $3, $4)
		RETURNING id
	`, req.Username, displayName, pwdHash, inviteRole).Scan(&userID)
	if err != nil {
		http.Error(w, `{"error":"користувач з таким логіном вже існує"}`, http.StatusConflict)
		return
	}

	// 4. Burn/Increment Invite
	_, err = tx.Exec(`UPDATE invites SET uses_count = uses_count + 1 WHERE id = $1`, inviteID)
	if err != nil {
		http.Error(w, `{"error":"помилка оновлення запрошення"}`, http.StatusInternalServerError)
		return
	}

	// 5. Register Device & E2EE Keys
	var deviceID int
	deviceName := req.DeviceName
	if deviceName == "" {
		deviceName = "Основний пристрій"
	}

	err = tx.QueryRow(`
		INSERT INTO devices (user_id, device_id, device_name, identity_key, signed_prekey, signed_prekey_sig, registration_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id
	`, userID, req.DeviceID, deviceName, req.IdentityKey, req.SignedPreKey, req.SignedPreKeySig, req.RegistrationID).Scan(&deviceID)
	if err != nil {
		http.Error(w, `{"error":"помилка реєстрації ключів пристрою"}`, http.StatusInternalServerError)
		return
	}

	// 6. Insert One-Time PreKeys
	for _, otk := range req.OneTimePreKeys {
		_, _ = tx.Exec(`
			INSERT INTO one_time_prekeys (device_id, key_id, public_key)
			VALUES ($1, $2, $3)
			ON CONFLICT DO NOTHING
		`, deviceID, otk.KeyID, otk.PublicKey)
	}

	// 7. Create Session Token
	rawToken, err := auth.GenerateSecureToken(32)
	if err != nil {
		http.Error(w, `{"error":"помилка сесії"}`, http.StatusInternalServerError)
		return
	}

	hasher := sha256.New()
	hasher.Write([]byte(rawToken))
	tokenHash := hex.EncodeToString(hasher.Sum(nil))

	expires := time.Now().Add(auth.SessionDuration)
	_, err = tx.Exec(`
		INSERT INTO sessions (user_id, device_id, token_hash, expires_at)
		VALUES ($1, $2, $3, $4)
	`, userID, req.DeviceID, tokenHash, expires)
	if err != nil {
		http.Error(w, `{"error":"помилка створення сесії"}`, http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(); err != nil {
		http.Error(w, `{"error":"помилка збереження"}`, http.StatusInternalServerError)
		return
	}

	respondJSON(w, http.StatusCreated, models.AuthResponse{
		Token: rawToken,
		User: models.User{
			ID:          userID,
			Username:    req.Username,
			DisplayName: displayName,
			Role:        inviteRole,
			IsActive:    true,
			CreatedAt:   time.Now(),
		},
		Device: models.Device{
			ID:          deviceID,
			UserID:      userID,
			DeviceID:    req.DeviceID,
			DeviceName:  deviceName,
			IdentityKey: req.IdentityKey,
			LastSeen:    time.Now(),
		},
	})
}

func (a *API) HandleLogin(w http.ResponseWriter, r *http.Request) {
	var req models.LoginRequest
	if err := decodeJSON(r, &req); err != nil {
		http.Error(w, `{"error":"невірний формат запиту"}`, http.StatusBadRequest)
		return
	}

	var user models.User
	var pwdHash string
	err := a.db.QueryRow(`
		SELECT id, username, display_name, password_hash, role, avatar_url, is_active, created_at
		FROM users
		WHERE username = $1
	`, req.Username).Scan(
		&user.ID, &user.Username, &user.DisplayName, &pwdHash, &user.Role, &user.AvatarURL, &user.IsActive, &user.CreatedAt,
	)

	if err != nil || !user.IsActive {
		http.Error(w, `{"error":"невірний логін або пароль"}`, http.StatusUnauthorized)
		return
	}

	valid, _ := auth.VerifyPassword(req.Password, pwdHash)
	if !valid {
		http.Error(w, `{"error":"невірний логін або пароль"}`, http.StatusUnauthorized)
		return
	}

	// Register device if not exists
	deviceName := req.DeviceName
	if deviceName == "" {
		deviceName = "Device"
	}

	_, _ = a.db.Exec(`
		INSERT INTO devices (user_id, device_id, device_name, identity_key, signed_prekey, signed_prekey_sig, registration_id)
		VALUES ($1, $2, $3, '', '', '', 0)
		ON CONFLICT (user_id, device_id) DO UPDATE SET last_seen = NOW()
	`, user.ID, req.DeviceID, deviceName)

	rawToken, _ := auth.GenerateSecureToken(32)
	hasher := sha256.New()
	hasher.Write([]byte(rawToken))
	tokenHash := hex.EncodeToString(hasher.Sum(nil))

	_, _ = a.db.Exec(`
		INSERT INTO sessions (user_id, device_id, token_hash, expires_at)
		VALUES ($1, $2, $3, $4)
	`, user.ID, req.DeviceID, tokenHash, time.Now().Add(auth.SessionDuration))

	respondJSON(w, http.StatusOK, models.AuthResponse{
		Token: rawToken,
		User:  user,
		Device: models.Device{
			UserID:     user.ID,
			DeviceID:   req.DeviceID,
			DeviceName: deviceName,
		},
	})
}

func (a *API) HandleGetMe(w http.ResponseWriter, r *http.Request) {
	user, _ := middleware.GetUserFromContext(r.Context())
	respondJSON(w, http.StatusOK, user)
}

func (a *API) HandleListUsers(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())

	rows, err := a.db.Query(`
		SELECT id, username, display_name, role, avatar_url, is_active, created_at
		FROM users
		WHERE is_active = TRUE AND id != $1
		ORDER BY display_name ASC
	`, currentUser.ID)
	if err != nil {
		http.Error(w, `{"error":"помилка бази даних"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	users := make([]models.User, 0)
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Role, &u.AvatarURL, &u.IsActive, &u.CreatedAt); err == nil {
			users = append(users, u)
		}
	}

	respondJSON(w, http.StatusOK, users)
}

func (a *API) HandleGetUser(w http.ResponseWriter, r *http.Request) {
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, `{"error":"невірний id"}`, http.StatusBadRequest)
		return
	}

	var u models.User
	err = a.db.QueryRow(`
		SELECT id, username, display_name, role, avatar_url, is_active, created_at
		FROM users
		WHERE id = $1 AND is_active = TRUE
	`, id).Scan(&u.ID, &u.Username, &u.DisplayName, &u.Role, &u.AvatarURL, &u.IsActive, &u.CreatedAt)

	if err != nil {
		http.Error(w, `{"error":"користувача не знайдено"}`, http.StatusNotFound)
		return
	}

	respondJSON(w, http.StatusOK, u)
}

// HandleGetPreKeyBundle fetches the E2EE key bundle for recipient devices (X3DH)
func (a *API) HandleGetPreKeyBundle(w http.ResponseWriter, r *http.Request) {
	targetUserID, err := strconv.Atoi(chi.URLParam(r, "userId"))
	if err != nil {
		http.Error(w, `{"error":"invalid userId"}`, http.StatusBadRequest)
		return
	}

	rows, err := a.db.Query(`
		SELECT id, device_id, identity_key, signed_prekey, signed_prekey_sig, registration_id
		FROM devices
		WHERE user_id = $1 AND identity_key != ''
	`, targetUserID)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	bundles := make([]models.PreKeyBundle, 0)
	for rows.Next() {
		var d models.Device
		if err := rows.Scan(&d.ID, &d.DeviceID, &d.IdentityKey, &d.SignedPreKey, &d.SignedPreKeySig, &d.RegistrationID); err != nil {
			continue
		}

		bundle := models.PreKeyBundle{
			UserID:         targetUserID,
			DeviceID:       d.DeviceID,
			IdentityKey:    d.IdentityKey,
			SignedPreKey:   d.SignedPreKey,
			SignedPreKeySig: d.SignedPreKeySig,
			RegistrationID: d.RegistrationID,
		}

		// Consume one OTK atomically if available
		var otkID int
		var otkPub string
		err := a.db.QueryRow(`
			UPDATE one_time_prekeys
			SET consumed = TRUE, consumed_at = NOW()
			WHERE id = (
				SELECT id FROM one_time_prekeys
				WHERE device_id = $1 AND consumed = FALSE
				LIMIT 1
				FOR UPDATE SKIP LOCKED
			)
			RETURNING key_id, public_key
		`, d.ID).Scan(&otkID, &otkPub)

		if err == nil {
			bundle.OneTimeKeyID = &otkID
			bundle.OneTimePreKey = &otkPub
		}

		bundles = append(bundles, bundle)
	}

	respondJSON(w, http.StatusOK, bundles)
}

func (a *API) HandleUploadPreKeys(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())
	currentDeviceID, _ := middleware.GetDeviceFromContext(r.Context())

	var req struct {
		IdentityKey     string          `json:"identity_key"`
		SignedPreKey    string          `json:"signed_prekey"`
		SignedPreKeySig string          `json:"signed_prekey_sig"`
		RegistrationID  int             `json:"registration_id"`
		PreKeys         []models.OTKDTO `json:"prekeys"`
	}
	if err := decodeJSON(r, &req); err != nil {
		http.Error(w, `{"error":"invalid format"}`, http.StatusBadRequest)
		return
	}

	var devRecordID int
	if req.IdentityKey != "" {
		err := a.db.QueryRow(`
			INSERT INTO devices (user_id, device_id, device_name, identity_key, signed_prekey, signed_prekey_sig, registration_id)
			VALUES ($1, $2, 'Клієнт VARTA', $3, $4, $5, $6)
			ON CONFLICT (user_id, device_id) DO UPDATE SET
				identity_key = EXCLUDED.identity_key,
				signed_prekey = EXCLUDED.signed_prekey,
				signed_prekey_sig = EXCLUDED.signed_prekey_sig,
				registration_id = EXCLUDED.registration_id,
				last_seen = NOW()
			RETURNING id
		`, currentUser.ID, currentDeviceID, req.IdentityKey, req.SignedPreKey, req.SignedPreKeySig, req.RegistrationID).Scan(&devRecordID)
		if err != nil {
			http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
			return
		}
	} else {
		err := a.db.QueryRow("SELECT id FROM devices WHERE user_id = $1 AND device_id = $2", currentUser.ID, currentDeviceID).Scan(&devRecordID)
		if err != nil {
			http.Error(w, `{"error":"device not found"}`, http.StatusNotFound)
			return
		}
	}

	for _, k := range req.PreKeys {
		_, _ = a.db.Exec(`
			INSERT INTO one_time_prekeys (device_id, key_id, public_key)
			VALUES ($1, $2, $3)
			ON CONFLICT DO NOTHING
		`, devRecordID, k.KeyID, k.PublicKey)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{"success": true, "uploaded": len(req.PreKeys)})
}

func (a *API) HandleGetPendingMessages(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())
	currentDeviceID, _ := middleware.GetDeviceFromContext(r.Context())

	rows, err := a.db.Query(`
		SELECT id, message_id, sender_user_id, sender_device_id, recipient_user_id, recipient_device_id,
		       ciphertext, type, created_at
		FROM messages
		WHERE recipient_user_id = $1 AND recipient_device_id = $2 AND delivered = FALSE
		ORDER BY id ASC
		LIMIT 100
	`, currentUser.ID, currentDeviceID)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	envelopes := make([]models.MessageEnvelope, 0)
	for rows.Next() {
		var env models.MessageEnvelope
		if err := rows.Scan(&env.ID, &env.MessageID, &env.SenderUserID, &env.SenderDeviceID,
			&env.RecipientUserID, &env.RecipientDeviceID, &env.Ciphertext, &env.Type, &env.CreatedAt); err == nil {
			envelopes = append(envelopes, env)
		}
	}

	respondJSON(w, http.StatusOK, envelopes)
}

func (a *API) HandleSendMessage(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())
	currentDeviceID, _ := middleware.GetDeviceFromContext(r.Context())

	var env models.MessageEnvelope
	if err := decodeJSON(r, &env); err != nil || env.MessageID == "" || env.Ciphertext == "" {
		http.Error(w, `{"error":"invalid envelope"}`, http.StatusBadRequest)
		return
	}

	_, err := a.db.Exec(`
		INSERT INTO messages (message_id, sender_user_id, sender_device_id, recipient_user_id, recipient_device_id, ciphertext, type)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (message_id) DO NOTHING
	`, env.MessageID, currentUser.ID, currentDeviceID, env.RecipientUserID, env.RecipientDeviceID, env.Ciphertext, env.Type)

	if err != nil {
		http.Error(w, `{"error":"could not store message"}`, http.StatusInternalServerError)
		return
	}

	if a.hub != nil {
		a.hub.BroadcastToUser(env.RecipientUserID, ws.Frame{
			Type:              "msg",
			MessageID:         env.MessageID,
			SenderUserID:      currentUser.ID,
			RecipientUserID:   env.RecipientUserID,
			RecipientDeviceID: env.RecipientDeviceID,
			Ciphertext:        env.Ciphertext,
		})
	}

	respondJSON(w, http.StatusAccepted, map[string]interface{}{"status": "queued", "message_id": env.MessageID})
}

func (a *API) HandleGetConversationHistory(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())
	withUserID, err := strconv.Atoi(r.URL.Query().Get("with_user"))
	if err != nil || withUserID <= 0 {
		http.Error(w, `{"error":"with_user parameter required"}`, http.StatusBadRequest)
		return
	}

	limit := 100
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 && l <= 200 {
		limit = l
	}

	rows, err := a.db.Query(`
		SELECT id, message_id, sender_user_id, sender_device_id, recipient_user_id, recipient_device_id,
		       ciphertext, type, delivered, read_at, is_deleted, created_at
		FROM messages
		WHERE ((sender_user_id = $1 AND recipient_user_id = $2)
		   OR (sender_user_id = $2 AND recipient_user_id = $1))
		   AND is_deleted = FALSE
		ORDER BY id DESC
		LIMIT $3
	`, currentUser.ID, withUserID, limit)

	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type HistoryMsg struct {
		ID                int64      `json:"id"`
		MessageID         string     `json:"message_id"`
		SenderUserID      int        `json:"sender_user_id"`
		SenderDeviceID    string     `json:"sender_device_id"`
		RecipientUserID   int        `json:"recipient_user_id"`
		RecipientDeviceID string     `json:"recipient_device_id"`
		Ciphertext        string     `json:"ciphertext"`
		Type              string     `json:"type"`
		Delivered         bool       `json:"delivered"`
		ReadAt            *time.Time `json:"read_at"`
		IsDeleted         bool       `json:"is_deleted"`
		CreatedAt         time.Time  `json:"created_at"`
	}

	history := make([]HistoryMsg, 0)
	for rows.Next() {
		var m HistoryMsg
		if err := rows.Scan(&m.ID, &m.MessageID, &m.SenderUserID, &m.SenderDeviceID,
			&m.RecipientUserID, &m.RecipientDeviceID, &m.Ciphertext, &m.Type,
			&m.Delivered, &m.ReadAt, &m.IsDeleted, &m.CreatedAt); err == nil {
			history = append(history, m)
		}
	}

	// Reverse to chronological order (oldest first)
	for i, j := 0, len(history)-1; i < j; i, j = i+1, j-1 {
		history[i], history[j] = history[j], history[i]
	}

	respondJSON(w, http.StatusOK, history)
}

func (a *API) HandleMarkMessagesRead(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())

	var req struct {
		MessageIDs []string `json:"message_ids"`
	}
	if err := decodeJSON(r, &req); err != nil || len(req.MessageIDs) == 0 {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	for _, mid := range req.MessageIDs {
		var senderID int
		err := a.db.QueryRow(`
			UPDATE messages
			SET read_at = NOW(), delivered = TRUE, delivered_at = COALESCE(delivered_at, NOW())
			WHERE message_id = $1 AND recipient_user_id = $2
			RETURNING sender_user_id
		`, mid, currentUser.ID).Scan(&senderID)

		if err == nil && senderID > 0 && a.hub != nil {
			a.hub.BroadcastToUser(senderID, ws.Frame{
				Type:         "read_receipt",
				MessageIDs:   []string{mid},
				SenderUserID: currentUser.ID,
			})
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{"success": true})
}

func (a *API) HandleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())

	var req struct {
		MessageID string `json:"message_id"`
	}
	if err := decodeJSON(r, &req); err != nil || req.MessageID == "" {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	var recID int
	err := a.db.QueryRow(`
		UPDATE messages
		SET is_deleted = TRUE
		WHERE message_id = $1 AND sender_user_id = $2
		RETURNING recipient_user_id
	`, req.MessageID, currentUser.ID).Scan(&recID)

	if err != nil {
		http.Error(w, `{"error":"message not found or permission denied"}`, http.StatusNotFound)
		return
	}

	if a.hub != nil && recID > 0 {
		a.hub.BroadcastToUser(recID, ws.Frame{
			Type:      "msg_deleted",
			MessageID: req.MessageID,
		})
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{"success": true})
}

func (a *API) HandleAddReaction(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())

	var req struct {
		MessageID string `json:"message_id"`
		Emoji     string `json:"emoji"`
	}
	if err := decodeJSON(r, &req); err != nil || req.MessageID == "" || req.Emoji == "" {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	var senderID, recID int
	err := a.db.QueryRow(`
		SELECT sender_user_id, recipient_user_id FROM messages WHERE message_id = $1
	`, req.MessageID).Scan(&senderID, &recID)

	if err != nil {
		http.Error(w, `{"error":"message not found"}`, http.StatusNotFound)
		return
	}

	_, _ = a.db.Exec(`
		INSERT INTO message_reactions (message_id, user_id, emoji)
		VALUES ($1, $2, $3)
		ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = EXCLUDED.emoji
	`, req.MessageID, currentUser.ID, req.Emoji)

	otherUserID := recID
	if currentUser.ID == recID {
		otherUserID = senderID
	}

	if a.hub != nil && otherUserID > 0 {
		a.hub.BroadcastToUser(otherUserID, ws.Frame{
			Type:         "reaction",
			MessageID:    req.MessageID,
			Emoji:        req.Emoji,
			SenderUserID: currentUser.ID,
		})
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{"success": true})
}

const MediaDir = "/app/data/media"

func (a *API) HandleUploadMedia(w http.ResponseWriter, r *http.Request) {
	currentUser, ok := middleware.GetUserFromContext(r.Context())
	if !ok {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	// 50 MB max body
	r.Body = http.MaxBytesReader(w, r.Body, 50*1024*1024)

	dir := MediaDir
	if stat, err := os.Stat("data/media"); err == nil && stat.IsDir() {
		dir = "data/media"
	}
	_ = os.MkdirAll(dir, 0755)

	blob, err := io.ReadAll(r.Body)
	if err != nil || len(blob) == 0 {
		http.Error(w, `{"error":"empty or invalid payload"}`, http.StatusBadRequest)
		return
	}

	token, _ := auth.GenerateSecureToken(16)
	mediaID := fmt.Sprintf("vmed-%d-%s", time.Now().UnixMilli(), token[:12])
	filePath := filepath.Join(dir, mediaID+".blob")

	if err := os.WriteFile(filePath, blob, 0644); err != nil {
		http.Error(w, `{"error":"failed to save blob"}`, http.StatusInternalServerError)
		return
	}

	mimeType := r.Header.Get("Content-Type")
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}

	_, err = a.db.Exec(`
		INSERT INTO media_blobs (id, uploader_user_id, file_size, mime_type, file_path)
		VALUES ($1, $2, $3, $4, $5)
	`, mediaID, currentUser.ID, len(blob), mimeType, filePath)

	if err != nil {
		_ = os.Remove(filePath)
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}

	respondJSON(w, http.StatusCreated, map[string]interface{}{
		"success":  true,
		"media_id": mediaID,
		"url":      "/api/v1/media/" + mediaID,
		"size":     len(blob),
	})
}

func (a *API) HandleGetMedia(w http.ResponseWriter, r *http.Request) {
	mediaID := chi.URLParam(r, "id")
	if mediaID == "" {
		http.Error(w, "invalid media id", http.StatusBadRequest)
		return
	}

	var filePath, mimeType string
	err := a.db.QueryRow(`
		SELECT file_path, mime_type FROM media_blobs WHERE id = $1
	`, mediaID).Scan(&filePath, &mimeType)

	if err != nil {
		http.Error(w, "media not found", http.StatusNotFound)
		return
	}

	data, err := os.ReadFile(filePath)
	if err != nil {
		http.Error(w, "file missing from storage", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (a *API) HandleAckMessages(w http.ResponseWriter, r *http.Request) {
	currentUser, _ := middleware.GetUserFromContext(r.Context())
	currentDeviceID, _ := middleware.GetDeviceFromContext(r.Context())

	var req struct {
		MessageIDs []string `json:"message_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid format"}`, http.StatusBadRequest)
		return
	}

	for _, msgID := range req.MessageIDs {
		_, _ = a.db.Exec(`
			UPDATE messages
			SET delivered = TRUE, delivered_at = NOW()
			WHERE message_id = $1 AND recipient_user_id = $2 AND recipient_device_id = $3
		`, msgID, currentUser.ID, currentDeviceID)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{"status": "acknowledged"})
}

func decodeJSON(r *http.Request, target interface{}) error {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}
	body = bytes.TrimPrefix(body, []byte("\xef\xbb\xbf"))
	return json.Unmarshal(body, target)
}

func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
