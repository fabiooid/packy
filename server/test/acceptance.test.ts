import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createApp } from '../src/app.ts';
import { addOperator } from '../src/auth.ts';
import { lookupBarcode, saveBarcodes } from '../src/catalog.ts';
import { openDb } from '../src/db.ts';
import { ORDER_MAX_AGE_MS, SCAN_OFFER_MS } from '../src/pack.ts';
import { FIXTURE_BARCODES, fixtureSources } from '../src/sources/fixture.ts';
import type { FixtureControl } from '../src/sources/fixture.ts';
import { normalizeOrder, ORDERS_QUERY, VARIANTS_QUERY } from '../src/sources/shopify.ts';
import type { ShopifyOrderNode } from '../src/sources/shopify.ts';

const barcodeFor = (codice: string) => {
  const entry = FIXTURE_BARCODES.find((e) => e.codice === codice);
  if (!entry) throw new Error(`fixture barcode missing for ${codice}`);
  return entry.barcode;
};
const MS001 = barcodeFor('MS001');
const MS002 = barcodeFor('MS002');
const MS024 = barcodeFor('MS024');
const MS040 = barcodeFor('MS040');

let clock: number;
let fixture: FixtureControl;
let app: ReturnType<typeof createApp>;
let db: ReturnType<typeof openDb>;

async function call(token: string | null, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as any };
}

async function signIn(username: string): Promise<string> {
  const res = await call(null, 'POST', '/v1/auth/login', { username, password: 'test-password-1' });
  assert.equal(res.status, 200);
  return res.json.token;
}

const open = async (t: string, orderId: string) => (await call(t, 'POST', '/v1/packs', { source: 'fixture', orderId })).json;
const scan = (t: string, pack: any, barcode: string) => call(t, 'POST', `/v1/packs/${pack.id}/scans`, { barcode, symbology: 'ean13' });
const confirm = (t: string, pack: any, scanId: string, actionId: string = randomUUID()) =>
  call(t, 'POST', `/v1/packs/${pack.id}/confirm`, { scanId, actionId, version: pack.version });
const confirmManual = (t: string, pack: any, lineId: string, actionId: string = randomUUID()) =>
  call(t, 'POST', `/v1/packs/${pack.id}/confirm`, { lineId, actionId, version: pack.version });

async function confirmManualLines(t: string, pack: any): Promise<any> {
  let current = pack;
  for (;;) {
    const line = current.lines.find((l: any) => l.verification?.method === 'manual' && (l.remaining > 0 || l.uncertain > 0));
    if (!line) return current;
    const res = await confirmManual(t, current, line.lineId);
    assert.equal(res.status, 200, res.json.error?.message ?? JSON.stringify(res.json));
    current = res.json;
  }
}
const act = (t: string, pack: any, name: string) => call(t, 'POST', `/v1/packs/${pack.id}/${name}`, { actionId: randomUUID(), version: pack.version });
const resolve = (t: string, pack: any, id: string, resolution: string) =>
  call(t, 'POST', `/v1/packs/${pack.id}/discrepancies/${id}/resolve`, { resolution, actionId: randomUUID(), version: pack.version });
const refresh = (t: string) => call(t, 'POST', '/v1/refresh', {});

async function packUnit(t: string, pack: any, barcode: string): Promise<any> {
  const s = await scan(t, pack, barcode);
  assert.equal(s.json.scan.outcome, 'eligible', s.json.scan.message);
  const c = await confirm(t, s.json.pack, s.json.scan.id);
  assert.equal(c.status, 200);
  return c.json;
}

async function packUnits(t: string, pack: any, barcodes: string[]): Promise<any> {
  let current = pack;
  for (const barcode of barcodes) current = await packUnit(t, current, barcode);
  return current;
}

const codes = (pack: any) => pack.blockers.map((b: any) => b.code);

let ana: string;
let ben: string;

beforeEach(async () => {
  clock = 1_800_000_000_000;
  db = openDb(':memory:');
  fixture = fixtureSources();
  app = createApp({ db, now: () => clock, policies: { kitCodes: ['MS010'] }, sources: fixture.sources }, fixture);
  addOperator(db, 'ana', 'Ana', 'test-password-1');
  addOperator(db, 'ben', 'Ben', 'test-password-1');
  ana = await signIn('ana');
  ben = await signIn('ben');
  await refresh(ana);
});

describe('1. authenticated access', () => {
  test('no route exposes orders without a valid session', async () => {
    for (const [m, p] of [['GET', '/v1/workload'], ['POST', '/v1/refresh'], ['POST', '/v1/packs'], ['GET', '/v1/packs/x']] as const) {
      assert.equal((await call(null, m, p, m === 'POST' ? {} : undefined)).status, 401);
      assert.equal((await call('forged-token', m, p, m === 'POST' ? {} : undefined)).status, 401);
    }
  });
  test('sessions expire, logout ends them, and repeated failures lock the account', async () => {
    clock += 13 * 3_600_000;
    assert.equal((await call(ana, 'GET', '/v1/workload')).status, 401);
    const fresh = await signIn('ana');
    await call(fresh, 'POST', '/v1/auth/logout', {});
    assert.equal((await call(fresh, 'GET', '/v1/workload')).status, 401);
    for (let i = 0; i < 5; i++) assert.equal((await call(null, 'POST', '/v1/auth/login', { username: 'ben', password: 'wrong-password' })).status, 401);
    assert.equal((await call(null, 'POST', '/v1/auth/login', { username: 'ben', password: 'test-password-1' })).status, 429);
  });
  test('the workload lists eligible orders and flags fixture data', async () => {
    const w = (await call(ana, 'GET', '/v1/workload')).json;
    assert.equal(w.fixture, true);
    assert.ok(w.orders.some((o: any) => o.orderId === 'f1' && o.eligible));
    assert.ok(!JSON.stringify(w).includes('token'));
  });
});

