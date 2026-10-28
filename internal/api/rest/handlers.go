package rest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"varta/internal/api/middleware"
	"varta/internal/auth"
	"varta/internal/database"
	"varta/internal/models"
)

type API struct {
	db *database.DB
}

func New(db *database.DB) *API {
	return &API{db: db}
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

		// Messages queue
		authR.Get("/messages/pending", a.HandleGetPendingMessages)
		authR.Post("/messages/send", a.HandleSendMessage)
		authR.Post("/messages/ack", a.HandleAckMessages)
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
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
		PreKeys []models.OTKDTO `json:"prekeys"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid format"}`, http.StatusBadRequest)
		return
	}

	var devRecordID int
	err := a.db.QueryRow("SELECT id FROM devices WHERE user_id = $1 AND device_id = $2", currentUser.ID, currentDeviceID).Scan(&devRecordID)
	if err != nil {
		http.Error(w, `{"error":"device not found"}`, http.StatusNotFound)
		return
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
	if err := json.NewDecoder(r.Body).Decode(&env); err != nil || env.MessageID == "" || env.Ciphertext == "" {
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

	respondJSON(w, http.StatusAccepted, map[string]interface{}{"status": "queued", "message_id": env.MessageID})
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

func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
