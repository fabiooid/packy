import type { DatabaseSync } from 'node:sqlite';
import { tx } from './db.ts';
import { replaceFeed } from './catalog.ts';
import { findLivePack } from './pack.ts';
import type { CatalogProduct, Sources, SourceOrder } from './types.ts';

function errorCode(error: unknown): string {
  // Codes only. Source errors must never carry tokens or customer data into logs or responses.
  const message = error instanceof Error ? error.message : '';
  return /^[a-z0-9_]+$/.test(message) ? message : 'source_error';
}

function setStatus(db: DatabaseSync, source: string, status: string, errorCodeValue: string | null, now: number): void {
  db.prepare(
    `INSERT INTO source_status (source, status, error_code, last_attempt_at, last_success_at) VALUES (?,?,?,?,?)
     ON CONFLICT (source) DO UPDATE SET status = excluded.status, error_code = excluded.error_code,
       last_attempt_at = excluded.last_attempt_at,
       last_success_at = COALESCE(excluded.last_success_at, source_status.last_success_at)`,
  ).run(source, status, errorCodeValue, now, status === 'ok' ? now : null);
}

function saveOrders(db: DatabaseSync, source: string, orders: SourceOrder[], now: number): void {
  const upsert = db.prepare(
    `INSERT INTO orders (source, order_id, reference, recipient, created_at, source_updated_at, eligible, ineligible_reason, lines, non_physical, pulled_at)
     VALUES (?,?,?,?,?,?,?,?,?,?,?)
     ON CONFLICT (source, order_id) DO UPDATE SET reference = excluded.reference, recipient = excluded.recipient,
       source_updated_at = excluded.source_updated_at, eligible = excluded.eligible, ineligible_reason = excluded.ineligible_reason,
       lines = excluded.lines, non_physical = excluded.non_physical, pulled_at = excluded.pulled_at`,
  );
  for (const o of orders) {
    upsert.run(o.source, o.orderId, o.reference, o.recipient, o.createdAt, o.sourceUpdatedAt, o.eligible ? 1 : 0, o.ineligibleReason,
      JSON.stringify(o.lines), JSON.stringify(o.nonPhysical), now);
  }
  // A healthy pull that no longer lists an order means it left the open set. Keep it, blocked, if work exists on it.
  const seen = new Set(orders.map((o) => o.orderId));
  const cached = db.prepare('SELECT order_id FROM orders WHERE source = ?').all(source) as { order_id: string }[];
  for (const { order_id } of cached) {
    if (seen.has(order_id)) continue;
    if (findLivePack(db, source, order_id)) {
      db.prepare('UPDATE orders SET eligible = 0, ineligible_reason = ?, pulled_at = ? WHERE source = ? AND order_id = ?')
        .run('Chiuso alla fonte: annullato o già evaso.', now, source, order_id);
    } else {
      db.prepare('DELETE FROM orders WHERE source = ? AND order_id = ?').run(source, order_id);
    }
  }
}

/** Pull stays outside the save. A failure keeps the last good rows and the previous success time. */
async function refreshSource<T>(
  db: DatabaseSync,
  name: string,
  now: () => number,
  pull: () => Promise<T>,
  save: (rows: T) => void,
): Promise<void> {
  try {
    const rows = await pull();
    tx(db, () => {
      save(rows);
      setStatus(db, name, 'ok', null, now());
    });
  } catch (error) {
    setStatus(db, name, 'unavailable', errorCode(error), now());
  }
}

/** Runs only when a person logs in, opens the app, or refreshes. Nothing schedules this. */
export async function refreshAll(db: DatabaseSync, sources: Sources, now: () => number): Promise<void> {
  const jobs: Promise<void>[] = [];

  if (sources.catalog) {
    const catalog = sources.catalog;
    jobs.push(refreshSource(db, catalog.name, now, () => catalog.pull(), (products: CatalogProduct[]) => {
      db.exec('DELETE FROM products');
      const insert = db.prepare('INSERT INTO products (code, name, fic_id, pulled_at) VALUES (?,?,?,?)');
      for (const p of products) insert.run(p.code, p.name, p.ficId, now());
    }));
  } else {
    setStatus(db, 'fic', 'not_connected', 'no_credentials', now());
  }

  for (const feed of sources.barcodes) {
    jobs.push((async () => {
      try {
        const entries = await feed.pull();
        tx(db, () => replaceFeed(db, feed.name, entries, now()));
      } catch (error) {
        // Keep the last known rows. A failed read must not erase mappings or mark the order source down.
        console.error(`barcode feed ${feed.name}: ${errorCode(error)}`);
      }
    })());
  }

  for (const source of sources.orders) {
    jobs.push(refreshSource(db, source.name, now, () => source.pull(), (orders) => {
      saveOrders(db, source.name, orders, now());
    }));
  }

  await Promise.all(jobs);
  for (const s of sources.notConnected) setStatus(db, s.name, 'not_connected', null, now());
}