describe('2. identity', () => {
  test('resolved lines use FIC names, not source titles', async () => {
    const p = await open(ana, 'f1');
    assert.equal(p.lines[0].identity.ficName, 'Cardamomo Sapone Mani 250ml');
    assert.equal(p.lines[0].identity.codice, 'MS001');
  });
  test('a blank SKU stays unresolved even when the title resembles a product', async () => {
    const p = await open(ana, 'f3');
    const line = p.lines.find((l: any) => l.lineId === 'f3-a');
    assert.equal(line.identity.status, 'unresolved');
    assert.equal(line.identity.ficName, null);
    assert.equal(line.identity.codice, null);
    assert.equal(line.verification.method, 'manual');
    assert.equal(line.canManualConfirm, true);
    assert.ok(!codes(p).includes('identity_unresolved'));
  });
  test('without an FIC catalog no line resolves and completion is blocked', async () => {
    db.exec('DELETE FROM products');
    const p = await open(ana, 'f2');
    assert.ok(p.lines.every((l: any) => l.identity.status === 'unresolved'));
    assert.equal(p.canComplete, false);
  });
});

describe('3 and 6. units, detection, repeated reads', () => {
  test('detection alone adds nothing and one confirmed unit does not satisfy quantity 3', async () => {
    let p = await open(ana, 'f1');
    const s = await scan(ana, p, MS001);
    assert.equal(s.json.scan.outcome, 'eligible');
    assert.equal(s.json.pack.lines[0].verified, 0);
    for (let i = 0; i < 5; i++) await scan(ana, p, MS001);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.lines[0].verified, 0);
    p = (await confirm(ana, p, s.json.scan.id)).json;
    assert.equal(p.lines[0].verified, 1);
    assert.equal(p.lines[0].remaining, 2);
    assert.equal(p.lines[0].state, 'partial');
    assert.equal(p.canComplete, false);
  });
  test('one offer yields one unit: reuse and expiry both fail', async () => {
    const p = await open(ana, 'f1');
    const s = await scan(ana, p, MS001);
    const first = await confirm(ana, p, s.json.scan.id);
    const again = await confirm(ana, first.json, s.json.scan.id);
    assert.equal(again.status, 409);
    assert.equal(again.json.error.code, 'scan_used');
    const s2 = await scan(ana, first.json, MS001);
    clock += SCAN_OFFER_MS + 1;
    const late = await confirm(ana, first.json, s2.json.scan.id);
    assert.equal(late.json.error.code, 'scan_expired');
    assert.equal(late.json.pack.lines[0].verified, 1);
  });
  test('a retried tap with the same action id does not double count', async () => {
    const p = await open(ana, 'f1');
    const s = await scan(ana, p, MS001);
    const id = randomUUID();
    await confirm(ana, p, s.json.scan.id, id);
    const retry = await confirm(ana, p, s.json.scan.id, id);
    assert.equal(retry.status, 200);
    assert.equal(retry.json.lines[0].verified, 1);
  });
  test('every view states that codes cannot prove distinct bottles', async () => {
    assert.match((await open(ana, 'f1')).limitsNote, /tipo di prodotto, non il singolo pezzo/);
  });
});

describe('4. wrong product and excess', () => {
  test('the lookalike earns no credit and is reported without blocking the order', async () => {
    let p = await open(ana, 'f1');
    const s = await scan(ana, p, MS002);
    assert.equal(s.json.scan.outcome, 'wrong_product');
    assert.equal(s.json.scan.codice, 'MS002');
    assert.equal(s.json.scan.productName, 'Cardamomo Sapone Mani 500ml');
    assert.match(s.json.scan.message, /Prodotto sbagliato\. Non contato/);
    assert.match(s.json.scan.message, /Hai letto Cardamomo Sapone Mani 500ml \(MS002\)\.$/);
    assert.doesNotMatch(s.json.scan.message, /MS001/, 'never suggests the right product');
    assert.equal(s.json.pack.lines[0].verified, 0);
    assert.equal(s.json.scan.id.length > 0, true);
    const offer = await confirm(ana, s.json.pack, s.json.scan.id);
    assert.equal(offer.json.error.code, 'scan_not_eligible');
    p = s.json.pack;
    assert.equal(s.json.scan.discrepancyId, null);
    assert.deepEqual(s.json.pack.discrepancies, []);
    p = await packUnits(ana, p, [MS001, MS001, MS001, MS024]);
    assert.equal(p.canComplete, false);
    p = await confirmManualLines(ana, p);
    assert.deepEqual(codes(p), []);
    assert.equal(p.canComplete, true);
  });
  test('excess never raises the count and does not block', async () => {
    let p = await open(ana, 'f2');
    p = await packUnit(ana, p, MS002);
    const s = await scan(ana, p, MS002);
    assert.equal(s.json.scan.outcome, 'excess');
    assert.equal(s.json.pack.lines[0].verified, 1);
    assert.deepEqual(s.json.pack.discrepancies, []);
    const again = await scan(ana, s.json.pack, MS002);
    assert.equal(again.json.pack.lines[0].verified, 1);
  });
});

