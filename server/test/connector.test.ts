import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../src/db.ts';
import { refreshAll } from '../src/refresh.ts';
import { connectorConfigFromEnv, connectorSources } from '../src/sources/connector.ts';

const SPEC = 'packy-connector/1';
const order = (over: Record<string, unknown> = {}) => ({
  orderId: 'A1', reference: '#A1', recipient: 'Marta', createdAt: '2026-11-10T09:00:00Z', sourceUpdatedAt: '2026-11-10T09:00:00Z',
  eligible: true, ineligibleReason: null, nonPhysical: [],
  lines: [{ lineId: 'l1', sku: '0806812399109', title: 'Sapone', variantTitle: null, required: 2, kind: 'physical', kindReason: null }],
  ...over,
});

/** A fake network: base URL -> path -> JSON body (or an HTTP status). */
function fakeFetch(routes: Record<string, Record<string, unknown>>, seen: { auth: string[] } = { auth: [] }): typeof fetch {
  return (async (input: string | URL, init?: RequestInit) => {
    seen.auth.push(new Headers(init?.headers).get('authorization') ?? '');
    const url = String(input);
    for (const [base, paths] of Object.entries(routes)) {
      if (!url.startsWith(base)) continue;
      const body = paths[url.slice(base.length) || '/'];
      if (typeof body === 'number') return new Response('{}', { status: body });
      if (body === undefined) return new Response('{}', { status: 404 });
      return new Response(JSON.stringify(body), { status: 200 });
    }
    throw new TypeError('fetch failed');
  }) as typeof fetch;
}

const cfg = (name: string, url = `https://c.test/${name}`) => ({ name, url, token: `t-${name}` });

describe('connector config', () => {
  test('reads names, addresses and one token each', () => {
    const list = connectorConfigFromEnv({
      PACKY_CONNECTORS: 'shop=https://c.test/shop/, erp-1=https://c.test/erp',
      PACKY_CONNECTOR_TOKEN_SHOP: 'a', PACKY_CONNECTOR_TOKEN_ERP_1: 'b',
    });
    assert.deepEqual(list, [{ name: 'shop', url: 'https://c.test/shop', token: 'a' }, { name: 'erp-1', url: 'https://c.test/erp', token: 'b' }]);
  });
  test('a missing token, a bad name, a repeat or plain http fails at startup', () => {
    assert.throws(() => connectorConfigFromEnv({ PACKY_CONNECTORS: 'shop=https://c.test' }), /PACKY_CONNECTOR_TOKEN_SHOP/);
    assert.throws(() => connectorConfigFromEnv({ PACKY_CONNECTORS: 'Shop=https://c.test', PACKY_CONNECTOR_TOKEN_SHOP: 'a' }), /valid name/);
    assert.throws(() => connectorConfigFromEnv({ PACKY_CONNECTORS: 'a=https://x.test,a=https://y.test', PACKY_CONNECTOR_TOKEN_A: 't' }), /twice/);
    assert.throws(() => connectorConfigFromEnv({ PACKY_CONNECTORS: 'a=http://x.test', PACKY_CONNECTOR_TOKEN_A: 't' }), /https/);
    assert.equal(connectorConfigFromEnv({ PACKY_CONNECTORS: 'a=http://localhost:8790/a', PACKY_CONNECTOR_TOKEN_A: 't' }).length, 1);
    assert.deepEqual(connectorConfigFromEnv({}), []);
  });
  test('PACKY_PRODUCTS_FROM must name a configured connector', () => {
    assert.throws(() => connectorSources([cfg('shop')], { productsFrom: 'erp' }), /PACKY_PRODUCTS_FROM/);
  });
});

