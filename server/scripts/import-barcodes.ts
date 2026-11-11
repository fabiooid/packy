// Usage: npm run barcodes:import -- <register.csv>. CSV columns: sku,ean. Values stay exact text. Merges into data/barcode-map.json.
import { readFileSync, writeFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) { console.error('Usage: npm run barcodes:import -- <register.csv>'); process.exit(1); }
const target = new URL('../../data/barcode-map.json', import.meta.url);
const artifact = JSON.parse(readFileSync(target, 'utf8'));
const [header, ...rows] = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map((r) => r.split(',').map((c) => c.replace(/^"|"$/g, '')));
const sku = header.findIndex((h) => h.toLowerCase() === 'sku');
const ean = header.findIndex((h) => h.toLowerCase() === 'ean');
if (sku < 0 || ean < 0) { console.error('The CSV needs sku and ean columns.'); process.exit(1); }
let added = 0;
for (const row of rows) {
  const codice = row[sku];
  const barcode = row[ean];
  if (!codice || !barcode) continue;
  if (/e\+/i.test(barcode)) { console.error(`Refusing ${codice}: ${barcode} looks like a spreadsheet number, not an exact string.`); process.exit(1); }
  const exists = artifact.entries.some((e: { barcode: string; codice: string; provenance: string }) => e.barcode === barcode && e.codice === codice && e.provenance === 'marketplace_register');
  if (!exists) { artifact.entries.push({ barcode, codice, provenance: 'marketplace_register', sourceRef: file.split('/').pop() }); added++; }
}
writeFileSync(target, JSON.stringify(artifact, null, 2) + '\n');
console.log(`Added ${added} register rows. Conflicts are detected at lookup time and fail closed.`);