describe('product-first scanning', () => {
  const scanFor = (t: string, pack: any, barcode: string, lineId: string) =>
    call(t, 'POST', `/v1/packs/${pack.id}/scans`, { barcode, symbology: 'ean13', lineId });

  test('with a product chosen, only that product can be counted', async () => {
    const p = await open(ana, 'f1');
    const other = await scanFor(ana, p, MS001, 'f1-b');
    assert.equal(other.json.scan.outcome, 'wrong_product');
    assert.match(other.json.scan.message, /^Prodotto sbagliato\. Non contato\. Hai letto .*\(MS001\)\.$/);
    assert.doesNotMatch(other.json.scan.message, /MS024/);
    assert.equal(other.json.pack.lines[0].verified, 0);
    const right = await scanFor(ana, p, MS024, 'f1-b');
    assert.equal(right.json.scan.outcome, 'eligible');
    assert.equal(right.json.scan.lineId, 'f1-b');
  });

  test('the chosen line must be on the order', async () => {
    const p = await open(ana, 'f1');
    const bad = await scanFor(ana, p, MS001, 'not-a-line');
    assert.equal(bad.status, 400);
    assert.equal(bad.json.error.code, 'bad_line');
  });

  test('after a matching scan, confirm records one unit; without a scan a barcoded line cannot be confirmed', async () => {
    let p = await open(ana, 'f1');
    const soap = p.lines.find((l: any) => l.lineId === 'f1-a');
    const skipped = await confirmManual(ana, p, soap.lineId);
    assert.equal(skipped.status, 409);
    assert.equal(skipped.json.error.code, 'scan_required');
    assert.equal(skipped.json.pack.lines.find((l: any) => l.lineId === 'f1-a').verified, 0);
    const s = await scanFor(ana, p, MS001, 'f1-a');
    assert.equal(s.json.scan.outcome, 'eligible');
    assert.equal(s.json.pack.lines.find((l: any) => l.lineId === 'f1-a').verified, 0);
    p = (await confirm(ana, s.json.pack, s.json.scan.id)).json;
    assert.equal(p.lines.find((l: any) => l.lineId === 'f1-a').verified, 1);
  });
});

describe('restart from 0', () => {
  test('restart clears every count and keeps the packer on the order', async () => {
    let p = await open(ana, 'f1');
    p = await packUnits(ana, p, [MS001, MS001]);
    assert.equal(p.lines[0].verified, 2);
    p = (await act(ana, p, 'restart')).json;
    assert.equal(p.status, 'active');
    assert.equal(p.isOwner, true);
    assert.equal(p.lines[0].verified, 0);
    assert.equal(p.hasRecordedCount, false);
    assert.equal(p.canLeave, true);
    p = await packUnit(ana, p, MS001);
    assert.equal(p.lines[0].verified, 1);
  });

  test('only the packer can restart', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    const seen = await open(ben, 'f1');
    assert.equal((await act(ben, seen, 'restart')).status, 403);
  });
});

describe('5. missing units and nonphysical rows', () => {
  test('one missing free sample blocks completion; shipping is a normal barcodeless line', async () => {
    let p = await open(ana, 'f2');
    const ship = p.lines.find((l: any) => l.lineId === 'f2-ship');
    assert.equal(ship.verification.method, 'manual');
    assert.deepEqual(p.nonPhysical, []);
    p = await packUnit(ana, p, MS002);
    assert.ok(codes(p).includes('units_missing'));
    p = await packUnit(ana, p, MS040);
    assert.equal(p.canComplete, false);
    p = await confirmManualLines(ana, p);
    assert.equal(p.canComplete, true);
    p = (await act(ana, p, 'complete')).json;
    assert.equal(p.status, 'completed');
  });
  test('a row of uncertain classification stays on the order and is confirmed by hand when it has no barcode', async () => {
    let p = await open(ana, 'f5');
    p = await packUnit(ana, p, MS002);
    const gift = p.lines.find((l: any) => l.lineId === 'f5-b');
    assert.equal(gift.verification.method, 'manual');
    assert.equal(p.canComplete, false);
    p = (await confirmManual(ana, p, 'f5-b')).json;
    assert.equal(p.canComplete, true);
  });
  test('Shopify rows: shipping is a normal line, a free item stays physical, no-shipping rows stay uncertain', () => {
    const node: ShopifyOrderNode = {
      id: 'o', name: '#1', createdAt: 'c', updatedAt: 'u', cancelledAt: null, closed: false, displayFinancialStatus: 'PAID',
      lineItems: { nodes: [
        { id: 'a', sku: 'MS001', title: 'SAMPLE', variantTitle: null, quantity: 1, currentQuantity: 1, requiresShipping: true },
        { id: 'b', sku: null, title: 'Mystery', variantTitle: null, quantity: 1, currentQuantity: 1, requiresShipping: false },
      ] },
      fulfillmentOrders: { nodes: [{ status: 'OPEN', lineItems: { nodes: [{ remainingQuantity: 1, lineItem: { id: 'a' } }] } }] },
      shippingLines: { nodes: [{ title: 'Express' }] },
    };
    const o = normalizeOrder(node);
    assert.equal(o.lines.find((l) => l.lineId === 'a')?.kind, 'physical');
    assert.equal(o.lines.find((l) => l.lineId === 'b')?.kind, 'uncertain');
    const ship = o.lines.find((l) => l.title === 'Express');
    assert.equal(ship?.kind, 'physical');
    assert.equal(ship?.sku, null);
    assert.deepEqual(o.nonPhysical, []);
  });
});

