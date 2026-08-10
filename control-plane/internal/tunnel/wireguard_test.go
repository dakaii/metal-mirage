package tunnel

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestWireGuardMintAndRender(t *testing.T) {
	t.Parallel()
	p := WireGuard{}
	priv, pub, err := p.MintKeys()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := base64.StdEncoding.DecodeString(priv); err != nil {
		t.Fatalf("priv: %v", err)
	}
	if _, err := base64.StdEncoding.DecodeString(pub); err != nil {
		t.Fatalf("pub: %v", err)
	}

	exports, err := p.RenderExports(ClientIdentity{
		Name:        "phone",
		PrivateKey:  priv,
		PublicKey:   pub,
		AddressCIDR: "10.66.0.2/32",
	}, DefaultEndpoint("1.2.3.4:51820", "serverPubKey=", "us"))
	if err != nil {
		t.Fatal(err)
	}
	if len(exports) != 1 || exports[0].ID != ExportWireGuardConf {
		t.Fatalf("exports: %+v", exports)
	}
	if exports[0].Filename != "us-phone.conf" {
		t.Fatalf("filename %q", exports[0].Filename)
	}
	body := exports[0].Body
	for _, want := range []string{
		"[Interface]",
		"PrivateKey = " + priv,
		"Address = 10.66.0.2/32",
		"[Peer]",
		"Endpoint = 1.2.3.4:51820",
		"AllowedIPs = 0.0.0.0/0, ::/0",
		"PersistentKeepalive = 25",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("missing %q in:\n%s", want, body)
		}
	}
	if ConfBody(exports) != body {
		t.Fatal("ConfBody mismatch")
	}
}

func TestWireGuardRenderRequiresPriv(t *testing.T) {
	t.Parallel()
	_, err := WireGuard{}.RenderExports(ClientIdentity{
		Name:        "x",
		AddressCIDR: "10.66.0.2/32",
	}, DefaultEndpoint("1.2.3.4:51820", "spk", "us"))
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestDefaultRegistryListsWireGuard(t *testing.T) {
	t.Parallel()
	list := DefaultRegistry().List()
	if len(list) != 1 || list[0].ID != ProtocolWireGuard {
		t.Fatalf("list: %+v", list)
	}
	if len(list[0].Formats) != 1 || list[0].Formats[0].ID != ExportWireGuardConf {
		t.Fatalf("formats: %+v", list[0].Formats)
	}
}

func TestParseProtocolID(t *testing.T) {
	t.Parallel()
	id, err := ParseProtocolID("")
	if err != nil || id != ProtocolWireGuard {
		t.Fatalf("empty: %v %v", id, err)
	}
	id, err = ParseProtocolID("wireguard")
	if err != nil || id != ProtocolWireGuard {
		t.Fatalf("wg: %v %v", id, err)
	}
	if _, err := ParseProtocolID("shadowsocks"); err == nil {
		t.Fatal("expected unsupported")
	}
}

func TestSanitizeFilename(t *testing.T) {
	t.Parallel()
	if got := sanitizeFilename("my phone!"); got != "my-phone" {
		t.Fatalf("got %q", got)
	}
}
