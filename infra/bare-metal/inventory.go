package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// NodeRole is a Talos machine type used in the portable inventory contract.
type NodeRole string

const (
	RoleControlPlane NodeRole = "controlplane"
	RoleWorker       NodeRole = "worker"
)

// Node is one bare-metal host in the L1 inventory.
type Node struct {
	Role NodeRole `json:"role" yaml:"role"`
	IP   string   `json:"ip" yaml:"ip"`
}

// PrimaryCluster is the primary stanza of config/clusters.yaml.
type PrimaryCluster struct {
	Provisioner string `yaml:"provisioner"`
	PulumiDir   string `yaml:"pulumi_dir"`
	Profile     string `yaml:"profile"`
	Nodes       []Node `yaml:"nodes"`
}

// ClustersFile is the portable provisioner switch document.
type ClustersFile struct {
	Primary PrimaryCluster `yaml:"primary"`
}

// ParseNodesJSON parses the Pulumi config JSON array of nodes.
func ParseNodesJSON(raw string) ([]Node, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("nodes config is empty")
	}
	var nodes []Node
	if err := json.Unmarshal([]byte(raw), &nodes); err != nil {
		return nil, fmt.Errorf("parse nodes JSON: %w", err)
	}
	return nodes, ValidateNodes(nodes)
}

// LoadClustersFile reads and lightly validates config/clusters.yaml.
func LoadClustersFile(path string) (*ClustersFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc ClustersFile
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := ValidatePrimary(doc.Primary); err != nil {
		return nil, err
	}
	return &doc, nil
}

// ValidatePrimary enforces the portable L1 switch contract for primary.
func ValidatePrimary(p PrimaryCluster) error {
	switch p.Provisioner {
	case "azure-metal-sim", "bare-metal", "aks":
		// ok
	case "":
		return fmt.Errorf("primary.provisioner is required")
	default:
		return fmt.Errorf("primary.provisioner %q is unsupported (want azure-metal-sim|bare-metal|aks)", p.Provisioner)
	}
	if strings.TrimSpace(p.PulumiDir) == "" {
		return fmt.Errorf("primary.pulumi_dir is required")
	}

	switch p.Provisioner {
	case "azure-metal-sim":
		if p.PulumiDir != "infra/primary" {
			return fmt.Errorf("primary.pulumi_dir for azure-metal-sim must be infra/primary (got %q)", p.PulumiDir)
		}
	case "bare-metal":
		if p.PulumiDir != "infra/bare-metal" {
			return fmt.Errorf("primary.pulumi_dir for bare-metal must be infra/bare-metal (got %q)", p.PulumiDir)
		}
		if err := ValidateNodes(p.Nodes); err != nil {
			return fmt.Errorf("primary.nodes: %w", err)
		}
	}
	return nil
}

// ValidateNodes checks role/IP inventory used by the bare-metal provisioner.
func ValidateNodes(nodes []Node) error {
	if len(nodes) == 0 {
		return fmt.Errorf("at least one node is required")
	}
	seen := map[string]struct{}{}
	cp := 0
	for i, n := range nodes {
		role := NodeRole(strings.TrimSpace(string(n.Role)))
		ip := strings.TrimSpace(n.IP)
		switch role {
		case RoleControlPlane:
			cp++
		case RoleWorker:
			// ok
		default:
			return fmt.Errorf("node[%d]: role %q invalid (want controlplane|worker)", i, n.Role)
		}
		if net.ParseIP(ip) == nil {
			return fmt.Errorf("node[%d]: ip %q is not a valid IP", i, n.IP)
		}
		if _, ok := seen[ip]; ok {
			return fmt.Errorf("node[%d]: duplicate ip %s", i, ip)
		}
		seen[ip] = struct{}{}
	}
	if cp == 0 {
		return fmt.Errorf("at least one controlplane node is required")
	}
	return nil
}

// FirstControlPlaneIP returns the first control-plane node IP.
func FirstControlPlaneIP(nodes []Node) (string, error) {
	for _, n := range nodes {
		if n.Role == RoleControlPlane {
			return strings.TrimSpace(n.IP), nil
		}
	}
	return "", fmt.Errorf("no controlplane node")
}

// NodesToJSON serializes inventory for Pulumi config.
func NodesToJSON(nodes []Node) (string, error) {
	b, err := json.Marshal(nodes)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
