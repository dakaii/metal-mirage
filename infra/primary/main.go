package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/pulumi/pulumi-azure-native-sdk/compute/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/network/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
	taloscluster "github.com/pulumiverse/pulumi-talos/sdk/go/talos/cluster"
	"github.com/pulumiverse/pulumi-talos/sdk/go/talos/machine"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "primary")
		location := cfgGet(cfg, "location", "eastus")
		talosImageID := cfg.Require("talosImageId")
		clusterName := cfgGet(cfg, "clusterName", "azure-hybrid-primary")
		cpCount := cfgGetInt(cfg, "controlPlaneCount", 1)
		workerCount := cfgGetInt(cfg, "workerCount", 1)
		vmSize := cfgGet(cfg, "vmSize", "Standard_B2s")

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
				tcpAllow("allow-talos-apid", 1001, "50000"),
				tcpAllow("allow-talos-trustd", 1002, "50001"),
				tcpAllow("allow-etcd", 1003, "2379-2380"),
				tcpAllow("allow-k8s-api", 1004, "6443"),
				tcpAllow("allow-https", 1005, "443"),
				tcpAllow("allow-http", 1006, "80"),
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
					"disk": "/dev/sda",
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
					},
				},
			})
			if err != nil {
				return err
			}

			cpCfg := machine.GetConfigurationOutput(ctx, machine.GetConfigurationOutputArgs{
				ClusterName:       pulumi.String(clusterName),
				MachineType:       pulumi.String("controlplane"),
				ClusterEndpoint:   clusterEndpoint,
				MachineSecrets:    secrets.MachineSecrets,
				Docs:              pulumi.Bool(false),
				Examples:          pulumi.Bool(false),
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
					},
				},
			})
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
		ctx.Export("controlPlanePublicIPs", pulumi.StringArray(cpIPsToArray(cpIPs)))
		ctx.Export("clusterEndpoint", clusterEndpoint)
		ctx.Export("kubeconfig", pulumi.ToSecret(kubeconfig.KubeconfigRaw))
		ctx.Export("provisioner", pulumi.String("azure-metal-sim"))

		return nil
	})
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
			AdminPassword: pulumi.String("NotUsedByTalos123!"),
			CustomData:    customData,
			LinuxConfiguration: &compute.LinuxConfigurationArgs{
				DisablePasswordAuthentication: pulumi.Bool(false),
			},
		},
	})
}

func tcpAllow(name string, priority int, port string) *network.SecurityRuleTypeArgs {
	return &network.SecurityRuleTypeArgs{
		Name:                     pulumi.String(name),
		Priority:                 pulumi.Int(priority),
		Direction:                network.SecurityRuleDirectionInbound,
		Access:                   network.SecurityRuleAccessAllow,
		Protocol:                 network.SecurityRuleProtocolTcp,
		SourceAddressPrefix:      pulumi.String("*"),
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
