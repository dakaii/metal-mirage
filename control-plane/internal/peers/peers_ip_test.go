package peers

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestNextFreeIPEmptyPool(t *testing.T) {
	t.Parallel()
	ip, err := nextFreeIP(nil)
	if err != nil {
		t.Fatal(err)
	}
	if ip != "10.66.0.2" {
		t.Fatalf("got %q, want 10.66.0.2", ip)
	}
}

func TestNextFreeIPReusesHoles(t *testing.T) {
	t.Parallel()
	used := map[int]struct{}{2: {}, 4: {}}
	ip, err := nextFreeIP(used)
	if err != nil {
		t.Fatal(err)
	}
	if ip != "10.66.0.3" {
		t.Fatalf("got %q, want hole 10.66.0.3", ip)
	}
}

func TestNextFreeIPSkipsTakenPrefix(t *testing.T) {
	t.Parallel()
	used := map[int]struct{}{}
	for o := peerIPMinOctet; o <= 10; o++ {
		used[o] = struct{}{}
	}
	ip, err := nextFreeIP(used)
	if err != nil {
		t.Fatal(err)
	}
	if ip != "10.66.0.11" {
		t.Fatalf("got %q, want 10.66.0.11", ip)
	}
}

func TestNextFreeIPExhausted(t *testing.T) {
	t.Parallel()
	used := map[int]struct{}{}
	for o := peerIPMinOctet; o <= peerIPMaxOctet; o++ {
		used[o] = struct{}{}
	}
	_, err := nextFreeIP(used)
	if err == nil {
		t.Fatal("expected exhaustion error")
	}
	if !errors.Is(err, ErrPoolExhausted) {
		t.Fatalf("got %v, want ErrPoolExhausted", err)
	}
}

func TestIsUniqueViolation(t *testing.T) {
	t.Parallel()
	if isUniqueViolation(errors.New("nope")) {
		t.Fatal("plain error should not match")
	}
	if !isUniqueViolation(&pgconn.PgError{Code: "23505"}) {
		t.Fatal("23505 should match")
	}
	if isUniqueViolation(&pgconn.PgError{Code: "23503"}) {
		t.Fatal("other SQLSTATE should not match")
	}
}

func TestPeerPoolOctet(t *testing.T) {
	t.Parallel()
	cases := []struct {
		ip     string
		want   int
		wantOK bool
	}{
		{"10.66.0.2", 2, true},
		{"10.66.0.251", 251, true},
		{"10.66.0.1", 0, false},   // reserved / out of pool
		{"10.66.0.252", 0, false}, // above max
		{"10.66.1.2", 0, false},
		{"192.168.0.2", 0, false},
		{"not-an-ip", 0, false},
		{" 10.66.0.5 ", 5, true},
	}
	for _, tc := range cases {
		got, ok := peerPoolOctet(tc.ip)
		if ok != tc.wantOK || got != tc.want {
			t.Fatalf("%q: got (%d,%v), want (%d,%v)", tc.ip, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestNextFreeIPDoesNotUseCountModulo(t *testing.T) {
	t.Parallel()
	// Old bug: after deleting peers, COUNT(*) reused colliding octets.
	// With holes at 2 and 3 gone but 4 taken, next must be 2 — not 3 (count=1 → 2+1).
	used := map[int]struct{}{4: {}}
	ip, err := nextFreeIP(used)
	if err != nil {
		t.Fatal(err)
	}
	if ip != "10.66.0.2" {
		t.Fatalf("got %q, want lowest hole 10.66.0.2", ip)
	}
}
