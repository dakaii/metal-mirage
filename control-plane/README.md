# Control plane (Phase 3) — Clerk + Neon peer portal

**Optional** demo layer on top of the WireGuard city exit. Not required for primary/standby/GitOps/VPN stacks.

**Not in scope here:** Stripe, Clerk Billing, subscriptions, rate-limit product features, or multi-tenant SaaS abuse controls. See [docs/ROADMAP.md](../docs/ROADMAP.md).

## What it does

- Authenticate users with **Clerk** (Bearer session JWT)
- Store device peers in **Neon** Postgres
- `POST /api/peers` mints a WireGuard keypair + client config JSON
- Allocates `10.66.0.2`–`10.66.0.251` (lowest free; unique in DB; reuses holes after DELETE)
- `POST /api/peers` returns **503** if the IP pool is exhausted, **409** if the device name already exists

Pushing the peer public key to the VPN VM is still an operator step in V1
(`wg set` / extend with a small reconciler later).

**Honesty — DB vs WireGuard drift:** this API only writes to Postgres. `scripts/vpn-bootstrap.sh` allocates from live `wg show` on the VM. After `POST /api/peers`, push DB peers onto the city VM with:

```bash
DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh
# optional: --prune removes WireGuard peers absent from the DB for that city
```

`DELETE /api/peers/{id}` removes the DB row only — re-run reconcile with `--prune` to drop it from `wg`.

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
| GET | `/api/peers` | Clerk | list devices |
| POST | `/api/peers` | Clerk | `{"name":"phone"}` → peer + private key + config |
| DELETE | `/api/peers/{id}` | Clerk | remove |
| GET | `/api/peers/{id}/config` | Clerk | metadata only |

## Env

See `.env.example`.
