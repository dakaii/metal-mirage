package config

import "os"

type Config struct {
	Port            string
	DatabaseURL     string
	ClerkSecretKey  string
	VPNEndpoint     string // host:port for WireGuard endpoint in generated configs
	VPNServerPubKey string
	VPNCity         string
}

func Load() Config {
	return Config{
		Port:            getenv("PORT", "8080"),
		DatabaseURL:     must("DATABASE_URL"),
		ClerkSecretKey:  must("CLERK_SECRET_KEY"),
		VPNEndpoint:     getenv("VPN_ENDPOINT", ""),
		VPNServerPubKey: getenv("VPN_SERVER_PUBLIC_KEY", ""),
		VPNCity:         getenv("VPN_CITY", "us"),
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func must(k string) string {
	v := os.Getenv(k)
	if v == "" {
		panic("missing required env: " + k)
	}
	return v
}
