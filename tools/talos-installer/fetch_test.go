package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseChecksums(t *testing.T) {
	t.Parallel()
	in := `
# comment
aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  metal-amd64.iso
11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff *vmlinuz-amd64
`
	m, err := ParseChecksums(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if m["metal-amd64.iso"] != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("iso: %q", m["metal-amd64.iso"])
	}
	if m["vmlinuz-amd64"] != "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff" {
		t.Fatalf("kernel: %q", m["vmlinuz-amd64"])
	}
}

func TestFetchAssetVerifiesChecksum(t *testing.T) {
	// Not parallel: mutates package-level ReleaseBase.
	body := []byte("talos-installer-fixture")
	sum := sha256.Sum256(body)
	hexSum := hex.EncodeToString(sum[:])
	sums := hexSum + "  metal-amd64.iso\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/sha256sum.txt"):
			_, _ = w.Write([]byte(sums))
		case strings.HasSuffix(r.URL.Path, "/metal-amd64.iso"):
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	prev := ReleaseBase
	ReleaseBase = srv.URL + "/download"
	t.Cleanup(func() { ReleaseBase = prev })

	dir := t.TempDir()
	path, err := FetchAsset(srv.Client(), "v0.0.0-test", "amd64", AssetISO, dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(body) {
		t.Fatalf("body mismatch")
	}

	// Second fetch should reuse cached file.
	path2, err := FetchAsset(srv.Client(), "v0.0.0-test", "amd64", AssetISO, dir)
	if err != nil || path2 != path {
		t.Fatalf("cache: %v %q", err, path2)
	}
}

func TestFetchAssetRejectsBadChecksum(t *testing.T) {
	// Not parallel: mutates package-level ReleaseBase.
	sums := strings.Repeat("0", 64) + "  metal-amd64.iso\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/sha256sum.txt") {
			_, _ = w.Write([]byte(sums))
			return
		}
		_, _ = w.Write([]byte("nope"))
	}))
	t.Cleanup(srv.Close)
	prev := ReleaseBase
	ReleaseBase = srv.URL + "/download"
	t.Cleanup(func() { ReleaseBase = prev })

	_, err := FetchAsset(srv.Client(), "v0.0.0-test", "amd64", AssetISO, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "sha256 mismatch") {
		t.Fatalf("expected mismatch, got %v", err)
	}
}

func TestWriteIPXE(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	p, err := WriteIPXE(dir, "amd64", "v1.9.5", "http://10.0.0.1:8080")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, want := range []string{"#!ipxe", "vmlinuz-amd64", "initramfs-amd64.xz", "http://10.0.0.1:8080"} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %q in %s", want, s)
		}
	}
	if filepath.Base(p) != "boot.ipxe" {
		t.Fatalf("name: %s", p)
	}
}
