package peers

import (
	"context"
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
	"github.com/dakaii/metal-mirage/control-plane/internal/tunnel"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
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

// ErrPoolExhausted is returned when every address in 10.66.0.2–251 is taken.
var ErrPoolExhausted = errors.New("peer IP pool exhausted (10.66.0.2–10.66.0.251)")

// ErrDuplicateName is returned when (user_id, name) already exists.
var ErrDuplicateName = errors.New("peer name already exists")

type Peer struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	Name        string    `json:"name"`
	PublicKey   string    `json:"public_key"`
	AllocatedIP string    `json:"allocated_ip"`
	City        string    `json:"city"`
	Protocol    string    `json:"protocol"`
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
SELECT id::text, user_id, name, public_key, allocated_ip, city, protocol, created_at
FROM peers WHERE user_id=$1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanPeers(rows)
}

// ListByCity returns all peers for a VPN city (operator / reconciler path).
// Not exposed on the Clerk-authenticated HTTP API.
func (s *Store) ListByCity(ctx context.Context, city string) ([]Peer, error) {
	rows, err := s.pool.Query(ctx, `
SELECT id::text, user_id, name, public_key, allocated_ip, city, protocol, created_at
FROM peers WHERE city=$1 ORDER BY allocated_ip`, city)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanPeers(rows)
}

func scanPeers(rows pgx.Rows) ([]Peer, error) {
	var out []Peer
	for rows.Next() {
		var p Peer
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.Protocol, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Create inserts a peer, allocating the lowest free 10.66.0.x address inside a
// transaction (advisory lock + UNIQUE(allocated_ip)) so concurrent creates and
// post-DELETE holes cannot collide.
func (s *Store) Create(ctx context.Context, userID, name, pub, city, protocol string) (Peer, error) {
	if protocol == "" {
		protocol = string(tunnel.ProtocolWireGuard)
	}
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
INSERT INTO peers (user_id, name, public_key, allocated_ip, city, protocol)
VALUES ($1,$2,$3,$4,$5,$6)
RETURNING id::text, user_id, name, public_key, allocated_ip, city, protocol, created_at`,
		userID, name, pub, ip, city, protocol,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.Protocol, &p.CreatedAt)
	if err != nil {
		if isUniqueViolation(err) {
			return Peer{}, ErrDuplicateName
		}
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
SELECT id::text, user_id, name, public_key, allocated_ip, city, protocol, created_at
FROM peers WHERE id=$1::uuid AND user_id=$2`, id, userID,
	).Scan(&p.ID, &p.UserID, &p.Name, &p.PublicKey, &p.AllocatedIP, &p.City, &p.Protocol, &p.CreatedAt)
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
	return "", ErrPoolExhausted
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
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
	store    *Store
	cfg      config.Config
	registry *tunnel.Registry
}

func NewHandler(store *Store, cfg config.Config, registry *tunnel.Registry) *Handler {
	if registry == nil {
		registry = tunnel.DefaultRegistry()
	}
	return &Handler{store: store, cfg: cfg, registry: registry}
}

// ListProtocols is public (no Clerk) — describes registered tunnel profile types.
func (h *Handler) ListProtocols(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]any{
		"protocols": h.registry.List(),
	})
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
	Name     string `json:"name"`
	Protocol string `json:"protocol"` // optional; default wireguard
}

type createResp struct {
	Peer       Peer            `json:"peer"`
	PrivateKey string          `json:"private_key"`
	Protocol   string          `json:"protocol"`
	Config     string          `json:"config"`  // legacy alias: wireguard-conf body
	Exports    []tunnel.Export `json:"exports"` // preferred: typed client imports
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	uid := auth.UserID(r)
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		http.Error(w, "name required", http.StatusBadRequest)
		return
	}
	protoID, err := tunnel.ParseProtocolID(strings.TrimSpace(req.Protocol))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	proto, ok := h.registry.Get(protoID)
	if !ok {
		http.Error(w, "unsupported protocol", http.StatusBadRequest)
		return
	}
	endpoint := tunnel.DefaultEndpoint(h.cfg.VPNEndpoint, h.cfg.VPNServerPubKey, h.cfg.VPNCity)
	if err := validateExportEndpoint(protoID, endpoint); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	priv, pub, err := proto.MintKeys()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	peer, err := h.store.Create(r.Context(), uid, req.Name, pub, h.cfg.VPNCity, string(protoID))
	if err != nil {
		switch {
		case errors.Is(err, ErrPoolExhausted):
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
		case errors.Is(err, ErrDuplicateName):
			http.Error(w, err.Error(), http.StatusConflict)
		default:
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}
	exports, err := proto.RenderExports(tunnel.ClientIdentity{
		Name:        peer.Name,
		PrivateKey:  priv,
		PublicKey:   pub,
		AddressCIDR: peer.AllocatedIP + "/32",
	}, endpoint)
	if err != nil {
		// Best-effort rollback so a render failure does not leave an orphan peer.
		if delErr := h.store.Delete(r.Context(), uid, peer.ID); delErr != nil {
			http.Error(w, fmt.Sprintf("render exports: %v (also failed to roll back peer %s: %v)", err, peer.ID, delErr), http.StatusInternalServerError)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, createResp{
		Peer:       peer,
		PrivateKey: priv,
		Protocol:   string(protoID),
		Config:     tunnel.ConfBody(exports),
		Exports:    exports,
	})
}

// validateExportEndpoint checks server-side fields required to render client exports
// *before* inserting a peer row (avoids orphans when VPN_* env is incomplete).
func validateExportEndpoint(id tunnel.ProtocolID, endpoint tunnel.Endpoint) error {
	if id != tunnel.ProtocolWireGuard {
		return nil
	}
	if strings.TrimSpace(endpoint.HostPort) == "" {
		return fmt.Errorf("VPN_ENDPOINT is required to mint wireguard client exports (host:port)")
	}
	if strings.TrimSpace(endpoint.ServerPublicKey) == "" {
		return fmt.Errorf("VPN_SERVER_PUBLIC_KEY is required to mint wireguard client exports")
	}
	return nil
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
	// Private keys are only returned at create time; this endpoint returns
	// protocol metadata and export format IDs for operators.
	uid := auth.UserID(r)
	id := r.PathValue("id")
	peer, err := h.store.Get(r.Context(), uid, id)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}
	var formats []tunnel.FormatMeta
	if p, ok := h.registry.Get(tunnel.ProtocolID(peer.Protocol)); ok {
		formats = p.Formats()
	}
	writeJSON(w, map[string]any{
		"peer":              peer,
		"note":              "private key is only shown once at POST /api/peers; re-import from the create response exports",
		"server_public_key": h.cfg.VPNServerPubKey,
		"endpoint":          h.cfg.VPNEndpoint,
		"export_formats":    formats,
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
