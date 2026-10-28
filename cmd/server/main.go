package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

	"varta/internal/api/rest"
	"varta/internal/api/ws"
	"varta/internal/cms"
	"varta/internal/config"
	"varta/internal/database"
)

func main() {
	log.Printf("[VARTA] Initializing Varta Secure Messenger Server v1.0...")

	cfg := config.Load()

	// 1. Database Connection & Schema Migration
	db, err := database.Connect(cfg)
	if err != nil {
		log.Fatalf("[FATAL] Database connection failed: %v", err)
	}
	defer db.Close()

	// 2. Real-time WebSocket Hub
	hub := ws.NewHub(db)
	go hub.Run()

	// 3. REST API & CMS
	api := rest.New(db, hub)
	adminCMS := cms.New(db)

	// 4. HTTP Router
	r := chi.NewRouter()

	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Recoverer)
	r.Use(chimw.Timeout(60 * time.Second))

	// CORS policy
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type", "X-CSRF-Token"},
		ExposedHeaders:   []string{"Link"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	// Domain host router helper: if host is adminchat.*, redirect root to /admin
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			host := req.Host
			if strings.HasPrefix(host, "adminchat.") && req.URL.Path == "/" {
				http.Redirect(w, req, "/admin", http.StatusFound)
				return
			}
			next.ServeHTTP(w, req)
		})
	})

	// Mount Subsystems
	r.Route("/api/v1", api.Routes)
	adminCMS.Routes(r)

	// WebSocket Live Endpoint
	r.Get("/ws", hub.ServeWS)

	// Root fallback
	r.Get("/", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"service":"varta-core",
			"status":"online",
			"protocol":"varta/1.0",
			"e2ee":"active",
			"cms_panel":"/admin"
		}`))
	})

	// 5. Start Server
	serverAddr := ":" + cfg.Port
	srv := &http.Server{
		Addr:         serverAddr,
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Printf("[VARTA] Server listening securely on %s (Environment: %s)", serverAddr, cfg.Environment)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[FATAL] Listen error: %v", err)
		}
	}()

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	log.Printf("[VARTA] Shutting down gracefully...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("[VARTA] Server shutdown error: %v", err)
	}
	log.Printf("[VARTA] Server stopped.")
}
