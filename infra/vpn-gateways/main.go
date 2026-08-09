package main

import (
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-azure-native-sdk/compute/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/network/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "vpn")
		location := cfg.Get("location")
		if location == "" {
			location = "eastus"
		}
		city := cfg.Get("city")
		if city == "" {
			city = "us"
		}
		vmSize := cfg.Get("vmSize")
		if vmSize == "" {
			vmSize = "Standard_B1s"
		}
		adminCIDR := cfg.Get("adminCidr")
		if adminCIDR == "" {
			adminCIDR = "0.0.0.0/0"
		}
		sshPublicKey := cfg.Require("sshPublicKey")

		rg, err := resources.NewResourceGroup(ctx, "vpn-rg", &resources.ResourceGroupArgs{
			Location: pulumi.String(location),
			Tags: pulumi.StringMap{
				"role": pulumi.String("vpn-gateway"),
				"city": pulumi.String(city),
			},
		})
		if err != nil {
			return err
		}

		vnet, err := network.NewVirtualNetwork(ctx, "vpn-vnet", &network.VirtualNetworkArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			AddressSpace: &network.AddressSpaceArgs{
				AddressPrefixes: pulumi.StringArray{pulumi.String("10.66.0.0/16")},
			},
		})
		if err != nil {
			return err
		}

		subnet, err := network.NewSubnet(ctx, "vpn-subnet", &network.SubnetArgs{
			ResourceGroupName:  rg.Name,
			VirtualNetworkName: vnet.Name,
			AddressPrefix:      pulumi.String("10.66.1.0/24"),
		})
		if err != nil {
			return err
		}

		// WireGuard peers connect from anywhere; lock SSH/metrics to adminCidr.
		nsg, err := network.NewNetworkSecurityGroup(ctx, "vpn-nsg", &network.NetworkSecurityGroupArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			SecurityRules: network.SecurityRuleTypeArray{
				&network.SecurityRuleTypeArgs{
					Name:                     pulumi.String("allow-wireguard"),
					Priority:                 pulumi.Int(1001),
					Direction:                network.SecurityRuleDirectionInbound,
					Access:                   network.SecurityRuleAccessAllow,
					Protocol:                 network.SecurityRuleProtocolUdp,
					SourceAddressPrefix:      pulumi.String("*"),
					SourcePortRange:          pulumi.String("*"),
					DestinationAddressPrefix: pulumi.String("*"),
					DestinationPortRange:     pulumi.String("51820"),
				},
				&network.SecurityRuleTypeArgs{
					Name:                     pulumi.String("allow-ssh"),
					Priority:                 pulumi.Int(1002),
					Direction:                network.SecurityRuleDirectionInbound,
					Access:                   network.SecurityRuleAccessAllow,
					Protocol:                 network.SecurityRuleProtocolTcp,
					SourceAddressPrefix:      pulumi.String(adminCIDR),
					SourcePortRange:          pulumi.String("*"),
					DestinationAddressPrefix: pulumi.String("*"),
					DestinationPortRange:     pulumi.String("22"),
				},
				&network.SecurityRuleTypeArgs{
					Name:                     pulumi.String("allow-node-exporter"),
					Priority:                 pulumi.Int(1003),
					Direction:                network.SecurityRuleDirectionInbound,
					Access:                   network.SecurityRuleAccessAllow,
					Protocol:                 network.SecurityRuleProtocolTcp,
					SourceAddressPrefix:      pulumi.String(adminCIDR),
					SourcePortRange:          pulumi.String("*"),
					DestinationAddressPrefix: pulumi.String("*"),
					DestinationPortRange:     pulumi.String("9100"),
				},
			},
		})
		if err != nil {
			return err
		}

		pip, err := network.NewPublicIPAddress(ctx, "vpn-pip", &network.PublicIPAddressArgs{
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

		nic, err := network.NewNetworkInterface(ctx, "vpn-nic", &network.NetworkInterfaceArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			EnableIPForwarding: pulumi.Bool(true),
			NetworkSecurityGroup: &network.NetworkSecurityGroupTypeArgs{
				Id: nsg.ID(),
			},
			IpConfigurations: network.NetworkInterfaceIPConfigurationArray{
				&network.NetworkInterfaceIPConfigurationArgs{
					Name:                      pulumi.String("ipconfig"),
					Subnet:                    &network.SubnetTypeArgs{Id: subnet.ID()},
					PrivateIPAllocationMethod: network.IPAllocationMethodDynamic,
					PublicIPAddress:           &network.PublicIPAddressTypeArgs{Id: pip.ID()},
				},
			},
		})
		if err != nil {
			return err
		}

		cloudInit := cloudInitScript(city)
		customData := pulumi.String(base64.StdEncoding.EncodeToString([]byte(cloudInit)))

		vm, err := compute.NewVirtualMachine(ctx, fmt.Sprintf("vpn-%s", city), &compute.VirtualMachineArgs{
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
					Publisher: pulumi.String("Canonical"),
					Offer:     pulumi.String("0001-com-ubuntu-server-jammy"),
					Sku:       pulumi.String("22_04-lts-gen2"),
					Version:   pulumi.String("latest"),
				},
				OsDisk: &compute.OSDiskArgs{
					Name:         pulumi.Sprintf("vpn-%s-os", city),
					Caching:      compute.CachingTypesReadWrite,
					CreateOption: compute.DiskCreateOptionTypesFromImage,
					ManagedDisk: &compute.ManagedDiskParametersArgs{
						StorageAccountType: compute.StorageAccountTypes_Standard_LRS,
					},
					DiskSizeGB: pulumi.Int(30),
				},
			},
			OsProfile: &compute.OSProfileArgs{
				ComputerName:  pulumi.Sprintf("vpn-%s", city),
				AdminUsername: pulumi.String("azureuser"),
				CustomData:    customData,
				LinuxConfiguration: &compute.LinuxConfigurationArgs{
					DisablePasswordAuthentication: pulumi.Bool(true),
					Ssh: &compute.SshConfigurationArgs{
						PublicKeys: compute.SshPublicKeyTypeArray{
							&compute.SshPublicKeyTypeArgs{
								Path:    pulumi.String("/home/azureuser/.ssh/authorized_keys"),
								KeyData: pulumi.String(sshPublicKey),
							},
						},
					},
				},
			},
			Tags: pulumi.StringMap{
				"role": pulumi.String("vpn-gateway"),
				"city": pulumi.String(city),
			},
		})
		if err != nil {
			return err
		}

		ctx.Export("resourceGroupName", rg.Name)
		ctx.Export("city", pulumi.String(city))
		ctx.Export("publicIP", pip.IpAddress)
		ctx.Export("vmName", vm.Name)
		ctx.Export("wireguardPort", pulumi.Int(51820))
		ctx.Export("metricsPort", pulumi.Int(9100))
		ctx.Export("sshUser", pulumi.String("azureuser"))
		ctx.Export("cloudInitNote", pulumi.String("WireGuard installed via cloud-init; run scripts/vpn-bootstrap.sh to mint peer configs"))

		return nil
	})
}

