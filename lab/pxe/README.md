# Lab PXE (optional — Level B)

Homelab-only recipe to network-boot Talos into **maintenance mode**. This is
**not** production BMC/PXE orchestration and is **not** wired into Pulumi.

Prefer [Image Factory PXE](https://factory.talos.dev) or Omni when you outgrow USB.

## Honest limits

- Needs a dedicated lab VLAN / DHCP you control (host networking).
- Easy to break your home LAN DHCP — use an isolated switch/VLAN.
- You must **edit** `dnsmasq.conf.example` (or your own conf). Compose does **not**
  read `PXE_*` environment variables.
- `undionly.kpxe` / iPXE firmware under TFTP is **not** shipped — provide your own
  or use machines that already speak iPXE HTTP.
- No BMC power/boot control here (Lifecycle stays `noop` in OSS — see
  [INSTALL-TALOS.md](../../docs/INSTALL-TALOS.md)).

## 1. Fetch kernel + initramfs + iPXE script

```bash
# Replace the host with the IP that will serve .secrets/talos-installer/
./scripts/fetch-talos-installer.sh pxe-set --http-base http://192.168.10.2:8080
```

## 2. Serve the asset directory

```bash
cd .secrets/talos-installer
python3 -m http.server 8080
```

Confirm `curl -fsS http://192.168.10.2:8080/boot.ipxe` returns the script.

## 3. DHCP (dnsmasq)

1. Copy [`dnsmasq.conf.example`](dnsmasq.conf.example) → e.g. `dnsmasq.conf`.
2. Edit **interface**, **dhcp-range**, **router**, and the `http://…/boot.ipxe` URL
   to match your lab VLAN and HTTP server.
3. Place `undionly.kpxe` (or your iPXE build) in a TFTP root if clients need it.
4. Run dnsmasq on the host with that config, **or**:

```bash
# Host networking + isolated NIC. Mount *your* edited conf + optional tftpboot.
docker compose -f lab/pxe/docker-compose.yml up
# Default compose mounts dnsmasq.conf.example — replace the volume with your edited file.
```

## 4. Boot node → maintenance → apply

When the node reaches Talos maintenance (apid `:50000`):

```bash
./scripts/up.sh primary   # after dry_run: false in clusters.yaml
# Optional USB/talosctl path:
./scripts/export-baremetal-machine-configs.sh
```

## Alternatives

| Approach | When |
|----------|------|
| USB ISO (`./scripts/fetch-talos-installer.sh iso`) | Few nodes, simplest |
| factory.talos.dev PXE URL | Sidero-hosted iPXE without local file serve |
| Omni | Managed machine enrollment |
| Out-of-tree Redfish / Lifecycle adapter | Lights-out rack ops |
