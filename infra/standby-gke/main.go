package main

import (
	"fmt"
	"strings"

	"github.com/pulumi/pulumi-gcp/sdk/v8/go/gcp/container"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "standby")
		gcpCfg := config.New(ctx, "gcp")

		project := gcpCfg.Get("project")
		if project == "" {
			return fmt.Errorf("gcp:project is required (pulumi config set gcp:project <id>)")
		}
		location := cfg.Get("location")
		if location == "" {
			location = gcpCfg.Get("region")
		}
		if location == "" {
			location = "us-central1"
		}
		name := cfg.Get("clusterName")
		if name == "" {
			name = "metal-mirage-standby"
		}

		// Autopilot keeps the standby lab small (no node-pool SKU hunting).
		cluster, err := container.NewCluster(ctx, "standby-gke", &container.ClusterArgs{
			Name:               pulumi.String(name),
			Project:            pulumi.String(project),
			Location:           pulumi.String(location),
			EnableAutopilot:    pulumi.Bool(true),
			DeletionProtection: pulumi.Bool(false),
			ReleaseChannel: &container.ClusterReleaseChannelArgs{
				Channel: pulumi.String("REGULAR"),
			},
		})
		if err != nil {
			return err
		}

		kubeconfig := pulumi.All(cluster.Name, cluster.Endpoint, cluster.MasterAuth).ApplyT(
			func(args []any) (string, error) {
				cname, _ := args[0].(string)
				endpoint, _ := args[1].(string)
				var ca string
				switch auth := args[2].(type) {
				case container.ClusterMasterAuth:
					if auth.ClusterCaCertificate != nil {
						ca = *auth.ClusterCaCertificate
					}
				case *container.ClusterMasterAuth:
					if auth != nil && auth.ClusterCaCertificate != nil {
						ca = *auth.ClusterCaCertificate
					}
				}
				return formatGKEKubeconfig(cname, endpoint, ca), nil
			},
		).(pulumi.StringOutput)

		ctx.Export("project", pulumi.String(project))
		ctx.Export("location", pulumi.String(location))
		ctx.Export("gkeName", cluster.Name)
		ctx.Export("clusterEndpoint", cluster.Endpoint.ApplyT(func(ep string) string {
			ep = strings.TrimSpace(ep)
			if ep == "" {
				return ""
			}
			if strings.HasPrefix(ep, "https://") {
				return ep
			}
			return "https://" + ep
		}).(pulumi.StringOutput))
		ctx.Export("kubeconfig", pulumi.ToSecret(kubeconfig))
		ctx.Export("provisioner", pulumi.String("gke"))

		return nil
	})
}

func formatGKEKubeconfig(name, endpoint, caData string) string {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint != "" && !strings.HasPrefix(endpoint, "https://") {
		endpoint = "https://" + endpoint
	}
	// Authenticate with ADC / gcloud (gke-gcloud-auth-plugin).
	return fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: %s
  cluster:
    server: %s
    certificate-authority-data: %s
contexts:
- name: %s
  context:
    cluster: %s
    user: %s
current-context: %s
users:
- name: %s
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      installHint: Install gke-gcloud-auth-plugin for use with kubectl
      provideClusterInfo: true
`, name, endpoint, caData, name, name, name, name, name)
}
