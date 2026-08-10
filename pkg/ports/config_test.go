package ports

import (
	"path/filepath"
	"runtime"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// pkg/ports → repo root
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

func TestLoadClustersCapabilitiesRepoDefault(t *testing.T) {
	t.Parallel()
	doc, err := LoadClustersCapabilities(filepath.Join(repoRoot(t), "config", "clusters.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if EffectiveRemoteAccessProvider(doc.RemoteAccess) != RemoteAccessNone {
		t.Fatalf("provider: %q (want none)", doc.RemoteAccess.Provider)
	}
	dir := EffectiveRemoteAccessDir(doc.RemoteAccess, doc.VPN)
	if dir != "" {
		t.Fatalf("dir: %q (want empty when none)", dir)
	}
}

func TestValidateRemoteAccessNone(t *testing.T) {
	t.Parallel()
	if err := ValidateRemoteAccess(RemoteAccessConfig{Provider: "none"}, VPNAlias{}); err != nil {
		t.Fatal(err)
	}
	if EffectiveRemoteAccessDir(RemoteAccessConfig{Provider: "none"}, VPNAlias{PulumiDir: "infra/vpn-gateways"}) != "" {
		t.Fatal("expected empty dir when none")
	}
}

func TestValidateRemoteAccessUnknown(t *testing.T) {
	t.Parallel()
	if err := ValidateRemoteAccess(RemoteAccessConfig{Provider: "tailscale"}, VPNAlias{}); err == nil {
		t.Fatal("expected error")
	}
}

func TestValidateRemoteAccessRequiresDir(t *testing.T) {
	t.Parallel()
	if err := ValidateRemoteAccess(RemoteAccessConfig{Provider: "wireguard"}, VPNAlias{}); err == nil {
		t.Fatal("expected missing dir error")
	}
	if err := ValidateRemoteAccess(RemoteAccessConfig{Provider: "wireguard"}, VPNAlias{PulumiDir: "infra/vpn-gateways"}); err != nil {
		t.Fatal(err)
	}
}

func TestParseRemoteAccessProvider(t *testing.T) {
	t.Parallel()
	p, err := ParseRemoteAccessProvider("")
	if err != nil || p != RemoteAccessNone {
		t.Fatalf("empty: %v %v", p, err)
	}
	p, err = ParseRemoteAccessProvider("wireguard")
	if err != nil || p != RemoteAccessWireGuard {
		t.Fatalf("wireguard: %v %v", p, err)
	}
	if _, err := ParseRemoteAccessProvider("openvpn"); err == nil {
		t.Fatal("expected error")
	}
}

func TestNoopLifecycle(t *testing.T) {
	t.Parallel()
	var l LifecyclePort = NoopLifecycle{}
	if l.Provider() != "noop" {
		t.Fatal(l.Provider())
	}
}