describe('connector sources', () => {
  const routes = {
    'https://c.test/shop': {
      '/': { spec: SPEC, name: 'shop', provides: ['orders', 'barcodes'] },
      '/orders': { spec: SPEC, orders: [order()] },
      '/barcodes': { spec: SPEC, barcodes: [{ barcode: '0806812399109', code: 'MS024', sourceRef: 'v1' }] },
    },
    'https://c.test/erp': {
      '/': { spec: SPEC, name: 'erp', provides: ['products'] },
      '/products': { spec: SPEC, products: [{ code: 'MS024', name: 'Sapone 250 ml', externalId: '9' }] },
    },
  };

  test('orders, products and barcodes arrive through the spec, each source under its connector name', async () => {
    const db = openDb(':memory:');
    const seen = { auth: [] as string[] };
    const sources = connectorSources([cfg('shop'), cfg('erp')], { fetch: fakeFetch(routes, seen) });
    await refreshAll(db, sources, () => 1000);
    const o = db.prepare('SELECT source, reference FROM orders').all();
    assert.deepEqual(o.map((r) => ({ ...r })), [{ source: 'shop', reference: '#A1' }]);
    assert.deepEqual({ ...db.prepare('SELECT code, name, external_id FROM products').get() }, { code: 'MS024', name: 'Sapone 250 ml', external_id: '9' });
    assert.deepEqual({ ...db.prepare('SELECT barcode, codice, provenance FROM barcode_map').get() }, { barcode: '0806812399109', codice: 'MS024', provenance: 'shop' });
    const status = Object.fromEntries((db.prepare('SELECT source, status FROM source_status').all() as { source: string; status: string }[]).map((r) => [r.source, r.status]));
    assert.deepEqual(status, { shop: 'ok', products: 'ok' });
    assert.ok(seen.auth.every((a) => a === 'Bearer t-shop' || a === 'Bearer t-erp'));
  });

  test('a response that breaks the spec is rejected whole and the last good orders stay', async () => {
    const db = openDb(':memory:');
    const live = structuredClone(routes);
    await refreshAll(db, connectorSources([cfg('shop')], { fetch: fakeFetch(live) }), () => 1000);
    (live['https://c.test/shop'] as Record<string, unknown>)['/orders'] = { spec: SPEC, orders: [order({ orderId: 'B2' }), order({ lines: [{ lineId: 'x', required: 0 }] })] };
    await refreshAll(db, connectorSources([cfg('shop')], { fetch: fakeFetch(live) }), () => 2000);
    assert.deepEqual(db.prepare('SELECT order_id FROM orders').all().map((r) => r.order_id), ['A1']);
    assert.deepEqual({ ...db.prepare("SELECT status, error_code FROM source_status WHERE source = 'shop'").get() }, { status: 'unavailable', error_code: 'connector_bad_response' });
  });

  test('an unreachable connector is unavailable, not empty, and a bad token reads as unauthorized', async () => {
    const db = openDb(':memory:');
    const live: Record<string, Record<string, unknown>> = structuredClone(routes);
    const sources = connectorSources([cfg('shop')], { fetch: fakeFetch(live) });
    await refreshAll(db, sources, () => 1000);
    for (const k of Object.keys(live)) delete live[k];
    await refreshAll(db, sources, () => 2000);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM orders').get()?.n, 1);
    assert.deepEqual({ ...db.prepare("SELECT status, error_code FROM source_status WHERE source = 'shop'").get() }, { status: 'unavailable', error_code: 'connector_unreachable' });

    const db2 = openDb(':memory:');
    await refreshAll(db2, connectorSources([cfg('shop')], { fetch: fakeFetch({ 'https://c.test/shop': { '/': 401 } }) }), () => 1000);
    assert.equal(db2.prepare("SELECT error_code FROM source_status WHERE source = 'shop'").get()?.error_code, 'connector_unauthorized');
  });

  test('a connector whose manifest names another connector is refused', async () => {
    const db = openDb(':memory:');
    await refreshAll(db, connectorSources([cfg('other', 'https://c.test/shop')], { fetch: fakeFetch(routes) }), () => 1000);
    assert.equal(db.prepare("SELECT error_code FROM source_status WHERE source = 'other'").get()?.error_code, 'connector_name_mismatch');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM orders').get()?.n, 0);
  });

  test('two connectors offering products need PACKY_PRODUCTS_FROM; without a product list it reads not connected', async () => {
    const both = structuredClone(routes);
    (both['https://c.test/shop'] as Record<string, unknown>)['/'] = { spec: SPEC, name: 'shop', provides: ['orders', 'products'] };
    (both['https://c.test/shop'] as Record<string, unknown>)['/products'] = { spec: SPEC, products: [{ code: 'Z', name: 'Z', externalId: null }] };
    const db = openDb(':memory:');
    await refreshAll(db, connectorSources([cfg('shop'), cfg('erp')], { fetch: fakeFetch(both) }), () => 1000);
    assert.equal(db.prepare("SELECT status FROM source_status WHERE source = 'products'").get()?.status, 'not_connected');
    const db2 = openDb(':memory:');
    await refreshAll(db2, connectorSources([cfg('shop'), cfg('erp')], { fetch: fakeFetch(both), productsFrom: 'erp' }), () => 1000);
    assert.equal(db2.prepare('SELECT code FROM products').get()?.code, 'MS024');
  });

  test('barcodes in spreadsheet notation are refused', async () => {
    const bad = structuredClone(routes);
    (bad['https://c.test/shop'] as Record<string, unknown>)['/barcodes'] = { spec: SPEC, barcodes: [{ barcode: '8.05004E+12', code: 'MS001', sourceRef: null }] };
    const db = openDb(':memory:');
    await refreshAll(db, connectorSources([cfg('shop')], { fetch: fakeFetch(bad) }), () => 1000);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM barcode_map').get()?.n, 0);
  });
});

describe('connector security', () => {
  test('a redirect is never followed, so the token cannot be carried to another host', async () => {
    let init: RequestInit | undefined;
    const spy = (async (_u: string, i?: RequestInit) => { init = i; return new Response(JSON.stringify({ spec: SPEC, name: 'shop', provides: [] })); }) as typeof fetch;
    await connectorSources([cfg('shop')], { fetch: spy }).prepare!();
    assert.equal(init?.redirect, 'error');
  });
  test('config errors name the variable, never the token', () => {
    try {
      connectorConfigFromEnv({ PACKY_CONNECTORS: 'shop=http://x.test', PACKY_CONNECTOR_TOKEN_SHOP: 'super-secret-value' });
      assert.fail('should throw');
    } catch (e) {
      assert.doesNotMatch(String(e), /super-secret-value/);
    }
  });
});

