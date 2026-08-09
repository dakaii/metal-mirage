package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dakaii/azure-hybrid-platform/control-plane/internal/auth"
	"github.com/dakaii/azure-hybrid-platform/control-plane/internal/config"
	"github.com/dakaii/azure-hybrid-platform/control-plane/internal/db"
	"github.com/dakaii/azure-hybrid-platform/control-plane/internal/peers"
	"github.com/joho/godotenv"
)

func main() {
	_ = godotenv.Load()
	cfg := config.Load()

	ctx := context.Background()
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer pool.Close()

	if err := db.Migrate(ctx, pool); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	clerkAuth, err := auth.NewClerk(cfg.ClerkSecretKey)
	if err != nil {
		log.Fatalf("clerk: %v", err)
	}

	store := peers.NewStore(pool)
	api := peers.NewHandler(store, cfg)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("GET /api/peers", clerkAuth.Middleware(http.HandlerFunc(api.List)))
	mux.Handle("POST /api/peers", clerkAuth.Middleware(http.HandlerFunc(api.Create)))
	mux.Handle("DELETE /api/peers/{id}", clerkAuth.Middleware(http.HandlerFunc(api.Delete)))
	mux.Handle("GET /api/peers/{id}/config", clerkAuth.Middleware(http.HandlerFunc(api.DownloadConfig)))

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("control-plane listening on :%s", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("serve: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}
