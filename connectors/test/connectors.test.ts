import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { Hono } from 'hono';
import { parseOrders, SPEC } from '../../spec/connector-v1.ts';
import { connectorApp } from '../src/serve.ts';
import { normalizeOrder, ORDERS_QUERY, VARIANTS_QUERY } from '../src/shopify.ts';
import type { ShopifyOrderNode } from '../src/shopify.ts';

describe('Shopify rows', () => {
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

describe('read-only', () => {
  test('Shopify documents are queries, not mutations', () => {
    for (const q of [ORDERS_QUERY, VARIANTS_QUERY]) {
      assert.match(q, /^query /);
      assert.doesNotMatch(q, /mutation/);
    }
  });
});

describe('spec output', () => {
  const TOKEN = 'x'.repeat(32);
  const node: ShopifyOrderNode = {
    id: 'gid://shopify/Order/1', name: '#1001', createdAt: '2026-11-10T09:00:00Z', updatedAt: '2026-11-10T09:05:00Z',
    cancelledAt: null, closed: false, displayFinancialStatus: 'PAID', shippingAddress: { name: 'Marta Bianchi' },
    lineItems: { nodes: [{ id: 'a', sku: '0806812399109', title: 'Sapone', variantTitle: '250 ml', quantity: 2, currentQuantity: 2, requiresShipping: true }] },
    fulfillmentOrders: { nodes: [{ status: 'OPEN', lineItems: { nodes: [{ remainingQuantity: 2, lineItem: { id: 'a' } }] } }] },
    shippingLines: { nodes: [{ title: 'Standard' }] },
  };
  const app = connectorApp('shopify', { orders: async () => [normalizeOrder(node)], barcodes: async () => [] }, TOKEN);
  const get = (path: string, token: string | null = TOKEN) => app.request(path, { headers: token ? { authorization: `Bearer ${token}` } : {} });

  test('needs the token', async () => {
    assert.equal((await get('/', null)).status, 401);
    assert.equal((await get('/orders', 'wrong')).status, 401);
  });
  test('mounted under a path, the manifest answers at {base}/ as Packy asks for it', async () => {
    const outer = new Hono({ strict: false });
    outer.route('/shopify', app);
    const res = await outer.request('/shopify/', { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).name, 'shopify');
  });
  test('the manifest lists only what is served', async () => {
    assert.deepEqual(await (await get('/')).json(), { spec: SPEC, name: 'shopify', provides: ['orders', 'barcodes'] });
    assert.equal((await get('/products')).status, 404);
  });
  test('normalized Shopify orders pass the spec, leading zeroes kept', async () => {
    const res = await get('/orders');
    assert.equal(res.status, 200);
    const body = parseOrders(await res.json());
    assert.equal(body.orders[0].lines[0].sku, '0806812399109');
    assert.equal(body.orders[0].lines.find((l) => l.shipping)?.title, 'Standard');
  });
  test('output that breaks the spec is refused with a code, never sent', async () => {
    const bad = connectorApp('shopify', { orders: async () => [{ ...normalizeOrder(node), createdAt: 'yesterday' }] }, TOKEN);
    const res = await bad.request('/orders', { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal(res.status, 502);
    assert.deepEqual(await res.json(), { error: { code: 'spec_violation' } });
  });
  test('platform errors become codes, so tokens or customer data never leave', async () => {
    const failing = connectorApp('shopify', { orders: async () => { throw new Error('token abc123 rejected for Marta'); } }, TOKEN);
    const res = await failing.request('/orders', { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.deepEqual(await res.json(), { error: { code: 'platform_error' } });
  });
});
