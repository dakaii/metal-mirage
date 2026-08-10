package main

import (
	"strings"

	"github.com/pulumi/pulumi-azure-native-sdk/network/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v2"
	"github.com/pulumi/pulumi-azure-native-sdk/storage/v2"
	web "github.com/pulumi/pulumi-azure-native-sdk/web/v2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "shared")
		location := cfg.Get("location")
		if location == "" {
			location = "eastus"
		}
		primaryIP := cfg.Require("primaryIngressIP")
		standbyFQDN := cfg.Get("standbyFQDN")
		appDomain := cfg.Get("appDomain")
		enableWitness := cfgGetBool(cfg, "enableWitness", true)

		rg, err := resources.NewResourceGroup(ctx, "shared-rg", &resources.ResourceGroupArgs{
			Location: pulumi.String(location),
		})
		if err != nil {
			return err
		}

		// Stable Azure names so ./scripts/failover-promote.sh can toggle endpoints without guessing.
		const tmProfileName = "metal-mirage-app"
		const tmPrimaryEndpoint = "primary"
		const tmStandbyEndpoint = "standby"

		profile, err := network.NewProfile(ctx, "app-failover", &network.ProfileArgs{
			Name:                        pulumi.String(tmProfileName),
			ResourceGroupName:           rg.Name,
			TrafficRoutingMethod:        network.TrafficRoutingMethodPriority,
			TrafficViewEnrollmentStatus: network.TrafficViewEnrollmentStatusDisabled,
			DnsConfig: &network.DnsConfigArgs{
				RelativeName: pulumi.String(tmProfileName),
				Ttl:          pulumi.Float64(30),
			},
			// HTTP:80 matches metal-sim Azure LB → demo NodePort (no TLS required for portfolio DR).
			MonitorConfig: &network.MonitorConfigArgs{
				Protocol:                  network.MonitorProtocolHTTP,
				Port:                      pulumi.Float64(80),
				Path:                      pulumi.String("/healthz"),
				IntervalInSeconds:         pulumi.Float64(30),
				TimeoutInSeconds:          pulumi.Float64(10),
				ToleratedNumberOfFailures: pulumi.Float64(3),
			},
		})
		if err != nil {
			return err
		}

		_, err = network.NewEndpoint(ctx, "primary-endpoint", &network.EndpointArgs{
			Name:              pulumi.String(tmPrimaryEndpoint),
			ResourceGroupName: rg.Name,
			ProfileName:       profile.Name.Elem(),
			EndpointType:      pulumi.String("ExternalEndpoints"),
			EndpointStatus:    network.EndpointStatusEnabled,
			Priority:          pulumi.Float64(1),
			Target:            pulumi.String(primaryIP),
		})
		if err != nil {
			return err
		}

		if standbyFQDN != "" {
			_, err = network.NewEndpoint(ctx, "standby-endpoint", &network.EndpointArgs{
				Name:              pulumi.String(tmStandbyEndpoint),
				ResourceGroupName: rg.Name,
				ProfileName:       profile.Name.Elem(),
				EndpointType:      pulumi.String("ExternalEndpoints"),
				EndpointStatus:    network.EndpointStatusEnabled,
				Priority:          pulumi.Float64(2),
				Target:            pulumi.String(standbyFQDN),
			})
			if err != nil {
				return err
			}
		}

		ctx.Export("trafficManagerFQDN", profile.DnsConfig.ApplyT(func(d *network.DnsConfigResponse) string {
			if d == nil || d.RelativeName == nil {
				return ""
			}
			return *d.RelativeName + ".trafficmanager.net"
		}).(pulumi.StringOutput))
		ctx.Export("trafficManagerProfileName", pulumi.String(tmProfileName))
		ctx.Export("trafficManagerPrimaryEndpoint", pulumi.String(tmPrimaryEndpoint))
		ctx.Export("trafficManagerStandbyEndpoint", pulumi.String(tmStandbyEndpoint))
		ctx.Export("appDomainHint", pulumi.String(appDomain))
		ctx.Export("resourceGroupName", rg.Name)

		if enableWitness {
			if err := deployWitness(ctx, rg, cfg); err != nil {
				return err
			}
		}

		return nil
	})
}

