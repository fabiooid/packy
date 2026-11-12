// Serves one platform as a Packy connector (spec/connector-v1.md). Every response is checked against the spec
// before it leaves, so a mapping bug shows up here as an error instead of as wrong data in Packy.
import { timingSafeEqual, createHash } from 'node:crypto';
import { Hono } from 'hono';
import { parseBarcodes, parseOrders, parseProducts, SPEC, SpecError } from '../../spec/connector-v1.ts';
import type { Barcode, Capability, Order, Product } from '../../spec/connector-v1.ts';

export interface Handlers {
  orders?: () => Promise<Order[]>;
  products?: () => Promise<Product[]>;
  barcodes?: () => Promise<Barcode[]>;
}

const digest = (s: string) => createHash('sha256').update(s).digest();

/** Codes only. Platform errors can carry tokens or customer data, so their text never leaves the process. */
function errorCode(error: unknown): string {
  if (error instanceof SpecError) return 'spec_violation';
  const message = error instanceof Error ? error.message : '';
  return /^[a-z0-9_]+$/.test(message) ? message : 'platform_error';
}

export function connectorApp(name: string, handlers: Handlers, token: string): Hono {
  // Not strict: Packy asks for {base}/ and a mounted connector must answer it.
  const app = new Hono({ strict: false });
  const expected = digest(`Bearer ${token}`);
  app.use('*', async (c, next) => {
    if (!timingSafeEqual(digest(c.req.header('authorization') ?? ''), expected)) return c.json({ error: { code: 'unauthorized' } }, 401);
    c.header('cache-control', 'no-store');
    await next();
  });

  const provides = (['orders', 'products', 'barcodes'] as Capability[]).filter((k) => handlers[k]);
  app.get('/', (c) => c.json({ spec: SPEC, name, provides }));

  const route = <T>(path: Capability, key: string, run: () => Promise<T[]>, check: (body: unknown) => unknown) => {
    app.get(`/${path}`, async (c) => {
      try {
        const body = { spec: SPEC, [key]: await run() };
        check(body);
        return c.json(body);
      } catch (error) {
        const code = errorCode(error);
        console.error(`${name}/${path}: ${code}${error instanceof SpecError ? ` at ${error.path}` : ''}`);
        return c.json({ error: { code } }, 502);
      }
    });
  };
  if (handlers.orders) route('orders', 'orders', handlers.orders, parseOrders);
  if (handlers.products) route('products', 'products', handlers.products, parseProducts);
  if (handlers.barcodes) route('barcodes', 'barcodes', handlers.barcodes, parseBarcodes);
  return app;
}
