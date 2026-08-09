// listpeers prints control-plane peers for a VPN city (operator tool).
// Used by scripts/vpn-reconcile-peers.sh — not an HTTP API.
//
// Usage:
//
//	DATABASE_URL=… go run ./cmd/listpeers -city us
//
// Output (TSV): public_key<TAB>allocated_ip<TAB>name<TAB>id
//
// Read-only: does not run migrations. Bring up ./cmd/server once (or otherwise
// apply the peers schema) before using this tool.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/dakaii/metal-mirage/control-plane/internal/db"
	"github.com/dakaii/metal-mirage/control-plane/internal/peers"
	"github.com/joho/godotenv"
)

func main() {
	city := flag.String("city", "", "VPN city filter (required; matches peers.city / vpn stack output)")
	flag.Parse()
	*city = strings.TrimSpace(*city)
	if *city == "" {
		fmt.Fprintln(os.Stderr, "usage: listpeers -city <city>")
		os.Exit(2)
	}

	_ = godotenv.Load()
	dsn := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pool, err := db.Connect(ctx, dsn)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer pool.Close()

	list, err := peers.NewStore(pool).ListByCity(ctx, *city)
	if err != nil {
		log.Fatalf("list: %v (is the peers schema migrated? run control-plane ./cmd/server once)", err)
	}
	for _, p := range list {
		fmt.Printf("%s\t%s\t%s\t%s\n", p.PublicKey, p.AllocatedIP, p.Name, p.ID)
	}
}
