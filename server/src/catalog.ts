import type { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import type { BarcodeEntry, ProductLink, SourceLine } from './types.ts';

export type BarcodeLookup =
  | { status: 'unknown' }
  | { status: 'conflict'; codici: string[]; reason: string }
  | { status: 'resolved'; codice: string };

export interface Identity {
  /** 'unresolved' means a custom item: not in the product list, confirmed by hand. */
  status: 'resolved' | 'unresolved';
  /** How the product was found: a saved link for this source, or the SKU equal to the product code. */
  matchedBy?: 'link' | 'sku' | null;
  codice: string | null;
  ficName: string | null;
  reason: string | null;
  /** Diagnostic only. Never an FIC name. */
  sourceTitle: string;
}

export interface Verification {
  method: 'barcode' | 'manual' | 'none';
  barcodes: string[];
  blockCode: 'no_barcode' | 'kit_policy' | 'barcode_conflict' | null;
  reason: string | null;
}

export interface Policies {
  /** Products whose physical verification needs an approved policy. Blocked until then. */
  kitCodes: string[];
}

export function loadPolicies(path: string): Policies {
  return JSON.parse(readFileSync(path, 'utf8')) as Policies;
}

export function saveBarcodes(db: DatabaseSync, entries: BarcodeEntry[], now: number): void {
  const insert = db.prepare(
    `INSERT INTO barcode_map (barcode, codice, provenance, source_ref, observed_at) VALUES (?,?,?,?,?)
     ON CONFLICT (barcode, codice, provenance) DO UPDATE SET source_ref = excluded.source_ref, observed_at = excluded.observed_at`,
  );
  for (const e of entries) {
    if (typeof e.barcode !== 'string' || e.barcode.length === 0) throw new Error('barcode must be a nonempty string');
    insert.run(e.barcode, e.codice, e.provenance, e.sourceRef, now);
  }
}

/** Replaces one feed's rows, so a barcode removed at the source stops counting. */
export function replaceFeed(db: DatabaseSync, provenance: string, entries: BarcodeEntry[], now: number): void {
  db.prepare('DELETE FROM barcode_map WHERE provenance = ?').run(provenance);
  saveBarcodes(db, entries, now);
}

function codiciFor(db: DatabaseSync, barcode: string): string[] {
  const rows = db.prepare('SELECT DISTINCT codice FROM barcode_map WHERE barcode = ?').all(barcode) as { codice: string }[];
  return rows.map((r) => r.codice);
}

function barcodesFor(db: DatabaseSync, codice: string): string[] {
  const rows = db.prepare('SELECT DISTINCT barcode FROM barcode_map WHERE codice = ?').all(codice) as { barcode: string }[];
  return rows.map((r) => r.barcode);
}

/** Exact string match only. No trimming, padding, or numeric comparison. */
export function lookupBarcode(db: DatabaseSync, barcode: string): BarcodeLookup {
  const codici = codiciFor(db, barcode);
  if (codici.length === 0) return { status: 'unknown' };
  if (codici.length > 1) {
    return { status: 'conflict', codici, reason: `Questo codice è collegato a ${codici.length} prodotti: ${codici.join(', ')}.` };
  }
  const siblings = barcodesFor(db, codici[0]);
  if (siblings.length > 1) {
    return { status: 'conflict', codici, reason: `${codici[0]} ha ${siblings.length} codici diversi registrati. L'abbinamento va controllato.` };
  }
  return { status: 'resolved', codice: codici[0] };
}

export function productName(db: DatabaseSync, code: string): string | null {
  const row = db.prepare('SELECT name FROM products WHERE code = ?').get(code) as { name: string } | undefined;
  return row?.name ?? null;
}

/** Replaces every product link with the given list. Links are set up once, before going live. */
export function replaceLinks(db: DatabaseSync, links: ProductLink[]): void {
  db.exec('DELETE FROM product_links');
  const insert = db.prepare('INSERT OR REPLACE INTO product_links (source, key_type, key, codice) VALUES (?,?,?,?)');
  for (const l of links) insert.run(l.source, l.keyType, l.key, l.codice);
}

function linkedCodice(db: DatabaseSync, source: string, keyType: string, key: string): string | null {
  const row = db.prepare('SELECT codice FROM product_links WHERE source = ? AND key_type = ? AND key = ?').get(source, keyType, key) as { codice: string } | undefined;
  return row?.codice ?? null;
}

/**
 * Finds our product for an order line, in a fixed order and never by guessing from the title:
 * 1. a saved link for one of the source's own ids, 2. a saved link for the SKU, 3. the SKU equal to a product code.
 * Anything else is a custom item, confirmed by hand.
 */
export function resolveIdentity(db: DatabaseSync, line: SourceLine, source = ''): Identity {
  const sourceTitle = [line.title, line.variantTitle].filter(Boolean).join(' ');
  const custom: Identity = { status: 'unresolved', matchedBy: null, codice: null, ficName: null, reason: null, sourceTitle };
  const candidates: { codice: string; by: 'link' | 'sku' }[] = [];
  for (const k of line.keys ?? []) {
    const c = linkedCodice(db, source, k.type, k.value);
    if (c) candidates.push({ codice: c, by: 'link' });
  }
  const sku = line.sku?.trim();
  if (sku) {
    const c = linkedCodice(db, source, 'sku', sku);
    if (c) candidates.push({ codice: c, by: 'link' });
    candidates.push({ codice: sku, by: 'sku' });
  }
  for (const c of candidates) {
    const name = productName(db, c.codice);
    if (name !== null) return { status: 'resolved', matchedBy: c.by, codice: c.codice, ficName: name, reason: null, sourceTitle };
  }
  return custom;
}

export function resolveVerification(db: DatabaseSync, codice: string, policies: Policies): Verification {
  if (policies.kitCodes.includes(codice)) {
    return { method: 'none', barcodes: [], blockCode: 'kit_policy', reason: `${codice} è un kit. Non c'è ancora un modo approvato per verificarlo.` };
  }
  const barcodes = barcodesFor(db, codice);
  if (barcodes.length === 0) {
    return { method: 'manual', barcodes, blockCode: 'no_barcode', reason: null };
  }
  const conflicted = barcodes.some((b) => lookupBarcode(db, b).status === 'conflict');
  if (conflicted) {
    return { method: 'none', barcodes: [], blockCode: 'barcode_conflict', reason: `I codici a barre di ${codice} sono in conflitto e vanno controllati.` };
  }
  return { method: 'barcode', barcodes, blockCode: null, reason: null };
}
