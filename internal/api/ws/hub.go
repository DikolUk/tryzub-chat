package ws

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"varta/internal/database"
	"varta/internal/models"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024 * 64,
	WriteBufferSize: 1024 * 64,
	CheckOrigin: func(r *http.Request) bool {
		return true // Origin checked by reverse proxy
	},
}

type Frame struct {
	Type              string          `json:"type"` // "msg", "ack", "ping", "pong", "status"
	MessageID         string          `json:"message_id,omitempty"`
	RecipientUserID   int             `json:"recipient_user_id,omitempty"`
	RecipientDeviceID string          `json:"recipient_device_id,omitempty"`
	Ciphertext        string          `json:"ciphertext,omitempty"`
	Payload           json.RawMessage `json:"payload,omitempty"`
}

type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	send     chan []byte
	userID   int
	deviceID string
}

type Hub struct {
	db         *database.DB
	clients    map[string]*Client // key: "userID:deviceID"
	register   chan *Client
	unregister chan *Client
	broadcast  chan *models.MessageEnvelope
	mu         sync.RWMutex
}

func NewHub(db *database.DB) *Hub {
	return &Hub{
		db:         db,
		clients:    make(map[string]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan *models.MessageEnvelope, 256),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			key := fmt.Sprintf("%d:%s", client.userID, client.deviceID)
			h.mu.Lock()
			// If existing connection, close old one
			if existing, ok := h.clients[key]; ok {
				close(existing.send)
				_ = existing.conn.Close()
			}
			h.clients[key] = client
			h.mu.Unlock()
			log.Printf("[WS] Device online: user=%d, device=%s", client.userID, client.deviceID)

			// Drain offline queue
			go h.drainOfflineQueue(client)

		case client := <-h.unregister:
			key := fmt.Sprintf("%d:%s", client.userID, client.deviceID)
			h.mu.Lock()
			if c, ok := h.clients[key]; ok && c == client {
				delete(h.clients, key)
				close(client.send)
			}
			h.mu.Unlock()
			log.Printf("[WS] Device offline: user=%d, device=%s", client.userID, client.deviceID)
		}
	}
}

func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}

	hasher := sha256.New()
	hasher.Write([]byte(token))
	tokenHash := hex.EncodeToString(hasher.Sum(nil))

	var userID int
	var deviceID string
	var expiresAt time.Time

	err := h.db.QueryRow(`
		SELECT user_id, device_id, expires_at
		FROM sessions
		WHERE token_hash = $1
	`, tokenHash).Scan(&userID, &deviceID, &expiresAt)

	if err != nil || time.Now().After(expiresAt) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WS] Upgrade error: %v", err)
		return
	}

	client := &Client{
		hub:      h,
		conn:     conn,
		send:     make(chan []byte, 128),
		userID:   userID,
		deviceID: deviceID,
	}

	h.register <- client

	go client.writePump()
	go client.readPump()
}

func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		_ = c.conn.Close()
	}()

	c.conn.SetReadLimit(1024 * 512) // 512 KB per frame
	_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			break
		}

		var frame Frame
		if err := json.Unmarshal(message, &frame); err != nil {
			continue
		}

		switch frame.Type {
		case "ping":
			c.sendFrame(Frame{Type: "pong"})

		case "ack":
			if frame.MessageID != "" {
				_, _ = c.hub.db.Exec(`
					UPDATE messages
					SET delivered = TRUE, delivered_at = NOW()
					WHERE message_id = $1 AND recipient_user_id = $2 AND recipient_device_id = $3
				`, frame.MessageID, c.userID, c.deviceID)
			}

		case "msg":
			if frame.MessageID == "" || frame.RecipientUserID == 0 || frame.Ciphertext == "" {
				continue
			}

			// 1. Persist to store-and-forward mailbox
			_, err := c.hub.db.Exec(`
				INSERT INTO messages (message_id, sender_user_id, sender_device_id, recipient_user_id, recipient_device_id, ciphertext, type)
				VALUES ($1, $2, $3, $4, $5, $6, 'signal')
				ON CONFLICT (message_id) DO NOTHING
			`, frame.MessageID, c.userID, c.deviceID, frame.RecipientUserID, frame.RecipientDeviceID, frame.Ciphertext)

			if err != nil {
				log.Printf("[WS] Error storing message: %v", err)
				continue
			}

			// Send sender ack that server accepted it into queue
			c.sendFrame(Frame{
				Type:      "server_ack",
				MessageID: frame.MessageID,
			})

			// 2. If recipient device is currently connected, route immediately
			c.hub.mu.RLock()
			targetKey := fmt.Sprintf("%d:%s", frame.RecipientUserID, frame.RecipientDeviceID)
			targetClient, isOnline := c.hub.clients[targetKey]
			c.hub.mu.RUnlock()

			if isOnline {
				targetClient.sendFrame(Frame{
					Type:              "msg",
					MessageID:         frame.MessageID,
					RecipientUserID:   frame.RecipientUserID,
					RecipientDeviceID: frame.RecipientDeviceID,
					Ciphertext:        frame.Ciphertext,
				})
			}
		}
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			_, _ = w.Write(message)

			// Flush queued frames
			n := len(c.send)
			for i := 0; i < n; i++ {
				_, _ = w.Write([]byte{'\n'})
				_, _ = w.Write(<-c.send)
			}

			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *Client) sendFrame(f Frame) {
	bytes, err := json.Marshal(f)
	if err == nil {
		select {
		case c.send <- bytes:
		default:
			log.Printf("[WS] Buffer full for user %d:%s", c.userID, c.deviceID)
		}
	}
}

func (h *Hub) drainOfflineQueue(c *Client) {
	rows, err := h.db.Query(`
		SELECT message_id, sender_user_id, sender_device_id, ciphertext
		FROM messages
		WHERE recipient_user_id = $1 AND recipient_device_id = $2 AND delivered = FALSE
		ORDER BY id ASC
		LIMIT 100
	`, c.userID, c.deviceID)
	if err != nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		var msgID, senderDevice, ciphertext string
		var senderID int
		if err := rows.Scan(&msgID, &senderID, &senderDevice, &ciphertext); err == nil {
			c.sendFrame(Frame{
				Type:              "msg",
				MessageID:         msgID,
				RecipientUserID:   c.userID,
				RecipientDeviceID: c.deviceID,
				Ciphertext:        ciphertext,
			})
		}
	}
}