describe('7. interruption and corrections', () => {
  test('a person cannot open a second order while one is unfinished', async () => {
    const first = await open(ana, 'f1');
    const blocked = await call(ana, 'POST', '/v1/packs', { source: 'fixture', orderId: 'f2' });
    assert.equal(blocked.status, 409);
    assert.equal(blocked.json.error.code, 'order_already_open');
    assert.match(blocked.json.error.message, /Un ordine alla volta/);
    const same = await open(ana, 'f1');
    assert.equal(same.id, first.id);
    assert.equal((await act(ana, first, 'release')).status, 200);
    const next = await open(ana, 'f2');
    assert.equal(next.orderId, 'f2');
  });

  test('progress survives a new session and device', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    const other = await signIn('ana');
    const resumed = await open(other, 'f1');
    assert.equal(resumed.id, p.id);
    assert.equal(resumed.lines[0].verified, 1);
  });
  test('a stale device cannot write over newer progress', async () => {
    const p = await open(ana, 'f1');
    const s1 = await scan(ana, p, MS001);
    const s2 = await scan(ana, p, MS001);
    await confirm(ana, p, s1.json.scan.id);
    const stale = await confirm(ana, p, s2.json.scan.id);
    assert.equal(stale.json.error.code, 'stale_version');
    assert.equal(stale.json.pack.lines[0].verified, 1);
  });
  test('a removed unit loses its credit', async () => {
    let p = await open(ana, 'f2');
    p = await packUnit(ana, p, MS002);
    const unit = p.lines[0].units[0];
    p = (await call(ana, 'POST', `/v1/packs/${p.id}/units/${unit.id}/remove`, { reason: 'damaged', actionId: randomUUID(), version: p.version })).json;
    assert.equal(p.lines[0].verified, 0);
    assert.equal(p.lines[0].remaining, 1);
  });
});

describe('v1 session and counting rules', () => {
  test('leave with zero counts returns the order to ready, including after a read that was not counted', async () => {
    let p = await open(ana, 'f1');
    assert.equal(p.hasRecordedCount, false);
    assert.equal(p.canLeave, true);
    const unread = await scan(ana, p, MS001);
    assert.equal(unread.json.scan.outcome, 'eligible');
    assert.equal(unread.json.pack.lines[0].verified, 0);
    assert.equal(unread.json.pack.hasRecordedCount, false);
    assert.equal(unread.json.pack.canLeave, true);
    assert.equal((await act(ana, unread.json.pack, 'release')).status, 200);
    const again = await open(ana, 'f1');
    assert.notEqual(again.id, p.id);
    assert.equal(again.lines[0].verified, 0);
    assert.equal(again.status, 'active');
    assert.equal((await act(ana, again, 'release')).status, 200);
    const next = await open(ana, 'f2');
    assert.equal(next.orderId, 'f2');
  });

  test('a recorded count keeps the session until the order is packed or cancelled', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    assert.equal(p.hasRecordedCount, true);
    assert.equal(p.canLeave, false);
    const blocked = await call(ana, 'POST', '/v1/packs', { source: 'fixture', orderId: 'f2' });
    assert.equal(blocked.status, 409);
    assert.equal(blocked.json.error.code, 'order_already_open');
    const resumed = await open(ana, 'f1');
    assert.equal(resumed.id, p.id);
    assert.equal(resumed.lines[0].verified, 1);
  });

  test('cancelling an order in progress clears its counts and frees the operator', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    assert.equal((await act(ben, p, 'release')).status, 403);
    assert.equal((await act(ana, p, 'release')).status, 200);
    const w = (await call(ana, 'GET', '/v1/workload')).json;
    const f1 = w.orders.find((o: any) => o.orderId === 'f1');
    assert.equal(f1.packId, null);
    const next = await open(ana, 'f2');
    assert.equal(next.orderId, 'f2');
    const units = db.prepare(`SELECT status, removal_reason FROM units WHERE pack_id = ?`).all(p.id) as any[];
    assert.deepEqual(units.map((u) => [u.status, u.removal_reason]), [['removed', 'box_emptied']]);
  });

  test('a normal locked order cannot be emptied and left', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    assert.equal(p.canEmptyAndLeave, false);
  });

  test('a cancelled order with counted units can be emptied and left', async () => {
    let p = await open(ana, 'f1');
    p = await packUnit(ana, p, MS001);
    fixture.orders[0].eligible = false;
    fixture.orders[0].ineligibleReason = 'Cancelled at the source.';
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.canLeave, false);
    assert.equal(p.canEmptyAndLeave, true);
    assert.equal((await act(ana, p, 'release')).status, 200);
    const next = await open(ana, 'f2');
    assert.equal(next.orderId, 'f2');
  });

  test('an order with a line that can never be verified can be emptied and left', async () => {
    fixture.orders[1].lines.push({
      lineId: 'f2-ghost', sku: 'MS999', title: 'Articolo sconosciuto', variantTitle: null, required: 1, kind: 'physical', kindReason: null,
    });
    await refresh(ana);
    let p = await open(ana, 'f2');
    p = await packUnit(ana, p, MS002);
    assert.ok(codes(p).includes('identity_unresolved'));
    assert.equal(p.canEmptyAndLeave, true);
    assert.equal((await act(ana, p, 'release')).status, 200);
  });

  test('scans in any order track the matching line without counting until confirm', async () => {
    let p = await open(ana, 'f1');
    const candle = p.lines.find((l: any) => l.identity.codice === 'MS024');
    const soap = p.lines.find((l: any) => l.identity.codice === 'MS001');
    const s24 = await scan(ana, p, MS024);
    assert.equal(s24.json.scan.outcome, 'eligible');
    assert.equal(s24.json.scan.lineId, candle.lineId);
    assert.equal(s24.json.pack.lines.find((l: any) => l.lineId === candle.lineId).verified, 0);
    p = (await confirm(ana, s24.json.pack, s24.json.scan.id)).json;
    assert.equal(p.lines.find((l: any) => l.lineId === candle.lineId).verified, 1);
    assert.equal(p.lines.find((l: any) => l.lineId === soap.lineId).verified, 0);
    const s01 = await scan(ana, p, MS001);
    assert.equal(s01.json.scan.lineId, soap.lineId);
    p = (await confirm(ana, s01.json.pack, s01.json.scan.id)).json;
    assert.equal(p.lines.find((l: any) => l.lineId === soap.lineId).verified, 1);
    assert.equal(p.canComplete, false);
  });

  test('quantity greater than one counts 1/3 then 2/3 then 3/3 and stays incomplete until full', async () => {
    let p = await open(ana, 'f1');
    const line = () => p.lines.find((l: any) => l.identity.codice === 'MS001');
    assert.equal(line().verified, 0);
    assert.equal(line().required, 3);
    p = await packUnit(ana, p, MS001);
    assert.equal(line().verified, 1);
    assert.equal(line().state, 'partial');
    assert.equal(p.canComplete, false);
    p = await packUnit(ana, p, MS001);
    assert.equal(line().verified, 2);
    assert.equal(p.canComplete, false);
    p = await packUnit(ana, p, MS001);
    assert.equal(line().verified, 3);
    assert.equal(line().state, 'done');
    assert.equal(p.canComplete, false);
    p = await packUnit(ana, p, MS024);
    assert.equal(p.canComplete, false);
    p = await confirmManualLines(ana, p);
    assert.equal(p.canComplete, true);
  });

  test('a missing unit stays visible as an incomplete line and keeps done locked', async () => {
    let p = await open(ana, 'f1');
    p = await packUnits(ana, p, [MS001, MS001, MS024]);
    const soap = p.lines.find((l: any) => l.identity.codice === 'MS001');
    assert.equal(soap.verified, 2);
    assert.equal(soap.required, 3);
    assert.equal(soap.remaining, 1);
    assert.equal(soap.state, 'partial');
    assert.ok(codes(p).includes('units_missing'));
    assert.equal(p.canComplete, false);
    assert.equal((await act(ana, p, 'complete')).json.error.code, 'completion_blocked');
  });

  test('an extra unit names the product and does not change the list count', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    assert.equal(p.canComplete, true);
    const s = await scan(ana, p, MS002);
    assert.equal(s.json.scan.outcome, 'excess');
    assert.match(s.json.scan.message, /Cardamomo Sapone Mani 500ml \(MS002\)/);
    assert.match(s.json.scan.message, /Non contato/);
    assert.equal(s.json.pack.lines[0].verified, 1);
    assert.equal(s.json.pack.canComplete, true);
  });
});

