package db

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

func Connect(ctx context.Context, url string) (*pgxpool.Pool, error) {
	return pgxpool.New(ctx, url)
}

func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS peers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  allocated_ip TEXT NOT NULL,
  city TEXT NOT NULL DEFAULT 'us',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);
CREATE INDEX IF NOT EXISTS peers_user_id_idx ON peers(user_id);
-- Enforce one peer per WireGuard address (NextIP reuses holes after DELETE).
-- IF NOT EXISTS only skips when this index name already exists; duplicate
-- allocated_ip rows from a prior buggy deploy will still make Migrate fail.
CREATE UNIQUE INDEX IF NOT EXISTS peers_allocated_ip_uidx ON peers(allocated_ip);
`)
	return err
}
