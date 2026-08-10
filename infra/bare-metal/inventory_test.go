package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateNodes(t *testing.T) {
	t.Parallel()
	if err := ValidateNodes([]Node{
		{Role: RoleControlPlane, IP: "192.168.1.10"},
		{Role: RoleWorker, IP: "192.168.1.11"},
	}); err != nil {
		t.Fatalf("valid inventory rejected: %v", err)
	}

	cases := []struct {
		name  string
		nodes []Node
	}{
		{"empty", nil},
		{"no-cp", []Node{{Role: RoleWorker, IP: "10.0.0.1"}}},
		{"bad-role", []Node{{Role: "master", IP: "10.0.0.1"}}},
		{"bad-ip", []Node{{Role: RoleControlPlane, IP: "not-an-ip"}}},
		{"dup-ip", []Node{
			{Role: RoleControlPlane, IP: "10.0.0.1"},
			{Role: RoleWorker, IP: "10.0.0.1"},
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if err := ValidateNodes(tc.nodes); err == nil {
				t.Fatalf("expected error for %s", tc.name)
			}
		})
	}
}

func TestParseNodesJSON(t *testing.T) {
	t.Parallel()
	nodes, err := ParseNodesJSON(`[{"role":"controlplane","ip":"10.0.0.5"},{"role":"worker","ip":"10.0.0.6"}]`)
	if err != nil {
		t.Fatal(err)
	}
	ip, err := FirstControlPlaneIP(nodes)
	if err != nil || ip != "10.0.0.5" {
		t.Fatalf("FirstControlPlaneIP = %q, %v", ip, err)
	}
}

func TestValidateNodesTrimsFields(t *testing.T) {
	t.Parallel()
	nodes := []Node{{Role: " controlplane ", IP: " 10.0.0.9 "}}
	if err := ValidateNodes(nodes); err != nil {
		t.Fatal(err)
	}
	if nodes[0].Role != RoleControlPlane || nodes[0].IP != "10.0.0.9" {
		t.Fatalf("expected trimmed fields, got %#v", nodes[0])
	}
}

func TestFormatClusterEndpoint(t *testing.T) {
	t.Parallel()
	if got := formatClusterEndpoint("10.0.0.1"); got != "https://10.0.0.1:6443" {
		t.Fatalf("ipv4: %q", got)
	}
	if got := formatClusterEndpoint("2001:db8::1"); got != "https://[2001:db8::1]:6443" {
		t.Fatalf("ipv6: %q", got)
	}
}

func TestLoadClustersFileDefault(t *testing.T) {
	t.Parallel()
	path := filepath.Join("..", "..", "config", "clusters.yaml")
	doc, err := LoadClustersFile(path)
	if err != nil {
		t.Fatalf("default clusters.yaml invalid: %v", err)
	}
	if doc.Primary.Provisioner != "bare-metal" {
		t.Fatalf("got provisioner %q (want bare-metal)", doc.Primary.Provisioner)
	}
	if doc.Primary.PulumiDir != "infra/bare-metal" {
		t.Fatalf("got pulumi_dir %q", doc.Primary.PulumiDir)
	}
	cfg, err := ResolveBareMetalPulumiConfig(doc.Primary)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.DryRun {
		t.Fatal("default dry_run should be true")
	}
	if cfg.APIEndpointIP != "192.168.1.10" || cfg.IngressIP != "192.168.1.10" {
		t.Fatalf("endpoints: api=%q ingress=%q", cfg.APIEndpointIP, cfg.IngressIP)
	}
}

func TestLoadClustersAzureExample(t *testing.T) {
	t.Parallel()
	path := filepath.Join("..", "..", "config", "clusters.azure-metal-sim.example.yaml")
	doc, err := LoadClustersFile(path)
	if err != nil {
		t.Fatalf("azure example invalid: %v", err)
	}
	if doc.Primary.Provisioner != "azure-metal-sim" {
		t.Fatalf("got provisioner %q", doc.Primary.Provisioner)
	}
}

func TestLoadClustersBareMetalExample(t *testing.T) {
	t.Parallel()
	path := filepath.Join("..", "..", "config", "clusters.bare-metal.example.yaml")
	doc, err := LoadClustersFile(path)
	if err != nil {
		t.Fatalf("bare-metal example invalid: %v", err)
	}
	if doc.Primary.Provisioner != "bare-metal" {
		t.Fatalf("got provisioner %q", doc.Primary.Provisioner)
	}
	if doc.Primary.PulumiDir != "infra/bare-metal" {
		t.Fatalf("got pulumi_dir %q", doc.Primary.PulumiDir)
	}
	if err := ValidateNodes(doc.Primary.Nodes); err != nil {
		t.Fatal(err)
	}
}

func TestValidatePrimaryRejectsMismatchedDir(t *testing.T) {
	t.Parallel()
	err := ValidatePrimary(PrimaryCluster{
		Provisioner: "bare-metal",
		PulumiDir:   "infra/primary",
		Nodes:       []Node{{Role: RoleControlPlane, IP: "10.0.0.1"}},
	})
	if err == nil {
		t.Fatal("expected pulumi_dir mismatch error")
	}
}

func TestNodesToJSONRoundTrip(t *testing.T) {
	t.Parallel()
	in := []Node{{Role: RoleControlPlane, IP: "2001:db8::1"}}
	raw, err := NodesToJSON(in)
	if err != nil {
		t.Fatal(err)
	}
	out, err := ParseNodesJSON(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].IP != "2001:db8::1" {
		t.Fatalf("round-trip failed: %#v", out)
	}
}

func TestExampleFilesExist(t *testing.T) {
	t.Parallel()
	for _, p := range []string{
		filepath.Join("..", "..", "config", "clusters.yaml"),
		filepath.Join("..", "..", "config", "clusters.bare-metal.example.yaml"),
		filepath.Join("..", "..", "config", "clusters.azure-metal-sim.example.yaml"),
	} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("missing %s: %v", p, err)
		}
	}
}
