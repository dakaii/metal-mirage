package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// DefaultVersion matches scripts/register-talos-image.sh.
const DefaultVersion = "v1.9.5"

// ReleaseBase is the GitHub releases download root (overridable in tests).
var ReleaseBase = "https://github.com/siderolabs/talos/releases/download"

// AssetKind is a Talos release artifact we know how to fetch.
type AssetKind string

const (
	AssetISO       AssetKind = "iso"
	AssetKernel    AssetKind = "kernel"
	AssetInitramfs AssetKind = "initramfs"
	AssetUKI       AssetKind = "uki"
	AssetRaw       AssetKind = "raw"
)

func assetFileName(kind AssetKind, arch string) (string, error) {
	switch kind {
	case AssetISO:
		return fmt.Sprintf("metal-%s.iso", arch), nil
	case AssetKernel:
		return fmt.Sprintf("vmlinuz-%s", arch), nil
	case AssetInitramfs:
		return fmt.Sprintf("initramfs-%s.xz", arch), nil
	case AssetUKI:
		// UKI naming stabilized as metal-<arch>-uki.efi on newer releases;
		// v1.9.x may omit it — fetch will fail with a clear checksum miss.
		return fmt.Sprintf("metal-%s-uki.efi", arch), nil
	case AssetRaw:
		return fmt.Sprintf("metal-%s.raw.zst", arch), nil
	default:
		return "", fmt.Errorf("unsupported asset %q (want iso|kernel|initramfs|uki|raw)", kind)
	}
}

// ParseChecksums reads sha256sum.txt content into filename → hex digest.
func ParseChecksums(r io.Reader) (map[string]string, error) {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return nil, fmt.Errorf("bad checksum line: %q", line)
		}
		sum := fields[0]
		name := fields[len(fields)-1]
		name = path.Base(strings.TrimPrefix(name, "*"))
		if len(sum) != 64 {
			return nil, fmt.Errorf("bad sha256 length for %s", name)
		}
		out[name] = sum
	}
	return out, sc.Err()
}

func checksumURL(version string) string {
	return fmt.Sprintf("%s/%s/sha256sum.txt", strings.TrimRight(ReleaseBase, "/"), version)
}

func assetURL(version, fileName string) string {
	return fmt.Sprintf("%s/%s/%s", strings.TrimRight(ReleaseBase, "/"), version, fileName)
}

func fetchURL(client *http.Client, url, dest string) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "metal-mirage-talos-installer/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.Copy(f, resp.Body); err != nil {
		return err
	}
	return nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// FetchAsset downloads one release file and verifies sha256 against sha256sum.txt.
func FetchAsset(client *http.Client, version, arch string, kind AssetKind, outDir string) (string, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Minute}
	}
	fileName, err := assetFileName(kind, arch)
	if err != nil {
		return "", err
	}
	sumPath := filepath.Join(outDir, "sha256sum.txt")
	if err := fetchURL(client, checksumURL(version), sumPath); err != nil {
		return "", fmt.Errorf("checksums: %w", err)
	}
	f, err := os.Open(sumPath)
	if err != nil {
		return "", err
	}
	sums, err := ParseChecksums(f)
	_ = f.Close()
	if err != nil {
		return "", err
	}
	want, ok := sums[fileName]
	if !ok {
		return "", fmt.Errorf("%s not listed in sha256sum.txt for %s (asset may not exist for this version)", fileName, version)
	}

	dest := filepath.Join(outDir, fileName)
	if st, err := os.Stat(dest); err == nil && st.Size() > 0 {
		got, err := fileSHA256(dest)
		if err == nil && got == want {
			return dest, nil // already present + valid
		}
	}

	tmp := dest + ".partial"
	if err := fetchURL(client, assetURL(version, fileName), tmp); err != nil {
		return "", err
	}
	got, err := fileSHA256(tmp)
	if err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	if got != want {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("sha256 mismatch for %s: got %s want %s", fileName, got, want)
	}
	if err := os.Rename(tmp, dest); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return dest, nil
}

// FlashInstructions returns operator hints after an ISO download.
func FlashInstructions(isoPath string) string {
	return fmt.Sprintf(`ISO ready: %s

Flash (pick one), then boot the node into Talos maintenance mode (apid :50000):

  # Linux example — DOUBLE-CHECK the device (destroys the target disk/USB):
  sudo dd if=%s of=/dev/sdX bs=4M status=progress oflag=sync

  # Or use Ventoy / balenaEtcher / Rufus with the ISO.

Next:
  ./scripts/export-baremetal-machine-configs.sh   # after dry-run up (PR/metal P1)
  # or set dry_run: false and ./scripts/up.sh primary once nodes are in maintenance
See docs/INSTALL-TALOS.md
`, isoPath, isoPath)
}
