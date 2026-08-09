package peers

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dakaii/metal-mirage/control-plane/internal/auth"
	"github.com/dakaii/metal-mirage/control-plane/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/curve25519"
)

// WireGuard client pool for city exits (matches vpn-bootstrap / cloud-init).
// .0/.1 reserved conceptually; usable hosts are 10.66.0.2 – 10.66.0.251.
const (
	peerIPPrefix   = "10.66.0."
	peerIPMinOctet = 2
	peerIPMaxOctet = 251
	// Stable advisory-lock key so concurrent Create calls serialize IP picks.
	peerIPAdvisoryLockKey int64 = 0x6d657461_6c6970 // "metalip"
)

type Peer struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	Name        string    `json:"name"`
	PublicKey   string    `json:"public_key"`
	AllocatedIP string    `json:"allocated_ip"`
	City        string    `json:"city"`
	CreatedAt   time.Time `json:"created_at"`
}

type Store struct {
	pool *pgxpool.Pool
}

func NewStore(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

func (s *Store) List(ctx context.Context, userID string) ([]Peer, error) {
	rows, err := s.pool.Query(ctx, `
SELECT id::text, user_id, name, public_key, allocated_ip, city, created_at
FROM peers WHERE user_id=$1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Peer
	for rows.Next() {
		var p Peer
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Create inserts a peer, allocating the lowest free 10.66.0.x address inside a
// transaction (advisory lock + UNIQUE(allocated_ip)) so concurrent creates and
// post-DELETE holes cannot collide.
func (s *Store) Create(ctx context.Context, userID, name, pub, city string) (Peer, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Peer{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, peerIPAdvisoryLockKey); err != nil {
		return Peer{}, err
	}
	ip, err := nextIPTx(ctx, tx)
	if err != nil {
		return Peer{}, err
	}

	var p Peer
	err = tx.QueryRow(ctx, `
INSERT INTO peers (user_id, name, public_key, allocated_ip, city)
VALUES ($1,$2,$3,$4,$5)
RETURNING id::text, user_id, name, public_key, allocated_ip, city, created_at`,
		userID, name, pub, ip, city,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.CreatedAt)
	if err != nil {
		return Peer{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Peer{}, err
	}
	return p, nil
}

func (s *Store) Delete(ctx context.Context, userID, id string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM peers WHERE id=$1::uuid AND user_id=$2`, id, userID)
	return err
}

func (s *Store) Get(ctx context.Context, userID, id string) (Peer, error) {
	var p Peer
	err := s.pool.QueryRow(ctx, `
SELECT id::text, user_id, name, public_key, allocated_ip, city, created_at
FROM peers WHERE id=$1::uuid AND user_id=$2`, id, userID,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.CreatedAt)
	return p, err
}

// NextIP returns the lowest free address in the peer pool (read-only preview).
// Prefer Create, which allocates under a lock.
func (s *Store) NextIP(ctx context.Context) (string, error) {
	return nextIPTx(ctx, s.pool)
}

type ipQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func nextIPTx(ctx context.Context, q ipQuerier) (string, error) {
	used, err := loadUsedOctets(ctx, q)
	if err != nil {
		return "", err
	}
	return nextFreeIP(used)
}

func loadUsedOctets(ctx context.Context, q ipQuerier) (map[int]struct{}, error) {
	rows, err := q.Query(ctx, `SELECT allocated_ip FROM peers`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	used := make(map[int]struct{})
	for rows.Next() {
		var ip string
		if err := rows.Scan(&ip); err != nil {
			return nil, err
		}
		if o, ok := peerPoolOctet(ip); ok {
			used[o] = struct{}{}
		}
	}
	return used, rows.Err()
}

// nextFreeIP picks the lowest unused host in 10.66.0.2–10.66.0.251.
func nextFreeIP(used map[int]struct{}) (string, error) {
	for o := peerIPMinOctet; o <= peerIPMaxOctet; o++ {
		if _, taken := used[o]; !taken {
			return peerIPPrefix + strconv.Itoa(o), nil
		}
	}
	return "", errors.New("peer IP pool exhausted (10.66.0.2–10.66.0.251)")
}

// peerPoolOctet returns the host octet if ip is in the 10.66.0.0/24 peer pool.
func peerPoolOctet(ip string) (int, bool) {
	parsed := net.ParseIP(strings.TrimSpace(ip))
	if parsed == nil {
		return 0, false
	}
	v4 := parsed.To4()
	if v4 == nil || v4[0] != 10 || v4[1] != 66 || v4[2] != 0 {
		return 0, false
	}
	o := int(v4[3])
	if o < peerIPMinOctet || o > peerIPMaxOctet {
		return 0, false
	}
	return o, true
}

type Handler struct {
	store *Store
	cfg   config.Config
}

func NewHandler(store *Store, cfg config.Config) *Handler {
	return &Handler{store: store, cfg: cfg}
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	uid := auth.UserID(r)
	peers, err := h.store.List(r.Context(), uid)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, peers)
}

type createReq struct {
	Name string `json:"name"`
}

type createResp struct {
	Peer       Peer   `json:"peer"`
	PrivateKey string `json:"private_key"`
	Config     string `json:"config"`
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	uid := auth.UserID(r)
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		http.Error(w, "name required", 400)
		return
	}
	priv, pub, err := genWGKeypair()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	peer, err := h.store.Create(r.Context(), uid, req.Name, pub, h.cfg.VPNCity)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cfg := renderClientConfig(priv, peer.AllocatedIP, h.cfg)
	writeJSON(w, createResp{Peer: peer, PrivateKey: priv, Config: cfg})
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	uid := auth.UserID(r)
	id := r.PathValue("id")
	if err := h.store.Delete(r.Context(), uid, id); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) DownloadConfig(w http.ResponseWriter, r *http.Request) {
	// Private keys are only returned at create time; this endpoint returns a
	// template using the stored public peer identity for operators.
	uid := auth.UserID(r)
	id := r.PathValue("id")
	peer, err := h.store.Get(r.Context(), uid, id)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}
	writeJSON(w, map[string]any{
		"peer":              peer,
		"note":              "private key is only shown once at POST /api/peers",
		"server_public_key": h.cfg.VPNServerPubKey,
		"endpoint":          h.cfg.VPNEndpoint,
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func genWGKeypair() (privB64, pubB64 string, err error) {
	var priv [32]byte
	if _, err = rand.Read(priv[:]); err != nil {
		return "", "", err
	}
	// clamp
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64
	var pub [32]byte
	curve25519.ScalarBaseMult(&pub, &priv)
	return base64.StdEncoding.EncodeToString(priv[:]), base64.StdEncoding.EncodeToString(pub[:]), nil
}

func renderClientConfig(priv, ip string, cfg config.Config) string {
	return fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = %s/32
DNS = 1.1.1.1

[Peer]
PublicKey = %s
Endpoint = %s
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
`, priv, ip, cfg.VPNServerPubKey, cfg.VPNEndpoint)
}
