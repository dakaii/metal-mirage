package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/dakaii/metal-mirage/pkg/ports"
)

// Offline check: remote_access + lifecycle against config/clusters.yaml.
// Usage: go -C pkg/ports run ./cmd/validate-clusters [path]
func main() {
	path := filepath.Join("..", "..", "config", "clusters.yaml")
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if _, err := ports.LoadClustersCapabilities(path); err != nil {
		fmt.Fprintf(os.Stderr, "capability ports: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("OK — remote_access + lifecycle")
}
