import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { parseOrders, SPEC } from '../../spec/connector-v1.ts';
import { faireConnector, normalizeFaireOrder } from '../src/faire.ts';
import type { FaireOrder } from '../src/faire.ts';

const order = (over: Partial<FaireOrder> = {}): FaireOrder => ({
  id: 'bo_1', display_id: 'ABC123', state: 'PROCESSING', created_at: '2026-11-10T09:00:00Z', updated_at: '2026-11-11T09:00:00Z',
  address: { name: 'Marta Bianchi', company_name: 'Bottega' },
  items: [{ id: 'oi_1', product_id: 'p_1', variant_id: 'po_1', sku: '0806812399109', product_name: 'Sapone', variant_name: '250 ml', quantity: 3 }],
  ...over,
});

describe('Faire orders', () => {
  test('a processing order maps to the spec with Faire ids as keys and leading zeroes kept', () => {
    const o = normalizeFaireOrder(order())!;
    parseOrders({ spec: SPEC, orders: [o] });
    assert.equal(o.reference, '#ABC123');
    assert.equal(o.recipient, 'Marta Bianchi');
    assert.equal(o.eligible, true);
    assert.equal(o.lines[0].sku, '0806812399109');
    assert.deepEqual(o.lines[0].keys, [{ type: 'product_id', value: 'p_1' }, { type: 'variant_id', value: 'po_1' }]);
  });
  test('new and backordered orders are listed but not packable; shipped and cancelled ones are left out', () => {
    assert.equal(normalizeFaireOrder(order({ state: 'NEW' }))?.ineligibleReason, 'Da accettare su Faire.');
    assert.equal(normalizeFaireOrder(order({ state: 'BACKORDERED' }))?.eligible, false);
    for (const state of ['IN_TRANSIT', 'DELIVERED', 'CANCELED']) assert.equal(normalizeFaireOrder(order({ state })), null);
  });
  test('cancelled or empty items are skipped; a tester is a separate line confirmed by hand', () => {
    const o = normalizeFaireOrder(order({ items: [
      { id: 'a', quantity: 2, product_name: 'Crema', includes_tester: true },
      { id: 'b', quantity: 1, product_name: 'Olio', state: 'CANCELED' },
      { id: 'c', quantity: 0, product_name: 'Sale' },
    ] }))!;
    assert.deepEqual(o.lines.map((l) => [l.lineId, l.kind, l.required]), [['a', 'physical', 2], ['a:tester', 'uncertain', 1]]);
  });
  test('a shape it does not understand fails closed', () => {
    assert.throws(() => normalizeFaireOrder({ id: 'x', state: 'PROCESSING' } as FaireOrder), /faire_bad_response/);
  });

  test('pages until a short page, sends the token only to Faire, and never as a URL parameter', async () => {
    const urls: string[] = [];
    const headers: Headers[] = [];
    const full = Array.from({ length: 50 }, (_, i) => order({ id: `bo_${i}` }));
    const fake = (async (u: string, init?: RequestInit) => {
      urls.push(u); headers.push(new Headers(init?.headers));
      return new Response(JSON.stringify({ orders: urls.length === 1 ? full : [order({ id: 'last' })] }));
    }) as typeof fetch;
    const got = await faireConnector('secret-token', { fetch: fake, now: () => Date.parse('2026-11-12T00:00:00Z') }).orders!();
    assert.equal(got.length, 51);
    assert.ok(urls.every((u) => u.startsWith('https://www.faire.com/external-api/v2/orders?') && !u.includes('secret-token')));
    assert.ok(headers.every((h) => h.get('x-faire-access-token') === 'secret-token'));
  });
  test('errors are codes only', async () => {
    const fake = (async () => new Response('token secret-token invalid', { status: 401 })) as typeof fetch;
    await assert.rejects(faireConnector('secret-token', { fetch: fake }).orders!(), (e: Error) => e.message === 'faire_unauthorized');
  });
});
