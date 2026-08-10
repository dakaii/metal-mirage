package peers

import (
	"strings"
	"testing"

	"github.com/dakaii/metal-mirage/control-plane/internal/tunnel"
)

func TestValidateExportEndpointRequiresWGFields(t *testing.T) {
	t.Parallel()
	err := validateExportEndpoint(tunnel.ProtocolWireGuard, tunnel.Endpoint{})
	if err == nil || !strings.Contains(err.Error(), "VPN_ENDPOINT") {
		t.Fatalf("expected VPN_ENDPOINT error, got %v", err)
	}
	err = validateExportEndpoint(tunnel.ProtocolWireGuard, tunnel.Endpoint{HostPort: "1.2.3.4:51820"})
	if err == nil || !strings.Contains(err.Error(), "VPN_SERVER_PUBLIC_KEY") {
		t.Fatalf("expected pubkey error, got %v", err)
	}
	err = validateExportEndpoint(tunnel.ProtocolWireGuard, tunnel.DefaultEndpoint("1.2.3.4:51820", "spk", "us"))
	if err != nil {
		t.Fatal(err)
	}
}
