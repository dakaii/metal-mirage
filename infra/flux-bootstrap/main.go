package main

import (
	"github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes"
	helmv3 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/helm/v3"
	corev1 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/core/v1"
	metav1 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/meta/v1"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "flux")
		kubeconfig := cfg.RequireSecret("kubeconfig")
		repoURL := cfg.Get("repoUrl")
		if repoURL == "" {
			repoURL = "https://github.com/dakaii/metal-mirage"
		}
		branch := cfg.Get("branch")
		if branch == "" {
			branch = "main"
		}
		clusterPath := cfg.Get("clusterPath")
		if clusterPath == "" {
			clusterPath = "./gitops/clusters/primary"
		}

		provider, err := kubernetes.NewProvider(ctx, "k8s", &kubernetes.ProviderArgs{
			Kubeconfig: kubeconfig,
		})
		if err != nil {
			return err
		}

		ns, err := corev1.NewNamespace(ctx, "flux-system", &corev1.NamespaceArgs{
			Metadata: &metav1.ObjectMetaArgs{
				Name: pulumi.String("flux-system"),
			},
		}, pulumi.Provider(provider))
		if err != nil {
			return err
		}

		// Official Flux install chart (controllers). GitRepository/Kustomization
		// are applied from gitops/ after install, or via scripts/install-flux.sh.
		flux, err := helmv3.NewRelease(ctx, "flux", &helmv3.ReleaseArgs{
			Chart:     pulumi.String("flux2"),
			Version:   pulumi.String("2.14.1"),
			Namespace: ns.Metadata.Name(),
			RepositoryOpts: &helmv3.RepositoryOptsArgs{
				Repo: pulumi.String("https://fluxcd-community.github.io/helm-charts"),
			},
			Values: pulumi.Map{
				"installCRDs": pulumi.Bool(true),
			},
		}, pulumi.Provider(provider), pulumi.DependsOn([]pulumi.Resource{ns}))
		if err != nil {
			return err
		}

		ctx.Export("fluxRelease", flux.Name)
		ctx.Export("repoUrl", pulumi.String(repoURL))
		ctx.Export("branch", pulumi.String(branch))
		ctx.Export("clusterPath", pulumi.String(clusterPath))
		ctx.Export("nextStep", pulumi.String("Run scripts/install-flux.sh to create GitRepository + root Kustomization, or apply gitops/clusters/<name> manually"))

		return nil
	})
}
