package cms

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

type CMS struct {
	db *database.DB
}

func New(db *database.DB) *CMS {
	return &CMS{db: db}
}

func (c *CMS) Routes(r chi.Router) {
	// Web UI
	r.Get("/admin", c.HandleAdminUI)
	r.Get("/admin/", c.HandleAdminUI)
	r.Post("/admin/login", c.HandleAdminLogin)

	// Admin API
	r.Route("/api/v1/admin", func(adminR chi.Router) {
		adminR.Use(middleware.AuthMiddleware(c.db))
		adminR.Use(middleware.RequireAdmin)

		adminR.Get("/stats", c.HandleGetStats)
		adminR.Get("/invites", c.HandleListInvites)
		adminR.Post("/invites", c.HandleCreateInvite)
		adminR.Delete("/invites/{id}", c.HandleRevokeInvite)

		adminR.Get("/users", c.HandleListUsers)
		adminR.Post("/users/{id}/toggle", c.HandleToggleUser)
		adminR.Delete("/users/{id}", c.HandleDeleteUser)

		adminR.Get("/audit", c.HandleGetAudit)
	})
}

func (c *CMS) HandleAdminLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	var user models.User
	var pwdHash string
	err := c.db.QueryRow(`
		SELECT id, username, display_name, password_hash, role, is_active
		FROM users
		WHERE username = $1 AND role = 'admin'
	`, req.Username).Scan(&user.ID, &user.Username, &user.DisplayName, &pwdHash, &user.Role, &user.IsActive)

	if err != nil || !user.IsActive {
		http.Error(w, `{"error":"невірний логін адміністратора або пароль"}`, http.StatusUnauthorized)
		return
	}

	valid, _ := auth.VerifyPassword(req.Password, pwdHash)
	if !valid {
		http.Error(w, `{"error":"невірний логін або пароль"}`, http.StatusUnauthorized)
		return
	}

	rawToken, _ := auth.GenerateSecureToken(32)
	hasher := sha256.New()
	hasher.Write([]byte(rawToken))
	tokenHash := hex.EncodeToString(hasher.Sum(nil))

	_, _ = c.db.Exec(`
		INSERT INTO sessions (user_id, device_id, token_hash, expires_at)
		VALUES ($1, 'admin-web-session', $2, $3)
	`, user.ID, tokenHash, time.Now().Add(7*24*time.Hour))

	// Set cookie for browser convenience
	http.SetCookie(w, &http.Cookie{
		Name:     "varta_session",
		Value:    rawToken,
		Path:     "/",
		Expires:  time.Now().Add(7 * 24 * time.Hour),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"token":   rawToken,
		"user":    user,
	})
}

func (c *CMS) HandleGetStats(w http.ResponseWriter, r *http.Request) {
	var userCount, deviceCount, activeInvites, pendingMessages int

	_ = c.db.QueryRow("SELECT COUNT(*) FROM users").Scan(&userCount)
	_ = c.db.QueryRow("SELECT COUNT(*) FROM devices").Scan(&deviceCount)
	_ = c.db.QueryRow("SELECT COUNT(*) FROM invites WHERE is_revoked = FALSE AND uses_count < max_uses").Scan(&activeInvites)
	_ = c.db.QueryRow("SELECT COUNT(*) FROM messages WHERE delivered = FALSE").Scan(&pendingMessages)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"users_count":      userCount,
		"devices_count":    deviceCount,
		"active_invites":   activeInvites,
		"pending_messages": pendingMessages,
		"server_time":      time.Now().UTC().Format(time.RFC3339),
	})
}

