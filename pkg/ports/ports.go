// Package ports defines capability contracts for metal-mirage.
//
// These are intentional seams so adapters stay swappable:
//
//	Compute        — L1 cluster provisioners (azure-metal-sim | bare-metal | aks)
//	RemoteAccess   — optional device/admin access plane (wireguard today; none to disable)
//	Lifecycle      — power / BMC / boot (documented stub; not implemented in OSS)
//	Observability  — scrape / health signals (GitOps hints today; not a runtime port)
//
// WireGuard is the shipped RemoteAccess *example*, not the platform identity.
// See docs/CAPABILITY-PORTS.md for what is and is not in scope.
package ports

// ComputeProvider is the L1 primary/standby provisioner id (config/clusters.yaml).
type ComputeProvider string

const (
	ComputeAzureMetalSim ComputeProvider = "azure-metal-sim"
	ComputeBareMetal     ComputeProvider = "bare-metal"
	ComputeAKS           ComputeProvider = "aks"
)

// PrimaryOutputs is the portable contract every primary compute adapter must export.
// Kept as documentation of the Pulumi stack outputs (see docs/PORTABLE-ARCHITECTURE.md).
type PrimaryOutputs struct {
	Kubeconfig        string
	APILoadBalancerIP string
	IngressIP         string
	ClusterEndpoint   string
	Provisioner       string
}

// ComputePort is the L1 compute capability. OSS implements this via Pulumi stack
// directories selected by config/clusters.yaml — not a single in-process Go driver.
type ComputePort interface {
	Provider() ComputeProvider
	// PulumiDir is the adapter path (e.g. infra/primary, infra/bare-metal).
	PulumiDir() string
}

// RemoteAccessProvider identifies a remote-access adapter.
type RemoteAccessProvider string

const (
	// RemoteAccessWireGuard is the OSS example: personal city-exit WireGuard VM.
	RemoteAccessWireGuard RemoteAccessProvider = "wireguard"
	// RemoteAccessNone disables the remote-access plane (platform-only bring-up).
	RemoteAccessNone RemoteAccessProvider = "none"
)

// RemoteAccessPort is the optional access plane (VPN is one implementation).
// Runtime projection (e.g. wg set) stays in adapter scripts, not the core contract.
type RemoteAccessPort interface {
	Provider() RemoteAccessProvider
	PulumiDir() string
}

// LifecycleProvider identifies an out-of-band power/boot adapter.
type LifecycleProvider string

const (
	// LifecycleNoop is the OSS default — ISO/PXE/Omni are operator-driven.
	LifecycleNoop LifecycleProvider = "noop"
	// LifecycleRedfish is reserved for a commercial / out-of-tree adapter.
	// Configured in OSS → validation error (not silently ignored).
	LifecycleRedfish LifecycleProvider = "redfish"
)

// LifecyclePort covers out-of-band power and boot control (BMC / Redfish / iLO).
// OSS ships only NoopLifecycle — see docs/CAPABILITY-PORTS.md and docs/INSTALL-TALOS.md.
type LifecyclePort interface {
	Provider() LifecycleProvider
	// PowerOn / PowerOff / SetBootPXE are intentional seams. Noop returns ErrLifecycleNotImplemented.
	PowerOn(nodeID string) error
	PowerOff(nodeID string) error
	SetBootPXE(nodeID string) error
}

// ErrLifecycleNotImplemented is returned by NoopLifecycle for all mutating calls.
var ErrLifecycleNotImplemented = errLifecycle("lifecycle adapter not implemented in OSS (provider=noop); use ISO/USB or lab/pxe, or an out-of-tree Redfish adapter")

type errLifecycle string

func (e errLifecycle) Error() string { return string(e) }

// ObservabilityPort describes how health/metrics are exposed to operators.
// Today this is GitOps ConfigMap hints + optional PrometheusRule CRDs, not a driver.
type ObservabilityPort interface {
	Provider() string
}

// NoopLifecycle documents the missing BMC capability without pretending it works.
type NoopLifecycle struct{}

func (NoopLifecycle) Provider() LifecycleProvider { return LifecycleNoop }

func (NoopLifecycle) PowerOn(string) error { return ErrLifecycleNotImplemented }

func (NoopLifecycle) PowerOff(string) error { return ErrLifecycleNotImplemented }

func (NoopLifecycle) SetBootPXE(string) error { return ErrLifecycleNotImplemented }

// GitOpsObservability is the shipped observability shape (hints in gitops/).
type GitOpsObservability struct{}

func (GitOpsObservability) Provider() string { return "gitops-hints" }
