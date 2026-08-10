// Package tunnel defines pluggable client-profile protocols for the optional
// peer portal. This is the profile/export half of the RemoteAccess capability
// (see pkg/ports and docs/CAPABILITY-PORTS.md). V1 ships WireGuard only;
// additional Protocol implementations can register without changing HTTP handlers.
package tunnel

import (
	"fmt"
	"sort"
	"sync"
)

// ProtocolID identifies a tunnel protocol (stable API string).
type ProtocolID string

const (
	// ProtocolWireGuard is the only protocol shipped in OSS V1.
	ProtocolWireGuard ProtocolID = "wireguard"
)

// Export IDs for WireGuard (and future protocols).
const (
	ExportWireGuardConf = "wireguard-conf"
)

// Endpoint is the server-side side of a client profile (shared per city exit).
type Endpoint struct {
	// HostPort is host:port for the client [Peer] Endpoint line.
	HostPort string
	// ServerPublicKey is the exit's WireGuard public key (base64).
	ServerPublicKey string
	// City is a short label (e.g. "us") used in filenames.
	City string
	// DNS is an optional DNS server for the client Interface block.
	DNS string
	// AllowedIPs is the WireGuard AllowedIPs value (full-tunnel by default).
	AllowedIPs string
	// KeepaliveSeconds is PersistentKeepalive (0 omits the line for WG).
	KeepaliveSeconds int
}

// DefaultEndpoint fills operator-friendly defaults for personal full-tunnel exits.
func DefaultEndpoint(hostPort, serverPub, city string) Endpoint {
	return Endpoint{
		HostPort:         hostPort,
		ServerPublicKey:  serverPub,
		City:             city,
		DNS:              "1.1.1.1",
		AllowedIPs:       "0.0.0.0/0, ::/0",
		KeepaliveSeconds: 25,
	}
}

// ClientIdentity is the device-side material for rendering exports.
type ClientIdentity struct {
	Name        string
	PrivateKey  string // base64; required for wireguard-conf body
	PublicKey   string // base64
	AddressCIDR string // e.g. 10.66.0.2/32
}

// Export is one importable artifact for a client app.
type Export struct {
	ID          string `json:"id"`
	ContentType string `json:"content_type"`
	Filename    string `json:"filename"`
	Body        string `json:"body"`
}

// FormatMeta describes an export kind without a body (for /api/tunnel/protocols).
type FormatMeta struct {
	ID          string `json:"id"`
	ContentType string `json:"content_type"`
	Extension   string `json:"extension"`
	Description string `json:"description"`
}

// ProtocolMeta is the public description of a registered protocol.
type ProtocolMeta struct {
	ID          ProtocolID   `json:"id"`
	Description string       `json:"description"`
	Formats     []FormatMeta `json:"formats"`
}

// Protocol mints keys and renders client exports for one tunnel type.
type Protocol interface {
	ID() ProtocolID
	Description() string
	Formats() []FormatMeta
	MintKeys() (privateKey, publicKey string, err error)
	RenderExports(client ClientIdentity, endpoint Endpoint) ([]Export, error)
}

// Registry maps protocol IDs to implementations.
type Registry struct {
	mu   sync.RWMutex
	byID map[ProtocolID]Protocol
}

// NewRegistry returns an empty registry. Call DefaultRegistry for the OSS set.
func NewRegistry() *Registry {
	return &Registry{byID: make(map[ProtocolID]Protocol)}
}

// Register adds or replaces a protocol.
func (r *Registry) Register(p Protocol) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.byID[p.ID()] = p
}

// Get returns a protocol by ID.
func (r *Registry) Get(id ProtocolID) (Protocol, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.byID[id]
	return p, ok
}

// List returns stable-sorted protocol metadata.
func (r *Registry) List() []ProtocolMeta {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.byID))
	for id := range r.byID {
		ids = append(ids, string(id))
	}
	sort.Strings(ids)
	out := make([]ProtocolMeta, 0, len(ids))
	for _, id := range ids {
		p := r.byID[ProtocolID(id)]
		out = append(out, ProtocolMeta{
			ID:          p.ID(),
			Description: p.Description(),
			Formats:     p.Formats(),
		})
	}
	return out
}

// DefaultRegistry registers the OSS-shipped protocols (WireGuard only).
func DefaultRegistry() *Registry {
	r := NewRegistry()
	r.Register(WireGuard{})
	return r
}

// ParseProtocolID validates a client-supplied protocol string.
func ParseProtocolID(s string) (ProtocolID, error) {
	switch ProtocolID(s) {
	case "", ProtocolWireGuard:
		return ProtocolWireGuard, nil
	default:
		return "", fmt.Errorf("unsupported protocol %q", s)
	}
}
