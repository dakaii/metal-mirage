# Lab PXE (optional — Level B)

Homelab-only recipe to network-boot Talos into **maintenance mode**. This is
**not** production BMC/PXE orchestration and is **not** wired into Pulumi.

Prefer [Image Factory PXE](https://factory.talos.dev) or Omni when you outgrow USB.

## Honest limits

- Needs a dedicated lab VLAN / DHCP you control (host networking).
- Easy to break your home LAN DHCP — use an isolated switch/VLAN.
- No BMC power/boot control here (Lifecycle stays `noop` in OSS — see
  [INSTALL-TALOS.md](../../docs/INSTALL-TALOS.md)).

## 1. Fetch kernel + initramfs + iPXE script

```bash
# Replace PXE_HOST with the IP of the machine that will serve files.
HTTP_BASE=http://192.168.10.2:8080 ./scripts/fetch-talos-installer.sh pxe-set
# Assets land in .secrets/talos-installer/ (gitignored)
```

## 2. Serve the asset directory

```bash
cd .secrets/talos-installer
python3 -m http.server 8080
```

Confirm `curl -fsS http://192.168.10.2:8080/boot.ipxe` returns the script.

## 3. DHCP + proxyDHCP (dnsmasq example)

Copy and edit [`dnsmasq.conf.example`](dnsmasq.conf.example), then either:

```bash
# From repo root — requires Docker host networking + an isolated NIC/VLAN.
export PXE_INTERFACE=eth1          # lab NIC
export PXE_ROUTER=192.168.10.1
export PXE_RANGE_START=192.168.10.50
export PXE_RANGE_END=192.168.10.100
export PXE_HTTP=http://192.168.10.2:8080
docker compose -f lab/pxe/docker-compose.yml up
```

Or run dnsmasq on the host with the example config. Point iPXE/`dhcp-boot` at
`${PXE_HTTP}/boot.ipxe`.

## 4. Boot node → maintenance → apply

When the node reaches Talos maintenance (apid `:50000`):

```bash
# Preferred: Pulumi apply
#   set dry_run: false in config/clusters.yaml
./scripts/up.sh primary
```

Or manual `talosctl apply-config --insecure` using exported machine configs
(`./scripts/export-baremetal-machine-configs.sh` when available on your branch).

## Alternatives

| Approach | When |
|----------|------|
| USB ISO (`./scripts/fetch-talos-installer.sh iso`) | Few nodes, simplest |
| factory.talos.dev PXE URL | Want Sidero-hosted iPXE without local file serve |
| Omni | Managed machine enrollment |
| Commercial Lifecycle / Redfish | Lights-out rack ops (out of this OSS repo) |
