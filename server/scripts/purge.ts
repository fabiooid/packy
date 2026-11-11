// Usage: npm run purge -- [days]. Removes recipient names and finished packing detail older than the retention window.
import { openDb } from '../src/db.ts';

const days = Number(process.argv[2] ?? 90);
const db = openDb(process.env.PACKY_DB ?? 'data/packy.db');
const cutoff = Date.now() - days * 86_400_000;
const old = `SELECT id FROM packs WHERE status IN ('completed','released') AND updated_at < ${cutoff}`;
db.exec(`UPDATE orders SET recipient = NULL WHERE (source, order_id) IN (SELECT source, order_id FROM packs WHERE id IN (${old}))`);
for (const table of ['units', 'scans', 'discrepancies', 'actions', 'events']) db.exec(`DELETE FROM ${table} WHERE pack_id IN (${old})`);
db.exec(`DELETE FROM packs WHERE id IN (${old})`);
db.prepare('DELETE FROM auth_sessions WHERE expires_at < ?').run(Date.now());
console.log(`Purged finished packing records older than ${days} days.`);
