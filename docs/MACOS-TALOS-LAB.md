# macOS / Mac Mini — Talos lab (virtualization only)

**Can you run Talos on a Mac Mini?** Yes — as **guest VMs**, not as the Mac’s host OS.

| Goal | Supported? |
|------|------------|
| Wipe macOS and install Talos bare metal on **Apple Silicon** | **No** — not a Sidero target (proprietary boot/firmware; upstream Linux gap) |
| Wipe an **Intel** Mac Mini and try `metal-amd64` | Unofficial / unsupported; prefer a normal x86 mini-PC if you want real metal |
| Keep macOS; run Talos in **VMs** on the Mini | **Yes** — documented Sidero path |

This is a **local lab / portfolio** path. It is **not** metal-mirage’s preferred L1 (`infra/bare-metal` on real servers or Azure metal-sim). The Mini stays the **hypervisor host**; failure domain includes macOS, power, and ISP.

## Recommended: `talosctl` + QEMU (Apple Hypervisor)

Sidero’s [QEMU local platform](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/local-platforms/qemu) guide lists **Apple Silicon Mac**. On macOS, QEMU uses **HVF** (Apple Hypervisor.framework) and **vmnet** for networking.

```bash
brew install qemu
brew install siderolabs/tap/talosctl

# First time: ownable state dir (inspect logs as non-root later)
mkdir -p ~/.talos/clusters

# Creates a local Talos cluster (VMs). Needs RAM headroom on the Mini.
sudo --preserve-env=HOME talosctl cluster create qemu
```

After create, `talosctl` configures `~/.talos/config` and merges kubeconfig. Default lab net is typically `10.5.0.0/24` (gateway/LB on `.1`). Tear down:

```bash
sudo --preserve-env=HOME talosctl cluster destroy --provisioner qemu
```

If the host rebooted before destroy, you may need to remove `~/.talos/clusters/<name>` manually (see upstream docs).

### Gotchas

- **RAM** — control-plane + workers compete with macOS; undersized Minis thrash.
- **Version quirks** — occasional darwin/arm64 QEMU issues (e.g. kexec handoff on some 1.13.x builds). Prefer current Sidero docs; upstream issues document workarounds when regressions land.
- **sudo / networking** — first create often needs elevated privileges for vmnet.
- **Not portable L1** — metal-mirage `config/clusters.yaml` `provisioner: bare-metal` expects reachable maintenance-mode node IPs you inventory; a `talosctl`-created QEMU cluster is a separate local kubeconfig unless you manually bridge that gap.

## Alternatives on the same Mini

| Approach | Notes |
|----------|--------|
| **Docker provisioner** (`talosctl cluster create` with Docker) | Needs Docker Desktop / OrbStack / Colima. Faster ephemeral lab; less “full disk install” than QEMU. |
| **UTM** | GUI over QEMU / Virtualization.framework; you can boot arm64 Talos images by hand — more fiddly than `talosctl cluster create qemu`. |
| **Asahi Linux + k3s** | Different stack: Linux **on** Apple Silicon, then k3s — **not Talos**. Prefer an x86 NUC for Talos-on-metal. |

## Hardware preference (client vs lab)

| Box | Best role |
|-----|-----------|
| **Mac Mini (Apple Silicon)** | Operator laptop **or** Talos **VM lab** via QEMU |
| **x86 NUC / mini-PC** | Real Talos **bare metal** primary (matches `metal-amd64` + this repo’s golden path) |
| **Raspberry Pi (arm64)** | Cheap metal lab with `metal-arm64` / k3s; weak as a client production primary |
| **Azure metal-sim** | Lab without home hardware — [DEPLOY.md](DEPLOY.md) / `config/clusters.azure-metal-sim.example.yaml` |

## Related

- [INSTALL-TALOS.md](INSTALL-TALOS.md) — ISO / PXE for real metal
- [METAL-PRIMARY.md](METAL-PRIMARY.md) — inventory → Pulumi apply golden path
- [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) — L1 contract
- Upstream: [Talos QEMU on macOS](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/local-platforms/qemu)
