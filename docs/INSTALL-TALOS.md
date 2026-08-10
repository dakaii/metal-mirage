# Installing Talos onto metal

metal-mirage applies machine config + bootstrap **after** nodes are in Talos
**maintenance mode**. Getting there is a separate concern (Lifecycle).

| Level | What | In this repo? |
|-------|------|----------------|
| **A** | Fetch ISO / kernel / initramfs with checksum verify + flash hints | **Yes** — `tools/talos-installer` + `./scripts/fetch-talos-installer.sh` |
| **B** | Lab PXE (dnsmasq + iPXE on an isolated VLAN) | **Yes (lab only)** — [`lab/pxe/`](../lab/pxe/) |
| **C** | BMC / Redfish power + virtual media | **Seam only** — `lifecycle.provider: noop`; `redfish` rejected in OSS |

Shell wrappers stay thin; download/verify logic is **Go** (testable, checksum-safe).
Operator glue (`up.sh`, flash notes) remains bash — same pattern as the rest of `scripts/`.

Doing full A+B+C production automation in-tree is **overkill** for OSS: C is a
commercial-shaped adapter (credentials, vendor variance, blast radius). We ship
A + honest B + a Lifecycle **port stub** so a private repo can implement Redfish
without rewriting GitOps.

## A — USB / ISO (recommended start)

```bash
./scripts/fetch-talos-installer.sh              # metal-amd64.iso → .secrets/talos-installer/
# Flash USB (dd / Ventoy / Etcher) — instructions printed by the tool
# Boot each node → maintenance mode (apid :50000)
./scripts/up.sh primary                         # dry_run true first is fine
# Export configs when available, then:
#   set dry_run: false → ./scripts/up.sh primary
```

Other assets:

```bash
./scripts/fetch-talos-installer.sh pxe-set                 # kernel + initramfs + boot.ipxe
./scripts/fetch-talos-installer.sh raw --arch arm64
TALOS_VERSION=v1.9.5 ./scripts/fetch-talos-installer.sh iso
```

## B — Lab PXE

See [`lab/pxe/README.md`](../lab/pxe/README.md). Isolated VLAN required.
Alternatively use [factory.talos.dev](https://factory.talos.dev) PXE URLs or Omni.

## C — Lifecycle / BMC (not in OSS runtime)

```yaml
# config/clusters.yaml
lifecycle:
  provider: noop        # default; redfish → validation error in OSS

primary:
  nodes:
    - role: controlplane
      ip: 192.168.1.10
      bmc:                 # optional metadata only today
        endpoint: https://192.168.1.100
        username: root
        # password via secret store / env in an out-of-tree adapter — never commit
```

`pkg/ports.LifecyclePort` exposes `PowerOn` / `PowerOff` / `SetBootPXE`.
`NoopLifecycle` returns `ErrLifecycleNotImplemented`. A commercial adapter can
implement `provider: redfish` out of tree.

## Related

- [METAL-PRIMARY.md](METAL-PRIMARY.md) — inventory → apply golden path
- [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md) — port matrix
- Azure metal-sim lab (no ISO): `./scripts/register-talos-image.sh` + `infra/primary`
