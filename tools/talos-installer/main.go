package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "talos-installer: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("talos-installer", flag.ContinueOnError)
	version := fs.String("version", DefaultVersion, "Talos release tag (e.g. v1.9.5)")
	arch := fs.String("arch", "amd64", "amd64|arm64")
	asset := fs.String("asset", "iso", "iso|kernel|initramfs|uki|raw|pxe-set")
	outDir := fs.String("out", ".secrets/talos-installer", "output directory")
	writeIPXE := fs.Bool("write-ipxe", false, "also write boot.ipxe (implies fetching pxe-set if needed)")
	httpBase := fs.String("http-base", "http://PXE_HOST:8080", "base URL embedded in boot.ipxe")
	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		return err
	}

	*version = strings.TrimSpace(*version)
	if *version == "" {
		return fmt.Errorf("-version is required")
	}
	if !strings.HasPrefix(*version, "v") {
		*version = "v" + *version
	}
	*arch = strings.TrimSpace(*arch)
	if *arch != "amd64" && *arch != "arm64" {
		return fmt.Errorf("-arch must be amd64 or arm64")
	}

	absOut, err := filepath.Abs(*outDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(absOut, 0o755); err != nil {
		return err
	}

	client := &http.Client{Timeout: 30 * time.Minute}
	kind := AssetKind(strings.TrimSpace(*asset))

	fetchOne := func(k AssetKind) (string, error) {
		fmt.Fprintf(os.Stderr, "==> fetching %s (%s %s)\n", k, *version, *arch)
		p, err := FetchAsset(client, *version, *arch, k, absOut)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(os.Stderr, "    %s\n", p)
		return p, nil
	}

	switch kind {
	case "pxe-set":
		if _, err := fetchOne(AssetKernel); err != nil {
			return err
		}
		if _, err := fetchOne(AssetInitramfs); err != nil {
			return err
		}
		*writeIPXE = true
	case AssetISO, AssetKernel, AssetInitramfs, AssetUKI, AssetRaw:
		p, err := fetchOne(kind)
		if err != nil {
			return err
		}
		if kind == AssetISO {
			fmt.Print(FlashInstructions(p))
		}
	default:
		return fmt.Errorf("unsupported -asset %q", *asset)
	}

	if *writeIPXE {
		// Ensure kernel+initramfs exist when only -asset iso was requested with -write-ipxe.
		if _, err := fetchOne(AssetKernel); err != nil {
			return err
		}
		if _, err := fetchOne(AssetInitramfs); err != nil {
			return err
		}
		ipxePath, err := WriteIPXE(absOut, *arch, *version, *httpBase)
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "==> wrote %s (edit -http-base / serve lab/pxe)\n", ipxePath)
	}

	fmt.Fprintf(os.Stderr, "Done. Assets in %s\n", absOut)
	return nil
}
