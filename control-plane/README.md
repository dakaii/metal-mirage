# Control plane (Phase 3) — Clerk + Neon peer portal

**Optional** demo layer on top of the WireGuard city exit. Not required for primary/standby/GitOps/VPN stacks.

**Not in scope here:** Stripe, Clerk Billing, subscriptions, rate-limit product features, or multi-tenant SaaS abuse controls. See [docs/ROADMAP.md](../docs/ROADMAP.md).

Client profile / export architecture: [docs/CLIENT-PROFILES.md](../docs/CLIENT-PROFILES.md).

## What it does

- Authenticate users with **Clerk** (Bearer session JWT)
- Store device peers in **Neon** Postgres (`protocol` defaults to `wireguard`)
- `POST /api/peers` mints keys via the tunnel registry and returns typed **exports** (plus legacy `config` for WireGuard INI)
- `GET /api/tunnel/protocols` lists registered protocols (public)

Pushing the peer public key to the VPN VM is still an operator step in V1
(`wg set` / `./scripts/vpn-reconcile-peers.sh`).

## Setup

1. Create a [Neon](https://neon.tech) project → copy `DATABASE_URL`
2. Create a [Clerk](https://clerk.com) application → copy secret key
3. From VPN stack outputs, set endpoint + server pubkey

```bash
cd control-plane
cp .env.example .env
# edit .env

go run ./cmd/server
```

## API

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| GET | `/healthz` | no | liveness |
| GET | `/api/tunnel/protocols` | no | registered protocols + export format IDs |
| GET | `/api/peers` | Clerk | list devices |
| POST | `/api/peers` | Clerk | `{"name":"phone"}` → peer + private key + `exports` (+ legacy `config`) |
| DELETE | `/api/peers/{id}` | Clerk | remove |
| GET | `/api/peers/{id}/config` | Clerk | metadata + export format list (no private key) |

`POST` may include optional `"protocol":"wireguard"` (default). Unsupported IDs return `400`.

Import `exports` where `id=wireguard-conf` into any client that accepts standard WireGuard profiles (official apps, Shadowrocket, etc.).

## Env

See `.env.example`.
