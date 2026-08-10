package ports

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// RemoteAccessConfig is the remote_access stanza of config/clusters.yaml.
type RemoteAccessConfig struct {
	// Provider is none (platform default) or wireguard.
	Provider string `yaml:"provider"`
	// PulumiDir selects the RemoteAccess adapter stack (ignored when provider=none).
	PulumiDir string `yaml:"pulumi_dir"`
}

// VPNAlias is the legacy vpn: stanza (same plane; kept for script compatibility).
type VPNAlias struct {
	PulumiDir string `yaml:"pulumi_dir"`
}

// ClustersCapabilities is the capability-oriented view of config/clusters.yaml.
// Primary compute validation remains in infra/bare-metal; this focuses on
// remote_access (+ optional vpn alias).
type ClustersCapabilities struct {
	RemoteAccess RemoteAccessConfig `yaml:"remote_access"`
	VPN          VPNAlias           `yaml:"vpn"`
}

// LoadClustersCapabilities reads remote_access / vpn from clusters.yaml.
func LoadClustersCapabilities(path string) (*ClustersCapabilities, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc ClustersCapabilities
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := ValidateRemoteAccess(doc.RemoteAccess, doc.VPN); err != nil {
		return nil, err
	}
	return &doc, nil
}

// ValidateRemoteAccess enforces the RemoteAccess port config contract.
func ValidateRemoteAccess(ra RemoteAccessConfig, vpn VPNAlias) error {
	provider := string(EffectiveRemoteAccessProvider(ra))
	switch RemoteAccessProvider(provider) {
	case RemoteAccessWireGuard, RemoteAccessNone:
		// ok
	default:
		return fmt.Errorf("remote_access.provider %q is unsupported (want wireguard|none)", provider)
	}

	if RemoteAccessProvider(provider) == RemoteAccessNone {
		return nil
	}

	dir := strings.TrimSpace(ra.PulumiDir)
	if dir == "" {
		dir = strings.TrimSpace(vpn.PulumiDir)
	}
	if dir == "" {
		return fmt.Errorf("remote_access.pulumi_dir is required when provider=%s (or set vpn.pulumi_dir)", provider)
	}
	return nil
}

// EffectiveRemoteAccessProvider returns the resolved provider id.
// Empty provider defaults to none (metal-first / platform-only). Explicit
// "wireguard" enables the city-exit adapter.
func EffectiveRemoteAccessProvider(ra RemoteAccessConfig) RemoteAccessProvider {
	p := strings.TrimSpace(ra.Provider)
	if p == "" {
		return RemoteAccessNone
	}
	return RemoteAccessProvider(p)
}

// EffectiveRemoteAccessDir returns the adapter directory for wireguard (empty if none).
func EffectiveRemoteAccessDir(ra RemoteAccessConfig, vpn VPNAlias) string {
	if EffectiveRemoteAccessProvider(ra) == RemoteAccessNone {
		return ""
	}
	if d := strings.TrimSpace(ra.PulumiDir); d != "" {
		return d
	}
	if d := strings.TrimSpace(vpn.PulumiDir); d != "" {
		return d
	}
	return "infra/vpn-gateways"
}

// ParseRemoteAccessProvider validates a provider string.
func ParseRemoteAccessProvider(s string) (RemoteAccessProvider, error) {
	switch RemoteAccessProvider(strings.TrimSpace(s)) {
	case "", RemoteAccessNone:
		return RemoteAccessNone, nil
	case RemoteAccessWireGuard:
		return RemoteAccessWireGuard, nil
	default:
		return "", fmt.Errorf("unsupported remote_access provider %q", s)
	}
}
