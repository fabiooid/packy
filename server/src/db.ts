import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
  failed_logins INTEGER NOT NULL DEFAULT 0, locked_until INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS auth_sessions (
  token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS products (code TEXT PRIMARY KEY, name TEXT NOT NULL, external_id TEXT, pulled_at INTEGER NOT NULL);
-- barcode and codice are TEXT on purpose: leading zeroes must survive.
CREATE TABLE IF NOT EXISTS barcode_map (
  barcode TEXT NOT NULL, codice TEXT NOT NULL, provenance TEXT NOT NULL, source_ref TEXT, observed_at INTEGER NOT NULL,
  PRIMARY KEY (barcode, codice, provenance)
);
-- How each order source names our products. key is an exact string, like barcodes.
CREATE TABLE IF NOT EXISTS product_links (
  source TEXT NOT NULL, key_type TEXT NOT NULL, key TEXT NOT NULL, codice TEXT NOT NULL,
  PRIMARY KEY (source, key_type, key)
);
CREATE TABLE IF NOT EXISTS source_status (
  source TEXT PRIMARY KEY, status TEXT NOT NULL, error_code TEXT, last_attempt_at INTEGER, last_success_at INTEGER
);
CREATE TABLE IF NOT EXISTS orders (
  source TEXT NOT NULL, order_id TEXT NOT NULL, reference TEXT NOT NULL, recipient TEXT,
  created_at TEXT NOT NULL, source_updated_at TEXT NOT NULL, eligible INTEGER NOT NULL, ineligible_reason TEXT,
  lines TEXT NOT NULL, non_physical TEXT NOT NULL, pulled_at INTEGER NOT NULL,
  PRIMARY KEY (source, order_id)
);
CREATE TABLE IF NOT EXISTS packs (
  id TEXT PRIMARY KEY, source TEXT NOT NULL, order_id TEXT NOT NULL, status TEXT NOT NULL,
  owner_user_id INTEGER NOT NULL REFERENCES users(id), version INTEGER NOT NULL DEFAULT 1,
  accepted_lines TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  completed_at INTEGER, completed_by INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS one_live_pack ON packs(source, order_id) WHERE status IN ('active','completed');
CREATE UNIQUE INDEX IF NOT EXISTS one_active_pack_per_user ON packs(owner_user_id) WHERE status = 'active';
CREATE TABLE IF NOT EXISTS units (
  id TEXT PRIMARY KEY, pack_id TEXT NOT NULL REFERENCES packs(id), line_id TEXT NOT NULL, codice TEXT NOT NULL,
  barcode TEXT NOT NULL, status TEXT NOT NULL, confirmed_by INTEGER NOT NULL, confirmed_at INTEGER NOT NULL,
  removed_by INTEGER, removed_at INTEGER, removal_reason TEXT
);
CREATE TABLE IF NOT EXISTS scans (
  id TEXT PRIMARY KEY, pack_id TEXT NOT NULL REFERENCES packs(id), barcode TEXT NOT NULL, symbology TEXT,
  outcome TEXT NOT NULL, line_id TEXT, user_id INTEGER NOT NULL, created_at INTEGER NOT NULL,
  expires_at INTEGER, consumed_at INTEGER
);
CREATE TABLE IF NOT EXISTS discrepancies (
  id TEXT PRIMARY KEY, pack_id TEXT NOT NULL REFERENCES packs(id), kind TEXT NOT NULL, barcode TEXT, codice TEXT,
  title TEXT NOT NULL, detail TEXT NOT NULL, read_count INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL,
  resolution TEXT, resolved_by INTEGER, resolved_at INTEGER, created_at INTEGER NOT NULL
);
-- Pieces the packer marked out of stock. The order can finish as "parziale"; the second shipment is handled by people.
CREATE TABLE IF NOT EXISTS shortages (
  pack_id TEXT NOT NULL REFERENCES packs(id), line_id TEXT NOT NULL, quantity INTEGER NOT NULL,
  user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (pack_id, line_id)
);
CREATE TABLE IF NOT EXISTS actions (action_id TEXT PRIMARY KEY, pack_id TEXT NOT NULL, response TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, pack_id TEXT NOT NULL, type TEXT NOT NULL, user_id INTEGER, data TEXT, created_at INTEGER NOT NULL
);
`;

export function openDb(path: string): DatabaseSync {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  // Older databases named the product list after one platform. The table is a cache refilled on the next pull.
  const cols = db.prepare("SELECT name FROM pragma_table_info('products')").all() as { name: string }[];
  if (cols.some((c) => c.name === 'fic_id')) db.exec('DROP TABLE products');
  db.exec(SCHEMA);
  db.exec(`DELETE FROM source_status WHERE source = 'fic'`);
  return db;
}

export function tx<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