describe('8. changes and conflicting work', () => {
  test('a second operator cannot write, and takeover turns credit into recheck', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    const seen = await open(ben, 'f2');
    assert.equal(seen.isOwner, false);
    assert.equal((await scan(ben, seen, MS002)).status, 403);
    let taken = (await act(ben, seen, 'takeover')).json;
    assert.equal(taken.isOwner, true);
    assert.equal(taken.lines[0].verified, 0);
    assert.equal(taken.lines[0].uncertain, 1);
    assert.equal(taken.lines[0].remaining, 0);
    assert.ok(codes(taken).includes('units_uncertain'));
    assert.equal((await scan(ana, taken, MS002)).status, 403);
    taken = await packUnits(ben, taken, [MS002, MS040]);
    taken = await confirmManualLines(ben, taken);
    assert.equal(taken.lines[0].verified, 1);
    assert.equal(taken.lines[0].units.length, 1);
    assert.equal(taken.canComplete, true);
  });
  test('reduced quantity withdraws credit and demands the unit comes out', async () => {
    let p = await open(ana, 'f1');
    p = await packUnits(ana, p, [MS001, MS001, MS001, MS024]);
    p = await confirmManualLines(ana, p);
    assert.equal(p.canComplete, true);
    fixture.orders[0].lines[0].required = 2;
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.canComplete, false);
    assert.equal(p.changes[0].kind, 'quantity');
    assert.equal((await scan(ana, p, MS001)).json.error.code, 'order_changed');
    p = (await act(ana, p, 'reconcile')).json;
    assert.equal(p.lines[0].verified, 2);
    assert.equal(p.discrepancies[0].kind, 'order_reduced');
    assert.equal(p.canComplete, false);
    p = (await resolve(ana, p, p.discrepancies[0].id, 'set_aside')).json;
    assert.equal(p.canComplete, true);
  });
  test('raised quantity keeps credit and asks for more', async () => {
    let p = await open(ana, 'f2');
    p = await packUnit(ana, p, MS002);
    fixture.orders[1].lines[0].required = 2;
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    p = (await act(ana, p, 'reconcile')).json;
    assert.equal(p.lines[0].verified, 1);
    assert.equal(p.lines[0].remaining, 1);
  });
  test('cancellation blocks completion, even with every unit verified', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    fixture.orders[1].eligible = false;
    fixture.orders[1].ineligibleReason = 'Cancelled at the source.';
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.ok(codes(p).includes('order_ineligible'));
    assert.equal((await act(ana, p, 'complete')).status, 409);
  });
  test('an order that leaves the open set is blocked, not silently certified', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    fixture.orders.splice(1, 1);
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.ok(codes(p).includes('order_ineligible'));
  });
  test('a packed order that changes later is flagged and can be reopened', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    p = (await act(ana, p, 'complete')).json;
    fixture.orders[1].lines[0].required = 2;
    await refresh(ana);
    const w = (await call(ana, 'GET', '/v1/workload')).json;
    assert.equal(w.orders.find((o: any) => o.orderId === 'f2').changedAfterCompletion, true);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    p = (await act(ana, p, 'reopen')).json;
    assert.equal(p.status, 'active');
    assert.ok(codes(p).includes('order_changed'));
  });
});

