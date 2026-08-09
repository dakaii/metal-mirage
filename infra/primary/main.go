package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/pulumi/pulumi-azure-native-sdk/authorization/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/compute/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/network/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
	taloscluster "github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

const (
	ingressLBName       = "ingress-lb"
	ingressFrontendName = "ingress-frontend"
	ingressBackendName  = "ingress-backend"
	ingressProbeName    = "demo-http"
	demoNodePort        = 30080
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "primary")
		location := cfgGet(cfg, "location", "eastus")
		talosImageID := cfg.Require("talosImageId")
		clusterName := cfgGet(cfg, "clusterName", "metal-mirage-primary")
		cpCount := cfgGetInt(cfg, "controlPlaneCount", 1)
		workerCount := cfgGetInt(cfg, "workerCount", 1)
		vmSize := cfgGet(cfg, "vmSize", "Standard_B2s")
		// Azure Gen2 Talos VHD typically presents the OS disk as /dev/sda.
		installDisk := cfgGet(cfg, "installDisk", "/dev/sda")
		// Lock Talos/k8s API planes; leave HTTP/demo open for Traffic Manager probes.
		adminCIDR := cfgGet(cfg, "adminCidr", "0.0.0.0/0")

		clientCfg, err := authorization.GetClientConfig(ctx)
		if err != nil {
			return err
		}

		rg, err := resources.NewResourceGroup(ctx, "primary-rg", &resources.ResourceGroupArgs{
			Location: pulumi.String(location),
		})
		if err != nil {
			return err
		}

		vnet, err := network.NewVirtualNetwork(ctx, "primary-vnet", &network.VirtualNetworkArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			AddressSpace: &network.AddressSpaceArgs{
				AddressPrefixes: pulumi.StringArray{pulumi.String("10.10.0.0/16")},
			},
		})
		if err != nil {
			return err
		}

		subnet, err := network.NewSubnet(ctx, "primary-subnet", &network.SubnetArgs{
			ResourceGroupName:  rg.Name,
			VirtualNetworkName: vnet.Name,
			AddressPrefix:      pulumi.String("10.10.1.0/24"),
		})
		if err != nil {
			return err
		}

		nsg, err := network.NewNetworkSecurityGroup(ctx, "primary-nsg", &network.NetworkSecurityGroupArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			SecurityRules: network.SecurityRuleTypeArray{
				tcpAllow("allow-talos-apid", 1001, "50000", adminCIDR),
				tcpAllow("allow-talos-trustd", 1002, "50001", adminCIDR),
				tcpAllow("allow-etcd", 1003, "2379-2380", adminCIDR),
				// 6443 stays open so the shared witness Function can probe /readyz
				// (Azure Functions egress is not your adminCidr). Lock further if unused.
				tcpAllow("allow-k8s-api", 1004, "6443", "*"),
				tcpAllow("allow-https", 1005, "443", "*"),
				tcpAllow("allow-http", 1006, "80", "*"),
				tcpAllow("allow-demo-nodeport", 1007, fmt.Sprintf("%d", demoNodePort), "*"),
			},
		})
		if err != nil {
			return err
		}

		// Single static public IP used as the Kubernetes API endpoint.
		// For 1-node demos this is attached to the first control plane NIC.
		apiPip, err := network.NewPublicIPAddress(ctx, "api-pip", &network.PublicIPAddressArgs{
			ResourceGroupName:        rg.Name,
			Location:                 rg.Location,
			PublicIPAllocationMethod: network.IPAllocationMethodStatic,
			Sku: &network.PublicIPAddressSkuArgs{
				Name: network.PublicIPAddressSkuNameStandard,
			},
		})
		if err != nil {
			return err
		}

		ingressPip, err := network.NewPublicIPAddress(ctx, "ingress-pip", &network.PublicIPAddressArgs{
			ResourceGroupName:        rg.Name,
			Location:                 rg.Location,
			PublicIPAllocationMethod: network.IPAllocationMethodStatic,
			Sku: &network.PublicIPAddressSkuArgs{
				Name: network.PublicIPAddressSkuNameStandard,
			},
		})
		if err != nil {
			return err
		}

		frontendID := lbChildID(clientCfg.SubscriptionId, rg.Name, ingressLBName, "frontendIPConfigurations", ingressFrontendName)
		backendID := lbChildID(clientCfg.SubscriptionId, rg.Name, ingressLBName, "backendAddressPools", ingressBackendName)
		probeID := lbChildID(clientCfg.SubscriptionId, rg.Name, ingressLBName, "probes", ingressProbeName)

		// Azure LB fronts demo NodePort 30080 (no cloud-controller required on Talos metal-sim).
		ingressLB, err := network.NewLoadBalancer(ctx, "ingress-lb", &network.LoadBalancerArgs{
			LoadBalancerName:  pulumi.String(ingressLBName),
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			Sku: &network.LoadBalancerSkuArgs{
				Name: network.LoadBalancerSkuNameStandard,
			},
			FrontendIPConfigurations: network.FrontendIPConfigurationArray{
				&network.FrontendIPConfigurationArgs{
					Name:            pulumi.String(ingressFrontendName),
					PublicIPAddress: &network.PublicIPAddressTypeArgs{Id: ingressPip.ID()},
				},
			},
			BackendAddressPools: network.BackendAddressPoolArray{
				&network.BackendAddressPoolArgs{Name: pulumi.String(ingressBackendName)},
			},
			Probes: network.ProbeArray{
				&network.ProbeArgs{
					Name:              pulumi.String(ingressProbeName),
					Protocol:          network.ProbeProtocolHttp,
					Port:              pulumi.Int(demoNodePort),
					RequestPath:       pulumi.String("/healthz"),
					IntervalInSeconds: pulumi.Int(10),
					NumberOfProbes:    pulumi.Int(2),
				},
			},
			LoadBalancingRules: network.LoadBalancingRuleArray{
				&network.LoadBalancingRuleArgs{
					Name:                    pulumi.String("http"),
					Protocol:                network.TransportProtocolTcp,
					FrontendIPConfiguration: &network.SubResourceArgs{Id: frontendID},
					FrontendPort:            pulumi.Int(80),
					BackendPort:             pulumi.Int(demoNodePort),
					EnableFloatingIP:        pulumi.Bool(false),
					IdleTimeoutInMinutes:    pulumi.Int(4),
					LoadDistribution:        network.LoadDistributionDefault,
					Probe:                   &network.SubResourceArgs{Id: probeID},
					BackendAddressPool:      &network.SubResourceArgs{Id: backendID},
					DisableOutboundSnat:     pulumi.Bool(false), // SNAT for workers without public IPs
				},
			},
		})
		if err != nil {
			return err
		}

		secrets, err := machine.NewSecrets(ctx, "talos-secrets", nil)
		if err != nil {
			return err
		}

		clusterEndpoint := apiPip.IpAddress.Elem().ApplyT(func(ip string) string {
			return fmt.Sprintf("https://%s:6443", ip)
		}).(pulumi.StringOutput)

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

		var firstNode pulumi.StringOutput
		var bootstrapDeps []pulumi.Resource
		cpIPs := make([]pulumi.StringInput, 0, cpCount)

		for i := 0; i < cpCount; i++ {
			name := fmt.Sprintf("cp-%d", i)

			var publicIPID pulumi.IDOutput
			var nodeAddr pulumi.StringOutput

			if i == 0 {
				publicIPID = apiPip.ID()
				nodeAddr = apiPip.IpAddress.Elem()
			} else {
				pip, err := network.NewPublicIPAddress(ctx, name+"-pip", &network.PublicIPAddressArgs{
					ResourceGroupName:        rg.Name,
					Location:                 rg.Location,
					PublicIPAllocationMethod: network.IPAllocationMethodStatic,
					Sku: &network.PublicIPAddressSkuArgs{
						Name: network.PublicIPAddressSkuNameStandard,
					},
				})
				if err != nil {
					return err
				}
				publicIPID = pip.ID()
				nodeAddr = pip.IpAddress.Elem()
			}
			cpIPs = append(cpIPs, nodeAddr)

			nic, err := network.NewNetworkInterface(ctx, name+"-nic", &network.NetworkInterfaceArgs{
				ResourceGroupName: rg.Name,
				Location:          rg.Location,
				NetworkSecurityGroup: &network.NetworkSecurityGroupTypeArgs{
					Id: nsg.ID(),
				},
				IpConfigurations: network.NetworkInterfaceIPConfigurationArray{
					&network.NetworkInterfaceIPConfigurationArgs{
						Name:                      pulumi.String("ipconfig"),
						Subnet:                    &network.SubnetTypeArgs{Id: subnet.ID()},
						PrivateIPAllocationMethod: network.IPAllocationMethodDynamic,
						PublicIPAddress:           &network.PublicIPAddressTypeArgs{Id: publicIPID},
						LoadBalancerBackendAddressPools: network.BackendAddressPoolArray{
							&network.BackendAddressPoolArgs{Id: backendID},
						},
					},
				},
			}, pulumi.DependsOn([]pulumi.Resource{ingressLB}))
			if err != nil {
				return err
			}

			cpCfg := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
				ClusterName:     pulumi.String(clusterName),
				MachineType:     pulumi.String("controlplane"),
				ClusterEndpoint: clusterEndpoint,
				MachineSecrets:  secrets.MachineSecrets,
				Docs:            pulumi.Bool(false),
				Examples:        pulumi.Bool(false),
			})

			vm, err := newTalosVM(ctx, name, rg, nic, talosImageID, vmSize, 30, cpCfg.MachineConfiguration())
			if err != nil {
				return err
			}

			apply, err := machine.NewConfigurationApply(ctx, name+"-cfg", &machine.ConfigurationApplyArgs{
				ClientConfiguration:       secrets.ClientConfiguration,
				MachineConfigurationInput: cpCfg.MachineConfiguration(),
				Node:                      nodeAddr,
				ConfigPatches:             pulumi.StringArray{pulumi.String(string(diskPatch))},
			}, pulumi.DependsOn([]pulumi.Resource{vm}))
			if err != nil {
				return err
			}
			bootstrapDeps = append(bootstrapDeps, apply)

			if i == 0 {
				firstNode = nodeAddr
			}
		}

		_, err = machine.NewBootstrap(ctx, "bootstrap", &machine.BootstrapArgs{
			Node:                firstNode,
			ClientConfiguration: secrets.ClientConfiguration,
		}, pulumi.DependsOn(bootstrapDeps))
		if err != nil {
			return err
		}

		for i := 0; i < workerCount; i++ {
			name := fmt.Sprintf("worker-%d", i)

			nic, err := network.NewNetworkInterface(ctx, name+"-nic", &network.NetworkInterfaceArgs{
				ResourceGroupName: rg.Name,
				Location:          rg.Location,
				NetworkSecurityGroup: &network.NetworkSecurityGroupTypeArgs{
					Id: nsg.ID(),
				},
				IpConfigurations: network.NetworkInterfaceIPConfigurationArray{
					&network.NetworkInterfaceIPConfigurationArgs{
						Name:                      pulumi.String("ipconfig"),
						Subnet:                    &network.SubnetTypeArgs{Id: subnet.ID()},
						PrivateIPAllocationMethod: network.IPAllocationMethodDynamic,
						LoadBalancerBackendAddressPools: network.BackendAddressPoolArray{
							&network.BackendAddressPoolArgs{Id: backendID},
						},
					},
				},
			}, pulumi.DependsOn([]pulumi.Resource{ingressLB}))
			if err != nil {
				return err
			}

			wCfg := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
				ClusterName:     pulumi.String(clusterName),
				MachineType:     pulumi.String("worker"),
				ClusterEndpoint: clusterEndpoint,
				MachineSecrets:  secrets.MachineSecrets,
				Docs:            pulumi.Bool(false),
				Examples:        pulumi.Bool(false),
			})

			vm, err := newTalosVM(ctx, name, rg, nic, talosImageID, vmSize, 40, wCfg.MachineConfiguration())
			if err != nil {
				return err
			}

			privateIP := nic.IpConfigurations.ApplyT(func(cfgs []network.NetworkInterfaceIPConfigurationResponse) (string, error) {
				if len(cfgs) == 0 || cfgs[0].PrivateIPAddress == nil {
					return "", fmt.Errorf("worker nic has no private IP yet")
				}
				return *cfgs[0].PrivateIPAddress, nil
			}).(pulumi.StringOutput)

			_, err = machine.NewConfigurationApply(ctx, name+"-cfg", &machine.ConfigurationApplyArgs{
				ClientConfiguration:       secrets.ClientConfiguration,
				MachineConfigurationInput: wCfg.MachineConfiguration(),
				Node:                      privateIP,
				ConfigPatches:             pulumi.StringArray{pulumi.String(string(diskPatch))},
			}, pulumi.DependsOn([]pulumi.Resource{vm}))
			if err != nil {
				return err
			}
		}

		kubeconfig, err := taloscluster.NewKubeconfig(ctx, "kubeconfig", &taloscluster.KubeconfigArgs{
			ClientConfiguration: &taloscluster.KubeconfigClientConfigurationArgs{
				CaCertificate:     secrets.ClientConfiguration.CaCertificate(),
				ClientCertificate: secrets.ClientConfiguration.ClientCertificate(),
				ClientKey:         secrets.ClientConfiguration.ClientKey(),
			},
			Node:     firstNode,
			Endpoint: firstNode,
		}, pulumi.DependsOn(bootstrapDeps))
		if err != nil {
			return err
		}

		ctx.Export("resourceGroupName", rg.Name)
		ctx.Export("apiLoadBalancerIP", apiPip.IpAddress)
		ctx.Export("ingressIP", ingressPip.IpAddress)
		ctx.Export("ingressLoadBalancer", ingressLB.Name)
		ctx.Export("demoNodePort", pulumi.Int(demoNodePort))
		ctx.Export("installDisk", pulumi.String(installDisk))
		ctx.Export("controlPlanePublicIPs", pulumi.StringArray(cpIPsToArray(cpIPs)))
		ctx.Export("clusterEndpoint", clusterEndpoint)
		ctx.Export("kubeconfig", pulumi.ToSecret(kubeconfig.KubeconfigRaw))
		ctx.Export("provisioner", pulumi.String("azure-metal-sim"))

		return nil
	})
}