func cloudInitScript(city string) string {
	// Keep Ansible out: cloud-init only. Idempotent key + interface setup.
	lines := []string{
		"#cloud-config",
		"package_update: true",
		"packages:",
		"  - wireguard",
		"  - wireguard-tools",
		"  - iptables",
		"  - prometheus-node-exporter",
		"write_files:",
		"  - path: /etc/sysctl.d/99-wireguard.conf",
		"    content: |",
		"      net.ipv4.ip_forward=1",
		"      net.ipv6.conf.all.forwarding=1",
		"  - path: /usr/local/bin/wg-bootstrap.sh",
		"    permissions: '0755'",
		"    content: |",
		"      #!/bin/bash",
		"      set -euo pipefail",
		"      CITY=" + city,
		"      mkdir -p /etc/wireguard /var/lib/wireguard",
		"      umask 077",
		"      if [[ ! -f /etc/wireguard/server.key ]]; then",
		"        wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub",
		"      fi",
		"      chmod 600 /etc/wireguard/server.key",
		"      PRIV=$(cat /etc/wireguard/server.key)",
		"      # Azure Ubuntu usually eth0; fall back to default-route iface.",
		"      IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')",
		"      IFACE=${IFACE:-eth0}",
		"      # Rewrite interface block only; preserve [Peer] sections added by vpn-bootstrap.",
		"      if [[ -f /etc/wireguard/wg0.conf ]]; then",
		"        awk 'BEGIN{p=0} /^\\[Peer\\]/{p=1} p{print}' /etc/wireguard/wg0.conf > /etc/wireguard/wg0.peers || true",
		"      else",
		"        : > /etc/wireguard/wg0.peers",
		"      fi",
		"      cat > /etc/wireguard/wg0.conf <<EOF",
		"      [Interface]",
		"      Address = 10.66.0.1/24",
		"      ListenPort = 51820",
		"      PrivateKey = ${PRIV}",
		"      PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE",
		"      PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE",
		"      EOF",
		"      sed -i 's/^[[:space:]]*//' /etc/wireguard/wg0.conf",
		"      if [[ -s /etc/wireguard/wg0.peers ]]; then",
		"        printf '\\n' >> /etc/wireguard/wg0.conf",
		"        cat /etc/wireguard/wg0.peers >> /etc/wireguard/wg0.conf",
		"      fi",
		"      rm -f /etc/wireguard/wg0.peers",
		"      systemctl enable prometheus-node-exporter",
		"      systemctl restart prometheus-node-exporter || systemctl start prometheus-node-exporter",
		"      systemctl enable wg-quick@wg0",
		"      systemctl restart wg-quick@wg0 || systemctl start wg-quick@wg0",
		"runcmd:",
		"  - sysctl --system",
		"  - /usr/local/bin/wg-bootstrap.sh",
	}
	return strings.Join(lines, "\n") + "\n"
}
