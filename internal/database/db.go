package database

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"time"

	_ "github.com/lib/pq"
	"varta/internal/config"
)

type DB struct {
	*sql.DB
}

func Connect(cfg *config.Config) (*DB, error) {
	connStr := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=%s",
		cfg.DBHost, cfg.DBPort, cfg.DBUser, cfg.DBPassword, cfg.DBName, cfg.DBSSLMode,
	)

	var db *sql.DB
	var err error

	// Retry connection with exponential backoff on container startup
	for attempts := 1; attempts <= 15; attempts++ {
		db, err = sql.Open("postgres", connStr)
		if err == nil {
			err = db.Ping()
			if err == nil {
				log.Printf("[DB] Connected to PostgreSQL at %s:%s/%s successfully", cfg.DBHost, cfg.DBPort, cfg.DBName)
				break
			}
		}
		log.Printf("[DB] Waiting for database (attempt %d/15): %v", attempts, err)
		time.Sleep(2 * time.Second)
	}

	if err != nil {
		return nil, fmt.Errorf("could not connect to database after 15 attempts: %w", err)
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)

	vartaDB := &DB{db}

	if err := vartaDB.runMigrations(); err != nil {
		return nil, fmt.Errorf("migration failure: %w", err)
	}

	if err := vartaDB.ensureInitialInvite(cfg.AdminInitialInvite); err != nil {
		log.Printf("[DB] Warning ensuring initial invite: %v", err)
	}

	return vartaDB, nil
}

func (db *DB) runMigrations() error {
	migrationPath := "migrations/000001_initial_schema.sql"
	sqlBytes, err := os.ReadFile(migrationPath)
	if err != nil {
		// Fallback for container root path
		sqlBytes, err = os.ReadFile("/app/migrations/000001_initial_schema.sql")
		if err != nil {
			return fmt.Errorf("failed to read migration file: %w", err)
		}
	}

	_, err = db.Exec(string(sqlBytes))
	if err != nil {
		return fmt.Errorf("executing migration failed: %w", err)
	}

	log.Printf("[DB] Migrations executed successfully")
	return nil
}

func (db *DB) ensureInitialInvite(initialToken string) error {
	var count int
	err := db.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
	if err != nil {
		return err
	}

	// If no users exist, ensure the root setup invite is active
	if count == 0 {
		var inviteExists bool
		err = db.QueryRow("SELECT EXISTS(SELECT 1 FROM invites WHERE role = 'admin' AND is_revoked = FALSE)").Scan(&inviteExists)
		if err != nil {
			return err
		}

		if !inviteExists {
			_, err = db.Exec(`
				INSERT INTO invites (token, role, max_uses, uses_count, note)
				VALUES ($1, 'admin', 1, 0, 'Initial Root Setup Token')
				ON CONFLICT (token) DO NOTHING
			`, initialToken)
			if err != nil {
				return err
			}
			log.Printf("[SECURITY] ================================================================")
			log.Printf("[SECURITY] No users found. Root admin invite initialized:")
			log.Printf("[SECURITY] Token: %s", initialToken)
			log.Printf("[SECURITY] ================================================================")
		}
	}
	return nil
}
