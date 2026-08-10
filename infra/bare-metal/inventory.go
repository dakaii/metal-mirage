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

// NodeBMC is optional out-of-band management metadata (Lifecycle seam).
// Never put passwords here — credentials stay in env / a secret store.
// json:"-" keeps BMC out of Pulumi baremetal:nodes JSON.
type NodeBMC struct {
	Endpoint string `yaml:"endpoint"` // e.g. https://192.168.1.100
	Username string `yaml:"username"`
}

// Node is one bare-metal host in the L1 inventory.
type Node struct {
	Role NodeRole `json:"role" yaml:"role"`
	IP   string   `json:"ip" yaml:"ip"`
	BMC  *NodeBMC `json:"-" yaml:"bmc"`
}

// PrimaryCluster is the primary stanza of config/clusters.yaml.
// Optional bare-metal fields (api_endpoint_ip, etc.) are the single source of
// truth synced into Pulumi by ./scripts/sync-baremetal-config.sh.
type PrimaryCluster struct {
	Provisioner   string `yaml:"provisioner"`
	PulumiDir     string `yaml:"pulumi_dir"`
	Profile       string `yaml:"profile"`
	Nodes         []Node `yaml:"nodes"`
	APIEndpointIP string `yaml:"api_endpoint_ip"`
	IngressIP     string `yaml:"ingress_ip"`
	InstallDisk   string `yaml:"install_disk"`
	// DryRun is optional; nil means default true for bare-metal offline safety.
	DryRun *bool `yaml:"dry_run"`
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
// On success, roles and IPs are trimmed in place so callers can compare reliably.
func ValidateNodes(nodes []Node) error {
	if len(nodes) == 0 {
		return fmt.Errorf("at least one node is required")
	}
	seen := map[string]struct{}{}
	cp := 0
	for i := range nodes {
		role := NodeRole(strings.TrimSpace(string(nodes[i].Role)))
		ip := strings.TrimSpace(nodes[i].IP)
		switch role {
		case RoleControlPlane:
			cp++
		case RoleWorker:
			// ok
		default:
			return fmt.Errorf("node[%d]: role %q invalid (want controlplane|worker)", i, nodes[i].Role)
		}
		if net.ParseIP(ip) == nil {
			return fmt.Errorf("node[%d]: ip %q is not a valid IP", i, nodes[i].IP)
		}
		if _, ok := seen[ip]; ok {
			return fmt.Errorf("node[%d]: duplicate ip %s", i, ip)
		}
		seen[ip] = struct{}{}
		nodes[i].Role = role
		nodes[i].IP = ip
		if nodes[i].BMC != nil {
			ep := strings.TrimSpace(nodes[i].BMC.Endpoint)
			if ep == "" {
				return fmt.Errorf("node[%d]: bmc.endpoint is required when bmc: is set", i)
			}
			if !strings.HasPrefix(ep, "https://") && !strings.HasPrefix(ep, "http://") {
				return fmt.Errorf("node[%d]: bmc.endpoint must be http(s) URL", i)
			}
			nodes[i].BMC.Endpoint = ep
			nodes[i].BMC.Username = strings.TrimSpace(nodes[i].BMC.Username)
		}
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

// BareMetalPulumiConfig is the resolved baremetal:* key set from clusters.yaml.
type BareMetalPulumiConfig struct {
	NodesJSON     string
	APIEndpointIP string
	IngressIP     string
	InstallDisk   string
	DryRun        bool
}

// ResolveBareMetalPulumiConfig maps primary: inventory fields → Pulumi keys.
func ResolveBareMetalPulumiConfig(p PrimaryCluster) (BareMetalPulumiConfig, error) {
	if err := ValidatePrimary(p); err != nil {
		return BareMetalPulumiConfig{}, err
	}
	if p.Provisioner != "bare-metal" {
		return BareMetalPulumiConfig{}, fmt.Errorf("provisioner is %q (want bare-metal)", p.Provisioner)
	}
	nodesJSON, err := NodesToJSON(p.Nodes)
	if err != nil {
		return BareMetalPulumiConfig{}, err
	}
	firstCP, err := FirstControlPlaneIP(p.Nodes)
	if err != nil {
		return BareMetalPulumiConfig{}, err
	}
	api := strings.TrimSpace(p.APIEndpointIP)
	if api == "" {
		api = firstCP
	}
	ingress := strings.TrimSpace(p.IngressIP)
	if ingress == "" {
		ingress = api
	}
	disk := strings.TrimSpace(p.InstallDisk)
	if disk == "" {
		disk = "/dev/sda"
	}
	dry := true
	if p.DryRun != nil {
		dry = *p.DryRun
	}
	return BareMetalPulumiConfig{
		NodesJSON:     nodesJSON,
		APIEndpointIP: api,
		IngressIP:     ingress,
		InstallDisk:   disk,
		DryRun:        dry,
	}, nil
}