describe('9. unknown, ambiguous, kits, leading zeroes', () => {
  test('an unknown code earns nothing and does not block', async () => {
    const p = await open(ana, 'f1');
    const s = await scan(ana, p, '0000000000000');
    assert.equal(s.json.scan.outcome, 'unknown_code');
    assert.equal(s.json.pack.lines[0].verified, 0);
    assert.ok(!codes(s.json.pack).includes('discrepancy_open'));
  });
  test('one code mapped to two products is ambiguous and earns nothing', async () => {
    saveBarcodes(db, [{ barcode: MS001, codice: 'MS002', provenance: 'test', sourceRef: null }], clock);
    const p = await open(ana, 'f1');
    assert.equal((await scan(ana, p, MS001)).json.scan.outcome, 'ambiguous_code');
    assert.equal(p.lines[0].state, 'blocked');
  });
  test('two sources disagreeing on a product code conflicts instead of picking one', async () => {
    saveBarcodes(db, [{ barcode: '1234567890128', codice: 'MS001', provenance: 'test', sourceRef: null }], clock);
    assert.equal(lookupBarcode(db, MS001).status, 'conflict');
    assert.ok(codes(await open(ana, 'f1')).includes('barcode_conflict'));
  });
  test('the kit is blocked with no acknowledgement route', async () => {
    const p = await open(ana, 'f4');
    assert.deepEqual(codes(p).slice(0, 1), ['kit_policy']);
    assert.equal(p.lines[0].verification.method, 'none');
    assert.equal(p.canComplete, false);
  });
  test('leading zeroes survive and no alternate form matches', async () => {
    assert.deepEqual(lookupBarcode(db, MS024), { status: 'resolved', codice: 'MS024' });
    assert.equal(lookupBarcode(db, MS024.slice(1)).status, 'unknown');
    const row = db.prepare('SELECT barcode, typeof(barcode) t FROM barcode_map WHERE codice = ?').get('MS024') as any;
    assert.deepEqual({ ...row }, { barcode: MS024, t: 'text' });
    const p = await open(ana, 'f1');
    assert.equal((await scan(ana, p, MS024.slice(1))).json.scan.outcome, 'unknown_code');
  });
});

describe('10. source failure and freshness', () => {
  test('an outage is not an empty workload', async () => {
    fixture.failing = true;
    const w = (await refresh(ana)).json;
    assert.equal(w.sources.find((s: any) => s.name === 'fixture').status, 'unavailable');
    assert.equal(w.sources.find((s: any) => s.name === 'fixture').errorCode, 'fixture_unavailable');
    assert.ok(w.orders.length > 0);
    assert.ok(w.orders.every((o: any) => o.freshness.state === 'unavailable'));
    assert.equal(w.sources.find((s: any) => s.name === 'faire').status, 'not_connected');
  });
  test('a healthy source with no orders is distinct from an outage', async () => {
    fixture.orders.length = 0;
    const w = (await refresh(ana)).json;
    assert.equal(w.orders.length, 0);
    assert.equal(w.sources.find((s: any) => s.name === 'fixture').status, 'ok');
  });
  test('work is preserved in an outage but stale data cannot complete', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    fixture.failing = true;
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.lines[0].verified, 1);
    assert.deepEqual(codes(p), ['stale_data']);
    assert.equal((await act(ana, p, 'complete')).status, 409);
    fixture.failing = false;
    await refresh(ana);
    clock += ORDER_MAX_AGE_MS + 1;
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.freshness.state, 'cached');
    assert.equal(p.canComplete, false);
    await refresh(ana);
    p = (await call(ana, 'GET', `/v1/packs/${p.id}`)).json;
    assert.equal(p.canComplete, true);
  });
});

describe('11. read-only sources', () => {
  test('completion calls no source, and adapter documents are queries, not mutations', async () => {
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    const before = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => { calls++; throw new Error('unexpected_network'); }) as typeof fetch;
    try {
      p = (await act(ana, p, 'complete')).json;
    } finally {
      globalThis.fetch = before;
    }
    assert.equal(p.status, 'completed');
    assert.equal(calls, 0);
    for (const q of [ORDERS_QUERY, VARIANTS_QUERY]) {
      assert.match(q, /^query /);
      assert.doesNotMatch(q, /mutation/);
    }
  });
});