func lbChildID(subscriptionID string, rgName pulumi.StringOutput, lbName, collection, child string) pulumi.StringOutput {
	return rgName.ApplyT(func(name string) string {
		return fmt.Sprintf(
			"/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/loadBalancers/%s/%s/%s",
			subscriptionID, name, lbName, collection, child,
		)
	}).(pulumi.StringOutput)
}

func newTalosVM(
	ctx *pulumi.Context,
	name string,
	rg *resources.ResourceGroup,
	nic *network.NetworkInterface,
	imageID, vmSize string,
	diskGB int,
	machineConfig pulumi.StringOutput,
) (*compute.VirtualMachine, error) {
	customData := machineConfig.ApplyT(func(mc string) string {
		return base64.StdEncoding.EncodeToString([]byte(mc))
	}).(pulumi.StringOutput)

	return compute.NewVirtualMachine(ctx, name, &compute.VirtualMachineArgs{
		ResourceGroupName: rg.Name,
		Location:          rg.Location,
		HardwareProfile: &compute.HardwareProfileArgs{
			VmSize: pulumi.String(vmSize),
		},
		NetworkProfile: &compute.NetworkProfileArgs{
			NetworkInterfaces: compute.NetworkInterfaceReferenceArray{
				&compute.NetworkInterfaceReferenceArgs{
					Id:      nic.ID(),
					Primary: pulumi.Bool(true),
				},
			},
		},
		StorageProfile: &compute.StorageProfileArgs{
			ImageReference: &compute.ImageReferenceArgs{
				Id: pulumi.String(imageID),
			},
			OsDisk: &compute.OSDiskArgs{
				Name:         pulumi.Sprintf("%s-os", name),
				Caching:      compute.CachingTypesReadWrite,
				CreateOption: compute.DiskCreateOptionTypesFromImage,
				ManagedDisk: &compute.ManagedDiskParametersArgs{
					StorageAccountType: compute.StorageAccountTypes_Standard_LRS,
				},
				DiskSizeGB: pulumi.Int(diskGB),
			},
		},
		OsProfile: &compute.OSProfileArgs{
			ComputerName:  pulumi.String(name),
			AdminUsername: pulumi.String("talos"),
			// Azure requires AdminPassword on Linux VMs; Talos ignores it (API-only OS).
			AdminPassword: pulumi.String("NotUsedByTalos123!"),
			CustomData:    customData,
			LinuxConfiguration: &compute.LinuxConfigurationArgs{
				DisablePasswordAuthentication: pulumi.Bool(false),
			},
		},
	})
}

func tcpAllow(name string, priority int, port, sourceCIDR string) *network.SecurityRuleTypeArgs {
	return &network.SecurityRuleTypeArgs{
		Name:                     pulumi.String(name),
		Priority:                 pulumi.Int(priority),
		Direction:                network.SecurityRuleDirectionInbound,
		Access:                   network.SecurityRuleAccessAllow,
		Protocol:                 network.SecurityRuleProtocolTcp,
		SourceAddressPrefix:      pulumi.String(sourceCIDR),
		SourcePortRange:          pulumi.String("*"),
		DestinationAddressPrefix: pulumi.String("*"),
		DestinationPortRange:     pulumi.String(port),
	}
}

func cfgGet(cfg *config.Config, key, def string) string {
	if v := cfg.Get(key); v != "" {
		return v
	}
	return def
}

func cfgGetInt(cfg *config.Config, key string, def int) int {
	if cfg.Get(key) == "" {
		return def
	}
	return cfg.GetInt(key)
}

func cpIPsToArray(ips []pulumi.StringInput) pulumi.StringArray {
	out := make(pulumi.StringArray, len(ips))
	for i, ip := range ips {
		out[i] = ip
	}
	return out
}
