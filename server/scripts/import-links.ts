// Usage: npm run links:import -- <links.csv>
// CSV columns: source,key,codice and optionally key_type (sku, product_id or variant_id; default sku).
// Example row: faire,p_abc123,MS001 or faire,MS-001-250,MS001,sku. Values stay exact text.
// Replaces the link for the same source + key_type + key. Writes data/product-links.json; restart the server to load it.
import { readFileSync, writeFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) { console.error('Usage: npm run links:import -- <links.csv>'); process.exit(1); }
const target = new URL('../../data/product-links.json', import.meta.url);
const artifact = JSON.parse(readFileSync(target, 'utf8')) as { note: string; links: { source: string; keyType: string; key: string; codice: string }[] };
const [header, ...rows] = readFileSync(file, 'utf8').split(/\r?\n/).filter((r) => r.trim()).map((r) => r.split(',').map((c) => c.trim().replace(/^"|"$/g, '')));
const col = (name: string) => header.findIndex((h) => h.toLowerCase() === name);
const [source, key, codice, keyType] = [col('source'), col('key'), col('codice'), col('key_type')];
if (source < 0 || key < 0 || codice < 0) { console.error('The CSV needs source, key and codice columns (key_type is optional).'); process.exit(1); }
const types = new Set(['sku', 'product_id', 'variant_id']);
let added = 0, replaced = 0;
for (const [i, row] of rows.entries()) {
  const link = { source: row[source]?.toLowerCase(), keyType: (keyType >= 0 && row[keyType]) ? row[keyType].toLowerCase() : 'sku', key: row[key], codice: row[codice] };
  if (!link.source || !link.key || !link.codice) { console.error(`Row ${i + 2}: source, key and codice are all required.`); process.exit(1); }
  if (!types.has(link.keyType)) { console.error(`Row ${i + 2}: key_type must be sku, product_id or variant_id.`); process.exit(1); }
  if (/e\+/i.test(link.key)) { console.error(`Row ${i + 2}: ${link.key} looks like a spreadsheet number, not an exact string.`); process.exit(1); }
  const at = artifact.links.findIndex((l) => l.source === link.source && l.keyType === link.keyType && l.key === link.key);
  if (at >= 0) { artifact.links[at] = link; replaced++; } else { artifact.links.push(link); added++; }
}
artifact.links.sort((a, b) => a.source.localeCompare(b.source) || a.key.localeCompare(b.key));
writeFileSync(target, JSON.stringify(artifact, null, 2) + '\n');
console.log(`${added} links added, ${replaced} replaced. Restart the server to load them. Links to codes missing from Fatture in Cloud are ignored and the line shows as Custom.`);
