package tunnel

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"

	"golang.org/x/crypto/curve25519"
)

// WireGuard is the stock personal-exit protocol (standard .conf export).
type WireGuard struct{}

func (WireGuard) ID() ProtocolID { return ProtocolWireGuard }

func (WireGuard) Description() string {
	return "Stock WireGuard tunnel; import the wireguard-conf export into any client that accepts standard WireGuard profiles (official apps, Shadowrocket, and similar)."
}

func (WireGuard) Formats() []FormatMeta {
	return []FormatMeta{{
		ID:          ExportWireGuardConf,
		ContentType: "text/plain; charset=utf-8",
		Extension:   ".conf",
		Description: "INI-style WireGuard config ([Interface] + [Peer])",
	}}
}

func (WireGuard) MintKeys() (privateKey, publicKey string, err error) {
	var priv [32]byte
	if _, err = rand.Read(priv[:]); err != nil {
		return "", "", err
	}
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64
	var pub [32]byte
	curve25519.ScalarBaseMult(&pub, &priv)
	return base64.StdEncoding.EncodeToString(priv[:]), base64.StdEncoding.EncodeToString(pub[:]), nil
}

func (WireGuard) RenderExports(client ClientIdentity, endpoint Endpoint) ([]Export, error) {
	if strings.TrimSpace(client.PrivateKey) == "" {
		return nil, fmt.Errorf("private key required to render %s", ExportWireGuardConf)
	}
	if strings.TrimSpace(client.AddressCIDR) == "" {
		return nil, fmt.Errorf("address required to render %s", ExportWireGuardConf)
	}
	if strings.TrimSpace(endpoint.HostPort) == "" || strings.TrimSpace(endpoint.ServerPublicKey) == "" {
		return nil, fmt.Errorf("endpoint host:port and server public key required")
	}

	dns := endpoint.DNS
	if dns == "" {
		dns = "1.1.1.1"
	}
	allowed := endpoint.AllowedIPs
	if allowed == "" {
		allowed = "0.0.0.0/0, ::/0"
	}
	keepalive := endpoint.KeepaliveSeconds
	if keepalive <= 0 {
		keepalive = 25
	}

	body := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = %s
DNS = %s

[Peer]
PublicKey = %s
Endpoint = %s
AllowedIPs = %s
PersistentKeepalive = %d
`, client.PrivateKey, client.AddressCIDR, dns, endpoint.ServerPublicKey, endpoint.HostPort, allowed, keepalive)

	name := sanitizeFilename(client.Name)
	if name == "" {
		name = "peer"
	}
	city := sanitizeFilename(endpoint.City)
	if city == "" {
		city = "vpn"
	}
	filename := city + "-" + name + ".conf"

	return []Export{{
		ID:          ExportWireGuardConf,
		ContentType: "text/plain; charset=utf-8",
		Filename:    filename,
		Body:        body,
	}}, nil
}

func sanitizeFilename(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		case r == ' ' || r == '.':
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	return out
}

// ConfBody returns the wireguard-conf body or empty if missing (helper for legacy "config" field).
func ConfBody(exports []Export) string {
	for _, e := range exports {
		if e.ID == ExportWireGuardConf {
			return e.Body
		}
	}
	return ""
}
