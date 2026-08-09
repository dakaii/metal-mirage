package peers

import (
	"context"
	"os"
	"testing"

	"github.com/dakaii/metal-mirage/control-plane/internal/db"
)

// Integration: lowest-free allocation + hole reuse against a real Postgres.
// Skipped unless DATABASE_URL is set (e.g. local Neon).
func TestCreateAllocatesUniqueIPsAndReusesHoles(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := db.Connect(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	_, _ = pool.Exec(ctx, `DELETE FROM peers WHERE user_id=$1`, "ip-alloc-integration")

	store := NewStore(pool)
	p1, err := store.Create(ctx, "ip-alloc-integration", "a", "pubA", "us")
	if err != nil {
		t.Fatalf("create a: %v", err)
	}
	p2, err := store.Create(ctx, "ip-alloc-integration", "b", "pubB", "us")
	if err != nil {
		t.Fatalf("create b: %v", err)
	}
	if p1.AllocatedIP == p2.AllocatedIP {
		t.Fatalf("expected distinct IPs, both %s", p1.AllocatedIP)
	}
	if err := store.Delete(ctx, "ip-alloc-integration", p1.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	p3, err := store.Create(ctx, "ip-alloc-integration", "c", "pubC", "us")
	if err != nil {
		t.Fatalf("create c: %v", err)
	}
	if p3.AllocatedIP != p1.AllocatedIP {
		t.Fatalf("expected hole reuse %s, got %s", p1.AllocatedIP, p3.AllocatedIP)
	}
	byCity, err := store.ListByCity(ctx, "us")
	if err != nil {
		t.Fatalf("ListByCity: %v", err)
	}
	found := map[string]bool{}
	for _, p := range byCity {
		if p.UserID == "ip-alloc-integration" {
			found[p.Name] = true
		}
	}
	if !found["b"] || !found["c"] {
		t.Fatalf("ListByCity missing integration peers: %#v", found)
	}
	t.Logf("p1=%s p2=%s p3=%s (hole reused)", p1.AllocatedIP, p2.AllocatedIP, p3.AllocatedIP)
}
