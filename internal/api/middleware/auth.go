package middleware

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
	"time"

	"varta/internal/database"
	"varta/internal/models"
)

type contextKey string

const (
	UserContextKey   contextKey = "user"
	DeviceContextKey contextKey = "device_id"
)

func AuthMiddleware(db *database.DB) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := extractToken(r)
			if token == "" {
				http.Error(w, `{"error":"unauthorized: missing token"}`, http.StatusUnauthorized)
				return
			}

			// Hash token for database lookup
			hasher := sha256.New()
			hasher.Write([]byte(token))
			tokenHash := hex.EncodeToString(hasher.Sum(nil))

			var user models.User
			var deviceID string
			var expiresAt time.Time

			err := db.QueryRow(`
				SELECT u.id, u.username, u.display_name, u.role, u.avatar_url, u.is_active, u.created_at,
				       s.device_id, s.expires_at
				FROM sessions s
				JOIN users u ON u.id = s.user_id
				WHERE s.token_hash = $1
			`, tokenHash).Scan(
				&user.ID, &user.Username, &user.DisplayName, &user.Role, &user.AvatarURL, &user.IsActive, &user.CreatedAt,
				&deviceID, &expiresAt,
			)

			if err != nil || !user.IsActive || time.Now().After(expiresAt) {
				http.Error(w, `{"error":"unauthorized: invalid or expired session"}`, http.StatusUnauthorized)
				return
			}

			// Background touch last_active
			go func() {
				_, _ = db.Exec("UPDATE sessions SET last_active = NOW() WHERE token_hash = $1", tokenHash)
			}()

			ctx := context.WithValue(r.Context(), UserContextKey, user)
			ctx = context.WithValue(ctx, DeviceContextKey, deviceID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, ok := r.Context().Value(UserContextKey).(models.User)
		if !ok || user.Role != "admin" {
			http.Error(w, `{"error":"forbidden: admin privileges required"}`, http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func GetUserFromContext(ctx context.Context) (models.User, bool) {
	u, ok := ctx.Value(UserContextKey).(models.User)
	return u, ok
}

func GetDeviceFromContext(ctx context.Context) (string, bool) {
	d, ok := ctx.Value(DeviceContextKey).(string)
	return d, ok
}

func extractToken(r *http.Request) string {
	authHeader := r.Header.Get("Authorization")
	if strings.HasPrefix(authHeader, "Bearer ") {
		return strings.TrimPrefix(authHeader, "Bearer ")
	}
	// Also support token in URL query for WebSocket handshakes
	if queryToken := r.URL.Query().Get("token"); queryToken != "" {
		return queryToken
	}
	// Or in cookie for CMS admin
	if cookie, err := r.Cookie("varta_session"); err == nil && cookie.Value != "" {
		return cookie.Value
	}
	return ""
}