describe('Shopify eligibility', () => {
  const base = (over: Partial<ShopifyOrderNode> = {}): ShopifyOrderNode => ({
    id: 'o', name: '#1', createdAt: 'c', updatedAt: 'u', cancelledAt: null, closed: false, displayFinancialStatus: 'PAID',
    lineItems: { nodes: [{ id: 'a', sku: 'MS001', title: 'T', variantTitle: null, quantity: 3, currentQuantity: 2, requiresShipping: true }] },
    fulfillmentOrders: { nodes: [{ status: 'OPEN', lineItems: { nodes: [{ remainingQuantity: 2, lineItem: { id: 'a' } }] } }] },
    shippingLines: { nodes: [] }, ...over,
  });
  test('the obligation is the remaining physical quantity, not the original', () => {
    assert.equal(normalizeOrder(base()).lines[0].required, 2);
  });
  test('cancelled, refunded, unpaid, held and finished orders are ineligible', () => {
    assert.equal(normalizeOrder(base({ cancelledAt: 'x' })).eligible, false);
    assert.equal(normalizeOrder(base({ displayFinancialStatus: 'REFUNDED' })).eligible, false);
    assert.equal(normalizeOrder(base({ displayFinancialStatus: 'PENDING' })).eligible, false);
    assert.equal(normalizeOrder(base({ fulfillmentOrders: { nodes: [{ status: 'ON_HOLD', lineItems: { nodes: [{ remainingQuantity: 2, lineItem: { id: 'a' } }] } }] } })).eligible, false);
    assert.equal(normalizeOrder(base({ fulfillmentOrders: { nodes: [{ status: 'CLOSED', lineItems: { nodes: [{ remainingQuantity: 0, lineItem: { id: 'a' } }] } }] } })).eligible, false);
  });
  test('a partial refund stays eligible with the reduced quantity', () => {
    const o = normalizeOrder(base({ displayFinancialStatus: 'PARTIALLY_REFUNDED' }));
    assert.equal(o.eligible, true);
    assert.equal(o.lines[0].required, 2);
  });
  test('an order too large to read completely cannot be certified', () => {
    const b = base();
    b.lineItems.pageInfo = { hasNextPage: true };
    assert.equal(normalizeOrder(b).eligible, false);
  });
});

describe('manual confirm for barcodeless lines', () => {
  test('a barcodeless line can be confirmed by hand, one unit at a time', async () => {
    let p = await open(ana, 'f3');
    const promo = p.lines.find((l: any) => l.lineId === 'f3-promo');
    assert.equal(promo.verification.method, 'manual');
    assert.equal(promo.canManualConfirm, true);
    assert.equal(promo.required, 2);
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    assert.equal(p.lines.find((l: any) => l.lineId === 'f3-promo').verified, 1);
    assert.equal(p.canComplete, false);
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    assert.equal(p.lines.find((l: any) => l.lineId === 'f3-promo').verified, 2);
    assert.equal(p.lines.find((l: any) => l.lineId === 'f3-promo').canManualConfirm, false);
  });

  test('a barcoded line cannot use the manual confirm path', async () => {
    const p = await open(ana, 'f1');
    const soap = p.lines.find((l: any) => l.identity.codice === 'MS001');
    assert.equal(soap.verification.method, 'barcode');
    assert.equal(soap.canManualConfirm, false);
    const res = await confirmManual(ana, p, soap.lineId);
    assert.equal(res.status, 409);
    assert.equal(res.json.error.code, 'scan_required');
    assert.equal(res.json.pack.lines.find((l: any) => l.lineId === soap.lineId).verified, 0);
  });

  test('shipping is a normal barcodeless line, not a skip', async () => {
    let p = await open(ana, 'f1');
    const ship = p.lines.find((l: any) => l.lineId === 'f1-ship');
    assert.equal(ship.identity.sourceTitle, 'Express');
    assert.equal(ship.verification.method, 'manual');
    assert.equal(ship.canManualConfirm, true);
    assert.deepEqual(p.nonPhysical, []);
    p = (await confirmManual(ana, p, 'f1-ship')).json;
    assert.equal(p.lines.find((l: any) => l.lineId === 'f1-ship').verified, 1);
    assert.equal(p.canComplete, false);
  });

  test('shipping must be confirmed but is never counted as a piece', async () => {
    const p = await open(ana, 'f1');
    assert.equal(p.lines.find((l: any) => l.lineId === 'f1-ship').isShipping, true);
    assert.equal(p.lines.find((l: any) => l.lineId === 'f1-a').isShipping, false);
    const w = (await call(ana, 'GET', '/v1/workload')).json;
    assert.equal(w.orders.find((o: any) => o.orderId === 'f1').units, 4);
  });

  test('the app reads the same packed feed and it needs a session', async () => {
    assert.equal((await call(null, 'GET', '/v1/packed')).status, 401);
    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    p = (await act(ana, p, 'complete')).json;
    const res = await call(ben, 'GET', '/v1/packed');
    assert.equal(res.status, 200);
    assert.equal(res.json.orders.length, 1);
    assert.equal(res.json.orders[0].reference, '#FIX-1002 free sample');
    assert.equal(res.json.orders[0].completedByName, 'Ana');
  });

  test('the dashboard reports pieces confirmed by hand', async () => {
    let p = await open(ana, 'f3');
    p = await packUnit(ana, p, MS001);
    p = await confirmManualLines(ana, p);
    p = (await act(ana, p, 'complete')).json;
    assert.equal(p.status, 'completed');
    const [o] = (await call(ana, 'GET', '/v1/admin/completed')).json.orders;
    assert.equal(o.units, 4);
    assert.equal(o.manualUnits, 3);
  });

  test('the order cannot be finished until barcodeless units are confirmed', async () => {
    let p = await open(ana, 'f3');
    p = await packUnit(ana, p, MS001);
    assert.equal(p.canComplete, false);
    assert.equal((await act(ana, p, 'complete')).json.error.code, 'completion_blocked');
    p = (await confirmManual(ana, p, 'f3-a')).json;
    assert.equal(p.canComplete, false);
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    assert.equal(p.canComplete, true);
  });

  test('a counted barcodeless unit can be taken back', async () => {
    let p = await open(ana, 'f3');
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    p = (await confirmManual(ana, p, 'f3-promo')).json;
    const line = p.lines.find((l: any) => l.lineId === 'f3-promo');
    assert.equal(line.verified, 2);
    const unitId = line.units[line.units.length - 1].id;
    const removed = await call(ana, 'POST', `/v1/packs/${p.id}/units/${unitId}/remove`, { reason: 'miscounted', actionId: randomUUID(), version: p.version });
    assert.equal(removed.status, 200);
    p = removed.json;
    const after = p.lines.find((l: any) => l.lineId === 'f3-promo');
    assert.equal(after.verified, 1);
    assert.equal(after.canManualConfirm, true);
    assert.equal(p.canComplete, false);
  });

  test('a retried manual confirm with the same action id does not double count', async () => {
    const p = await open(ana, 'f3');
    const id = randomUUID();
    const first = await confirmManual(ana, p, 'f3-a', id);
    assert.equal(first.status, 200);
    const retry = await confirmManual(ana, first.json, 'f3-a', id);
    assert.equal(retry.status, 200);
    assert.equal(retry.json.lines.find((l: any) => l.lineId === 'f3-a').verified, 1);
  });
});

