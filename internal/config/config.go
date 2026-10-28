package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port               string
	DBHost             string
	DBPort             string
	DBUser             string
	DBPassword         string
	DBName             string
	DBSSLMode          string
	AdminInitialInvite string
	SessionSecret      string
	Environment        string
	DataDir            string
}

func Load() *Config {
	return &Config{
		Port:               getEnv("PORT", "3047"),
		DBHost:             getEnv("DB_HOST", "localhost"),
		DBPort:             getEnv("DB_PORT", "5432"),
		DBUser:             getEnv("DB_USER", "varta_user"),
		DBPassword:         getEnv("DB_PASSWORD", "varta_secure_password_2026"),
		DBName:             getEnv("DB_NAME", "varta_db"),
		DBSSLMode:          getEnv("DB_SSLMODE", "disable"),
		AdminInitialInvite: getEnv("ADMIN_INITIAL_INVITE", "VARTA-INITIAL-ROOT-SETUP-2026"),
		SessionSecret:      getEnv("SESSION_SECRET", "varta_secret_key_minimum_32_characters_long_crypto_2026"),
		Environment:        getEnv("ENV", "production"),
		DataDir:            getEnv("DATA_DIR", "/app/data"),
	}
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	if val := os.Getenv(key); val != "" {
		if intVal, err := strconv.Atoi(val); err == nil {
			return intVal
		}
	}
	return defaultVal
}