func deployWitness(ctx *pulumi.Context, rg *resources.ResourceGroup, cfg *config.Config) error {
	primaryAPI := cfg.Require("primaryAPIURL")
	failureThreshold := cfgGet(cfg, "witnessFailureThreshold", "3")
	failoverWebhook := strings.TrimSpace(cfgGet(cfg, "failoverWebhookURL", ""))
	failoverHMAC := strings.TrimSpace(cfgGet(cfg, "failoverWebhookHMACSecret", ""))
	failoverGitHubRepo := strings.TrimSpace(cfgGet(cfg, "failoverGitHubRepo", ""))
	failoverGitHubToken := strings.TrimSpace(cfgGet(cfg, "failoverGitHubToken", ""))
	stateContainer := "witness-state"

	sa, err := storage.NewStorageAccount(ctx, "witnesssa", &storage.StorageAccountArgs{
		ResourceGroupName:      rg.Name,
		Location:               rg.Location,
		Sku:                    &storage.SkuArgs{Name: storage.SkuName_Standard_LRS},
		Kind:                   storage.KindStorageV2,
		AllowBlobPublicAccess:  pulumi.Bool(false),
		EnableHttpsTrafficOnly: pulumi.Bool(true),
		MinimumTlsVersion:      storage.MinimumTlsVersion_TLS1_2,
	})
	if err != nil {
		return err
	}

	// Durable counter for consecutive probe failures (Consumption Y1 has no sticky /tmp).
	_, err = storage.NewBlobContainer(ctx, "witness-state", &storage.BlobContainerArgs{
		ResourceGroupName: rg.Name,
		AccountName:       sa.Name,
		ContainerName:     pulumi.String(stateContainer),
		PublicAccess:      storage.PublicAccessNone,
	})
	if err != nil {
		return err
	}

	plan, err := web.NewAppServicePlan(ctx, "witness-plan", &web.AppServicePlanArgs{
		ResourceGroupName: rg.Name,
		Location:          rg.Location,
		Kind:              pulumi.String("FunctionApp"),
		Sku: &web.SkuDescriptionArgs{
			Name: pulumi.String("Y1"),
			Tier: pulumi.String("Dynamic"),
		},
		Reserved: pulumi.Bool(true),
	})
	if err != nil {
		return err
	}

	keys := storage.ListStorageAccountKeysOutput(ctx, storage.ListStorageAccountKeysOutputArgs{
		ResourceGroupName: rg.Name,
		AccountName:       sa.Name,
	})
	conn := pulumi.All(sa.Name, keys.Keys().Index(pulumi.Int(0)).Value()).ApplyT(func(args []any) string {
		name := args[0].(string)
		key := args[1].(string)
		return "DefaultEndpointsProtocol=https;AccountName=" + name + ";AccountKey=" + key + ";EndpointSuffix=core.windows.net"
	}).(pulumi.StringOutput)
	// ToSecret returns Output; re-wrap as StringOutput for AppSettings.
	secretConn := pulumi.ToSecret(conn).ApplyT(func(v any) string {
		return v.(string)
	}).(pulumi.StringOutput)

	app, err := web.NewWebApp(ctx, "witness-fn", &web.WebAppArgs{
		ResourceGroupName: rg.Name,
		Location:          rg.Location,
		Kind:              pulumi.String("FunctionApp"),
		ServerFarmId:      plan.ID(),
		Reserved:          pulumi.Bool(true),
		SiteConfig: &web.SiteConfigArgs{
			LinuxFxVersion: pulumi.String("PYTHON|3.11"),
			AppSettings: witnessAppSettings(
				secretConn,
				primaryAPI,
				failureThreshold,
				stateContainer,
				failoverWebhook,
				failoverHMAC,
				failoverGitHubRepo,
				failoverGitHubToken,
			),
		},
	})
	if err != nil {
		return err
	}

	ctx.Export("witnessFunctionName", app.Name)
	ctx.Export("witnessDefaultHost", app.DefaultHostName)
	ctx.Export("witnessStateContainer", pulumi.String(stateContainer))
	ctx.Export("primaryAPIURL", pulumi.String(primaryAPI))
	ctx.Export("failoverWebhookConfigured", pulumi.Bool(failoverWebhook != ""))
	ctx.Export("failoverGitHubDispatchConfigured", pulumi.Bool(failoverGitHubRepo != "" && failoverGitHubToken != ""))
	return nil
}

func witnessAppSettings(
	secretConn pulumi.StringOutput,
	primaryAPI, failureThreshold, stateContainer,
	failoverWebhook, failoverHMAC, failoverGitHubRepo, failoverGitHubToken string,
) web.NameValuePairArray {
	settings := web.NameValuePairArray{
		&web.NameValuePairArgs{Name: pulumi.String("FUNCTIONS_EXTENSION_VERSION"), Value: pulumi.String("~4")},
		&web.NameValuePairArgs{Name: pulumi.String("FUNCTIONS_WORKER_RUNTIME"), Value: pulumi.String("python")},
		&web.NameValuePairArgs{Name: pulumi.String("AzureWebJobsStorage"), Value: secretConn},
		&web.NameValuePairArgs{Name: pulumi.String("PRIMARY_API_URL"), Value: pulumi.String(primaryAPI)},
		&web.NameValuePairArgs{Name: pulumi.String("FAILURE_THRESHOLD"), Value: pulumi.String(failureThreshold)},
		&web.NameValuePairArgs{Name: pulumi.String("WITNESS_STATE_CONTAINER"), Value: pulumi.String(stateContainer)},
	}
	if failoverWebhook != "" {
		// Treat as secret so the URL is encrypted in stack state.
		settings = append(settings, &web.NameValuePairArgs{
			Name:  pulumi.String("FAILOVER_WEBHOOK_URL"),
			Value: pulumi.ToSecret(failoverWebhook).(pulumi.StringOutput),
		})
	}
	if failoverHMAC != "" {
		settings = append(settings, &web.NameValuePairArgs{
			Name:  pulumi.String("FAILOVER_WEBHOOK_HMAC_SECRET"),
			Value: pulumi.ToSecret(failoverHMAC).(pulumi.StringOutput),
		})
	}
	if failoverGitHubRepo != "" {
		settings = append(settings, &web.NameValuePairArgs{
			Name:  pulumi.String("FAILOVER_GITHUB_REPO"),
			Value: pulumi.String(failoverGitHubRepo),
		})
	}
	if failoverGitHubToken != "" {
		settings = append(settings, &web.NameValuePairArgs{
			Name:  pulumi.String("FAILOVER_GITHUB_TOKEN"),
			Value: pulumi.ToSecret(failoverGitHubToken).(pulumi.StringOutput),
		})
	}
	return settings
}

func cfgGet(cfg *config.Config, key, def string) string {
	if v := cfg.Get(key); v != "" {
		return v
	}
	return def
}

func cfgGetBool(cfg *config.Config, key string, def bool) bool {
	v := cfg.Get(key)
	if v == "" {
		return def
	}
	switch v {
	case "1", "true", "True", "TRUE", "yes", "YES", "on", "ON":
		return true
	case "0", "false", "False", "FALSE", "no", "NO", "off", "OFF":
		return false
	default:
		return def
	}
}