describe('web dashboard', () => {
  test('the completed-orders feed needs a session and lists only packed orders, read-only', async () => {
    assert.equal((await call(null, 'GET', '/v1/admin/completed')).status, 401);
    assert.equal((await call('forged-token', 'GET', '/v1/admin/completed')).status, 401);

    let p = await open(ana, 'f2');
    p = await packUnits(ana, p, [MS002, MS040]);
    p = await confirmManualLines(ana, p);
    clock += 60_000;
    p = (await act(ana, p, 'complete')).json;
    assert.equal(p.status, 'completed');
    await open(ben, 'f1'); // in progress, must not appear

    const before = JSON.stringify(db.prepare('SELECT * FROM packs ORDER BY id').all());
    const res = await call(ben, 'GET', '/v1/admin/completed');
    assert.equal(res.status, 200);
    assert.equal(res.json.fixture, true);
    assert.equal(res.json.total, 1);
    assert.equal(res.json.orders.length, 1);
    const [o] = res.json.orders;
    assert.equal(o.completedByName, 'Ana');
    assert.equal(o.units, 2, 'shipping is not a piece');
    assert.equal(o.manualUnits, 0);
    assert.equal(o.completedAt, clock);
    assert.equal(o.recipient, 'Cliente di prova');
    assert.equal(JSON.stringify(db.prepare('SELECT * FROM packs ORDER BY id').all()), before);
    assert.ok(!JSON.stringify(res.json).includes('token'));

    clock += 31 * 24 * 3_600_000;
    const later = (await call(await signIn('ben'), 'GET', '/v1/admin/completed')).json;
    assert.equal(later.orders.length, 0);
    assert.equal(later.total, 1);
  });
  test('the page is public but carries no data and a strict CSP', async () => {
    const page = await app.request('/admin');
    assert.equal(page.status, 200);
    const csp = page.headers.get('content-security-policy') ?? '';
    assert.match(csp, /script-src 'self'/);
    assert.match(csp, /frame-ancestors 'none'/);
    const html = await page.text();
    assert.doesNotMatch(html, /<script>/);
    assert.doesNotMatch(html, /Cliente di prova/);
    const js = await app.request('/admin/app.js');
    assert.match(js.headers.get('content-type') ?? '', /javascript/);
    const source = await js.text();
    assert.match(source, /textContent/);
    assert.match(source, /const PAGE = 15/);
    assert.match(source, /pager\.hidden = true/);
    assert.match(html, /id="pager"/);
    assert.match(html, /Precedente/);
    assert.match(html, /Successivo/);
    assert.match(csp, /img-src 'self'/);
    assert.match(html, /\/admin\/logo\.png/);
    assert.match(html, /\/admin\/favicon\.png/);
    assert.match(html, /\/admin\/favicon\.ico/);
    assert.match(html, /alt="Packy"/);
    assert.doesNotMatch(html, /xcassets|AppIcon\.png/);
    const logo = await app.request('/admin/logo.png');
    assert.equal(logo.status, 200);
    assert.match(logo.headers.get('content-type') ?? '', /image\/png/);
    const logoBytes = Buffer.from(await logo.arrayBuffer());
    assert.equal(logoBytes.subarray(1, 4).toString(), 'PNG');
    assert.equal(logoBytes.readUInt32BE(16), 826);
    assert.equal(logoBytes.readUInt32BE(20), 740);
    assert.equal(logoBytes[25], 6);
    const favicon = await app.request('/admin/favicon.png');
    assert.equal(favicon.status, 200);
    const favBytes = Buffer.from(await favicon.arrayBuffer());
    assert.equal(favBytes.readUInt32BE(16), 32);
    assert.equal(favBytes.readUInt32BE(20), 32);
    const ico = await app.request('/admin/favicon.ico');
    assert.equal(ico.status, 200);
    assert.match(ico.headers.get('content-type') ?? '', /icon/);
  });
});
