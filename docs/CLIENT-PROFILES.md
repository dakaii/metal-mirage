# Client profiles (tunnel exports)

Personal WireGuard exits mint **client profiles** — importable artifacts for apps on your devices. The optional control-plane exposes a small **protocol registry** so new export types can land later without rewriting the peer HTTP API.

**Shipped today:** `wireguard` → `wireguard-conf` (standard INI `.conf`).

## Why a registry

| Concern | Approach |
|---------|----------|
| Peer storage | `peers` row + `protocol` column (default `wireguard`) |
| Key mint + render | `control-plane/internal/tunnel.Protocol` |
| HTTP | Handlers call the registry; they do not hard-code INI strings |
| Operator path | `vpn-bootstrap.sh` still writes the same `.conf` shape for laptop bring-up |

```
POST /api/peers  →  Protocol.MintKeys + Store.Create + Protocol.RenderExports
GET  /api/tunnel/protocols  →  registry metadata (no auth)
```

## Importing `wireguard-conf`

Save the `exports[].body` (or legacy `config` field) as a `.conf` file and import it into any client that accepts **standard WireGuard profiles**, including:

- Official WireGuard apps (desktop / mobile)
- Shadowrocket (WireGuard profile import)
- Other apps that speak the same INI format

Operator bootstrap:

```bash
./scripts/vpn-bootstrap.sh phone
# → vpn-clients/<city>-phone.conf
```

## Extending (for forks / later OSS)

1. Implement `tunnel.Protocol` (ID, Formats, MintKeys, RenderExports).
2. `registry.Register(...)` in `tunnel.DefaultRegistry` (or inject a custom registry in tests).
3. Teach `tunnel.ParseProtocolID` to accept the new ID when you are ready to mint it via API.
4. Keep the city-exit VM path honest: `vpn-reconcile-peers.sh` / `listpeers` default to **WireGuard** peers only (`wg set`). Non-WG protocols need their own projection path.

Additional protocols are **not** required for personal WireGuard use. Commercial multi-protocol product surfaces stay out of this repo — see [ROADMAP.md](ROADMAP.md) and [LEGAL.md](LEGAL.md).

## Related

- [VPN.md](VPN.md) — city exit deploy + reconcile
- [control-plane/README.md](../control-plane/README.md) — API table
