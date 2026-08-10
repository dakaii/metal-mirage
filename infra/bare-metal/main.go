//go:build !syncconfig

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
	taloscluster "github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "baremetal")
		clusterName := cfgGet(cfg, "clusterName", "metal-mirage-primary")
		installDisk := cfgGet(cfg, "installDisk", "/dev/sda")
		talosVersion := cfgGet(cfg, "talosVersion", "v1.9.5")
		dryRun := cfgGetBool(cfg, "dryRun", true)

		nodes, err := ParseNodesJSON(cfg.Require("nodes"))
		if err != nil {
			return err
		}
		firstCP, err := FirstControlPlaneIP(nodes)
		if err != nil {
			return err
		}

		apiEndpointIP := strings.TrimSpace(cfgGet(cfg, "apiEndpointIP", firstCP))
		if apiEndpointIP == "" {
			return fmt.Errorf("baremetal:apiEndpointIP is required")
		}
		ingressIP := strings.TrimSpace(cfgGet(cfg, "ingressIP", apiEndpointIP))
		if ingressIP == "" {
			return fmt.Errorf("baremetal:ingressIP is required")
		}

		clusterEndpoint := formatClusterEndpoint(apiEndpointIP)

		diskPatch, err := json.Marshal(map[string]any{
			"machine": map[string]any{
				"install": map[string]any{
					"disk": installDisk,
				},
			},
		})
		if err != nil {
			return err
		}
		diskPatches := pulumi.StringArray{pulumi.String(string(diskPatch))}

		secrets, err := machine.NewSecrets(ctx, "talos-secrets", &machine.SecretsArgs{
			TalosVersion: pulumi.String(talosVersion),
		})
		if err != nil {
			return err
		}

		var firstNode string
		var bootstrapDeps []pulumi.Resource
		cpIPs := make([]string, 0)
		workerIPs := make([]string, 0)
		machineConfigs := pulumi.StringMap{}

		for i, n := range nodes {
			name := fmt.Sprintf("%s-%d", n.Role, i)
			ip := n.IP
			machineType := string(n.Role)
			if n.Role == RoleControlPlane {
				cpIPs = append(cpIPs, ip)
				if firstNode == "" {
					firstNode = ip
				}
			} else {
				workerIPs = append(workerIPs, ip)
			}

			// Bake install-disk patch into generated configs so dryRun exports match live apply.
			mc := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
				ClusterName:     pulumi.String(clusterName),
				MachineType:     pulumi.String(machineType),
				ClusterEndpoint: pulumi.String(clusterEndpoint),
				MachineSecrets:  secrets.MachineSecrets,
				ConfigPatches:   diskPatches,
				TalosVersion:    pulumi.String(talosVersion),
				Docs:            pulumi.Bool(false),
				Examples:        pulumi.Bool(false),
			})
			machineConfigs[name] = mc.MachineConfiguration()

			if dryRun {
				continue
			}

			apply, err := machine.NewConfigurationApply(ctx, name+"-cfg", &machine.ConfigurationApplyArgs{
				ClientConfiguration:       secrets.ClientConfiguration,
				MachineConfigurationInput: mc.MachineConfiguration(),
				Node:                      pulumi.String(ip),
			})
			if err != nil {
				return err
			}
			if n.Role == RoleControlPlane {
				bootstrapDeps = append(bootstrapDeps, apply)
			}
		}

		if !dryRun {
			bootstrap, err := machine.NewBootstrap(ctx, "bootstrap", &machine.BootstrapArgs{
				Node:                pulumi.String(firstNode),
				ClientConfiguration: secrets.ClientConfiguration,
			}, pulumi.DependsOn(bootstrapDeps))
			if err != nil {
				return err
			}

			// Wait for Bootstrap so kubeconfig fetch is not racing etcd/API bring-up.
			kubeconfig, err := taloscluster.NewKubeconfig(ctx, "kubeconfig", &taloscluster.KubeconfigArgs{
				ClientConfiguration: &taloscluster.KubeconfigClientConfigurationArgs{
					CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
					ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
					ClientKey:         secrets.ClientConfiguration.ClientKey(),
				},
				Node:     pulumi.String(firstNode),
				Endpoint: pulumi.String(apiEndpointIP),
			}, pulumi.DependsOn([]pulumi.Resource{bootstrap}))
			if err != nil {
				return err
			}
			ctx.Export("kubeconfig", pulumi.ToSecret(kubeconfig.KubeconfigRaw))
		} else {
			// Offline / inventory demo: secrets + machine configs are generated in
			// Pulumi state, but no Talos APIs are contacted.
			ctx.Export("kubeconfig", pulumi.ToSecret(pulumi.String("")))
			ctx.Export("dryRunNote", pulumi.String(
				"dryRun=true: machine secrets/configs generated; set baremetal:dryRun false after nodes are in Talos maintenance mode",
			))
		}

		ctx.Export("apiLoadBalancerIP", pulumi.String(apiEndpointIP))
		ctx.Export("ingressIP", pulumi.String(ingressIP))
		ctx.Export("clusterEndpoint", pulumi.String(clusterEndpoint))
		ctx.Export("clusterName", pulumi.String(clusterName))
		ctx.Export("installDisk", pulumi.String(installDisk))
		ctx.Export("talosVersion", pulumi.String(talosVersion))
		ctx.Export("controlPlaneIPs", stringArray(cpIPs))
		ctx.Export("workerIPs", stringArray(workerIPs))
		ctx.Export("machineConfigs", pulumi.ToSecret(machineConfigs))
		ctx.Export("dryRun", pulumi.Bool(dryRun))
		ctx.Export("provisioner", pulumi.String("bare-metal"))

		return nil
	})
}

func stringArray(vals []string) pulumi.StringArray {
	out := make(pulumi.StringArray, len(vals))
	for i, v := range vals {
		out[i] = pulumi.String(v)
	}
	return out
}

// formatClusterEndpoint builds https://host:6443, bracketing IPv6 literals.
func formatClusterEndpoint(apiIP string) string {
	host := apiIP
	if ip := net.ParseIP(apiIP); ip != nil && ip.To4() == nil {
		host = "[" + apiIP + "]"
	}
	return "https://" + host + ":6443"
}

func cfgGet(cfg *config.Config, key, def string) string {
	if v := cfg.Get(key); v != "" {
		return v
	}
	return def
}

func cfgGetBool(cfg *config.Config, key string, def bool) bool {
	if cfg.Get(key) == "" {
		return def
	}
	return cfg.GetBool(key)
}