func (c *CMS) HandleListInvites(w http.ResponseWriter, r *http.Request) {
	rows, err := c.db.Query(`
		SELECT id, token, role, max_uses, uses_count, expires_at, is_revoked, note, created_at
		FROM invites
		ORDER BY id DESC
		LIMIT 100
	`)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	invites := make([]models.Invite, 0)
	for rows.Next() {
		var inv models.Invite
		if err := rows.Scan(&inv.ID, &inv.Token, &inv.Role, &inv.MaxUses, &inv.UsesCount, &inv.ExpiresAt, &inv.IsRevoked, &inv.Note, &inv.CreatedAt); err == nil {
			invites = append(invites, inv)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(invites)
}

func (c *CMS) HandleCreateInvite(w http.ResponseWriter, r *http.Request) {
	adminUser, _ := middleware.GetUserFromContext(r.Context())

	var req struct {
		Role      string `json:"role"`
		MaxUses   int    `json:"max_uses"`
		ValidDays int    `json:"valid_days"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	if req.Role == "" {
		req.Role = "member"
	}
	if req.MaxUses <= 0 {
		req.MaxUses = 1
	}

	token := auth.GenerateInviteToken()
	var expiresAt *time.Time
	if req.ValidDays > 0 {
		t := time.Now().Add(time.Duration(req.ValidDays) * 24 * time.Hour)
		expiresAt = &t
	}

	var inviteID int
	err := c.db.QueryRow(`
		INSERT INTO invites (token, role, max_uses, uses_count, expires_at, created_by, note)
		VALUES ($1, $2, $3, 0, $4, $5, $6)
		RETURNING id
	`, token, req.Role, req.MaxUses, expiresAt, adminUser.ID, req.Note).Scan(&inviteID)

	if err != nil {
		http.Error(w, `{"error":"failed to generate invite"}`, http.StatusInternalServerError)
		return
	}

	// Log audit
	_, _ = c.db.Exec(`
		INSERT INTO audit_logs (user_id, action, details)
		VALUES ($1, 'CREATE_INVITE', $2)
	`, adminUser.ID, fmtDetails(map[string]interface{}{"token": token, "role": req.Role, "max_uses": req.MaxUses}))

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"invite": models.Invite{
			ID:        inviteID,
			Token:     token,
			Role:      req.Role,
			MaxUses:   req.MaxUses,
			ExpiresAt: expiresAt,
			Note:      req.Note,
			CreatedAt: time.Now(),
		},
	})
}

func (c *CMS) HandleRevokeInvite(w http.ResponseWriter, r *http.Request) {
	adminUser, _ := middleware.GetUserFromContext(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	_, err = c.db.Exec("UPDATE invites SET is_revoked = TRUE WHERE id = $1", id)
	if err != nil {
		http.Error(w, `{"error":"failed to revoke"}`, http.StatusInternalServerError)
		return
	}

	_, _ = c.db.Exec(`
		INSERT INTO audit_logs (user_id, action, details)
		VALUES ($1, 'REVOKE_INVITE', $2)
	`, adminUser.ID, fmtDetails(map[string]interface{}{"invite_id": id}))

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

func (c *CMS) HandleListUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := c.db.Query(`
		SELECT u.id, u.username, u.display_name, u.role, u.is_active, u.created_at,
		       COUNT(d.id) AS device_count
		FROM users u
		LEFT JOIN devices d ON d.user_id = u.id
		GROUP BY u.id
		ORDER BY u.id ASC
	`)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type UserRow struct {
		models.User
		DeviceCount int `json:"device_count"`
	}

	userRows := make([]UserRow, 0)
	for rows.Next() {
		var ur UserRow
		if err := rows.Scan(&ur.ID, &ur.Username, &ur.DisplayName, &ur.Role, &ur.IsActive, &ur.CreatedAt, &ur.DeviceCount); err == nil {
			userRows = append(userRows, ur)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(userRows)
}

func (c *CMS) HandleToggleUser(w http.ResponseWriter, r *http.Request) {
	adminUser, _ := middleware.GetUserFromContext(r.Context())
	id, _ := strconv.Atoi(chi.URLParam(r, "id"))

	if id == adminUser.ID {
		http.Error(w, `{"error":"неможливо заблокувати власний акаунт"}`, http.StatusBadRequest)
		return
	}

	_, err := c.db.Exec("UPDATE users SET is_active = NOT is_active WHERE id = $1", id)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}

	// Invalidate active sessions if blocked
	_, _ = c.db.Exec("DELETE FROM sessions WHERE user_id = $1", id)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

func (c *CMS) HandleDeleteUser(w http.ResponseWriter, r *http.Request) {
	adminUser, _ := middleware.GetUserFromContext(r.Context())
	id, _ := strconv.Atoi(chi.URLParam(r, "id"))

	if id == adminUser.ID {
		http.Error(w, `{"error":"неможливо видалити власний акаунт"}`, http.StatusBadRequest)
		return
	}

	_, err := c.db.Exec("DELETE FROM users WHERE id = $1", id)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"success": true})
}

func (c *CMS) HandleGetAudit(w http.ResponseWriter, r *http.Request) {
	rows, err := c.db.Query(`
		SELECT id, user_id, action, ip_address, details, created_at
		FROM audit_logs
		ORDER BY id DESC
		LIMIT 100
	`)
	if err != nil {
		http.Error(w, `{"error":"database error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	type LogItem struct {
		ID        int64           `json:"id"`
		UserID    *int            `json:"user_id"`
		Action    string          `json:"action"`
		IP        string          `json:"ip"`
		Details   json.RawMessage `json:"details"`
		CreatedAt time.Time       `json:"created_at"`
	}

	logs := make([]LogItem, 0)
	for rows.Next() {
		var l LogItem
		if err := rows.Scan(&l.ID, &l.UserID, &l.Action, &l.IP, &l.Details, &l.CreatedAt); err == nil {
			logs = append(logs, l)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(logs)
}

func fmtDetails(m map[string]interface{}) string {
	b, _ := json.Marshal(m)
	return string(b)
}
