//go:build syncconfig

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// CLI: go run -tags syncconfig . <path-to-clusters.yaml>
// Prints five lines: nodesJSON, apiEndpointIP, ingressIP, installDisk, dryRun(true|false)
func main() {
	path := filepath.Join("..", "..", "config", "clusters.yaml")
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	doc, err := LoadClustersFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load %s: %v\n", path, err)
		os.Exit(1)
	}
	cfg, err := ResolveBareMetalPulumiConfig(doc.Primary)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve: %v\n", err)
		os.Exit(1)
	}
	dry := "false"
	if cfg.DryRun {
		dry = "true"
	}
	fmt.Println(cfg.NodesJSON)
	fmt.Println(cfg.APIEndpointIP)
	fmt.Println(cfg.IngressIP)
	fmt.Println(cfg.InstallDisk)
	fmt.Println(dry)
}
