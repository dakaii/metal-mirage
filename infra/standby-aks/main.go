package main

import (
	"encoding/base64"
	"fmt"

	"github.com/pulumi/pulumi-azure-native-sdk/authorization/v2"
	containerservice "github.com/pulumi/pulumi-azure-native-sdk/containerservice/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/managedidentity/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/storage/v2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "standby")
		location := cfg.Get("location")
		if location == "" {
			location = "eastus"
		}
		nodeCount := cfg.GetInt("nodeCount")
		if nodeCount == 0 {
			nodeCount = 1
		}
		vmSize := cfg.Get("vmSize")
		if vmSize == "" {
			vmSize = "Standard_B2s"
		}
		k8sVersion := cfg.Get("kubernetesVersion")

		rg, err := resources.NewResourceGroup(ctx, "standby-rg", &resources.ResourceGroupArgs{
			Location: pulumi.String(location),
		})
		if err != nil {
			return err
		}

		identity, err := managedidentity.NewUserAssignedIdentity(ctx, "standby-id", &managedidentity.UserAssignedIdentityArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
		})
		if err != nil {
			return err
		}

		sa, err := storage.NewStorageAccount(ctx, "velerobackups", &storage.StorageAccountArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			Sku: &storage.SkuArgs{
				Name: storage.SkuName_Standard_LRS,
			},
			Kind:                   storage.KindStorageV2,
			AllowBlobPublicAccess:  pulumi.Bool(false),
			EnableHttpsTrafficOnly: pulumi.Bool(true),
			MinimumTlsVersion:      storage.MinimumTlsVersion_TLS1_2,
		})
		if err != nil {
			return err
		}

		container, err := storage.NewBlobContainer(ctx, "velero", &storage.BlobContainerArgs{
			ResourceGroupName: rg.Name,
			AccountName:       sa.Name,
			PublicAccess:      storage.PublicAccessNone,
		})
		if err != nil {
			return err
		}

		clientCfg, err := authorization.GetClientConfig(ctx)
		if err != nil {
			return err
		}

		// Storage Blob Data Contributor
		_, err = authorization.NewRoleAssignment(ctx, "velero-blob-data", &authorization.RoleAssignmentArgs{
			PrincipalId:   identity.PrincipalId,
			PrincipalType: authorization.PrincipalTypeServicePrincipal,
			RoleDefinitionId: pulumi.Sprintf(
				"/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/ba92a5b7-42e9-4cf0-8c5b-2c5c6b8f0c5d",
				clientCfg.SubscriptionId,
			),
			Scope: sa.ID(),
		})
		if err != nil {
			return err
		}

		clusterArgs := &containerservice.ManagedClusterArgs{
			ResourceGroupName: rg.Name,
			Location:          rg.Location,
			DnsPrefix:         pulumi.String("hybrid-standby"),
			Identity: &containerservice.ManagedClusterIdentityArgs{
				Type: containerservice.ResourceIdentityTypeUserAssigned,
				UserAssignedIdentities: pulumi.StringArray{
					identity.ID(),
				},
			},
			AgentPoolProfiles: containerservice.ManagedClusterAgentPoolProfileArray{
				&containerservice.ManagedClusterAgentPoolProfileArgs{
					Name:              pulumi.String("system"),
					Mode:              pulumi.String("System"),
					Count:             pulumi.Int(nodeCount),
					VmSize:            pulumi.String(vmSize),
					OsType:            pulumi.String("Linux"),
					Type:              pulumi.String("VirtualMachineScaleSets"),
					EnableAutoScaling: pulumi.Bool(false),
				},
			},
			NetworkProfile: &containerservice.ContainerServiceNetworkProfileArgs{
				NetworkPlugin:   pulumi.String("azure"),
				NetworkPolicy:   pulumi.String("azure"),
				LoadBalancerSku: pulumi.String("standard"),
			},
			OidcIssuerProfile: &containerservice.ManagedClusterOIDCIssuerProfileArgs{
				Enabled: pulumi.Bool(true),
			},
			SecurityProfile: &containerservice.ManagedClusterSecurityProfileArgs{
				WorkloadIdentity: &containerservice.ManagedClusterSecurityProfileWorkloadIdentityArgs{
					Enabled: pulumi.Bool(true),
				},
			},
		}
		if k8sVersion != "" {
			clusterArgs.KubernetesVersion = pulumi.String(k8sVersion)
		}

		cluster, err := containerservice.NewManagedCluster(ctx, "standby-aks", clusterArgs)
		if err != nil {
			return err
		}

		creds := containerservice.ListManagedClusterUserCredentialsOutput(ctx, containerservice.ListManagedClusterUserCredentialsOutputArgs{
			ResourceGroupName: rg.Name,
			ResourceName:      cluster.Name,
		})

		kubeconfig := creds.Kubeconfigs().Index(pulumi.Int(0)).Value().ApplyT(func(b64 string) (string, error) {
			raw, err := base64.StdEncoding.DecodeString(b64)
			if err != nil {
				return "", fmt.Errorf("decode kubeconfig: %w", err)
			}
			return string(raw), nil
		}).(pulumi.StringOutput)

		ctx.Export("resourceGroupName", rg.Name)
		ctx.Export("aksName", cluster.Name)
		ctx.Export("aksFqdn", cluster.Fqdn)
		ctx.Export("kubeconfig", pulumi.ToSecret(kubeconfig))
		ctx.Export("veleroStorageAccount", sa.Name)
		ctx.Export("veleroContainer", container.Name)
		ctx.Export("veleroIdentityClientId", identity.ClientId)
		ctx.Export("provisioner", pulumi.String("aks"))

		return nil
	})
}
