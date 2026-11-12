import { readFileSync } from 'node:fs';
import { Hono } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import { ADMIN_CSP, ADMIN_HTML, ADMIN_JS } from './admin-page.ts';
import { authenticate, login, logout } from './auth.ts';
import * as packing from './pack.ts';
import type { Ctx } from './pack.ts';
import { refreshAll } from './refresh.ts';
import { ApiError } from './types.ts';
import type { User } from './types.ts';
import type { FixtureControl } from './sources/fixture.ts';

type Env = { Variables: { user: User } };

export function createApp(ctx: Ctx, fixture: FixtureControl | null = null): Hono<Env> {
  const app = new Hono<Env>();
  let refreshing: Promise<void> | null = null;
  const refresh = async () => {
    refreshing ??= refreshAll(ctx.db, ctx.sources, ctx.now).finally(() => { refreshing = null; });
    await refreshing;
  };

  app.onError((error, c) => {
    if (error instanceof ApiError) {
      return c.json({ error: { code: error.code, message: error.message }, ...error.extra }, error.status as ContentfulStatusCode);
    }
    console.error('unhandled_error', error instanceof Error ? error.name : 'unknown');
    return c.json({ error: { code: 'server_error', message: 'Errore del server. Non registrato.' } }, 500);
  });

  app.get('/healthz', (c) => c.json({ ok: true }));

  // Read-only web dashboard. The page itself holds no data; it signs in and reads /v1/admin/completed.
  const adminHeaders = { 'content-security-policy': ADMIN_CSP, 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'cache-control': 'no-store' };
  const adminAsset = (name: string, type: string) => {
    const bytes = readFileSync(new URL(`./admin-assets/${name}`, import.meta.url));
    return (c: { body: (data: Uint8Array, status?: 200, headers?: Record<string, string>) => Response }) =>
      c.body(bytes, 200, { ...adminHeaders, 'content-type': type, 'cache-control': 'public, max-age=86400' });
  };
  app.get('/admin', (c) => c.html(ADMIN_HTML, 200, adminHeaders));
  app.get('/admin/app.js', (c) => c.body(ADMIN_JS, 200, { ...adminHeaders, 'content-type': 'text/javascript; charset=utf-8' }));
  app.get('/admin/logo.png', adminAsset('logo.png', 'image/png'));
  app.get('/admin/favicon.png', adminAsset('favicon.png', 'image/png'));
  app.get('/admin/favicon.ico', adminAsset('favicon.ico', 'image/x-icon'));

  const body = async (c: { req: { json: () => Promise<unknown> } }) => {
    const value = await c.req.json().catch(() => null);
    if (typeof value !== 'object' || value === null) throw new ApiError(400, 'bad_json', 'La richiesta non è valida.');
    return value as Record<string, unknown>;
  };
  const str = (v: unknown) => (typeof v === 'string' ? v : '');
  const num = (v: unknown) => {
    if (typeof v !== 'number') throw new ApiError(400, 'version_required', 'Alla richiesta manca la versione dell\'ordine.');
    return v;
  };

  app.post('/v1/auth/login', async (c) => {
    const b = await body(c);
    return c.json(await login(ctx.db, str(b.username), str(b.password), ctx.now()));
  });

  // Everything below requires a valid server-side session.
  app.use('/v1/*', async (c, next) => {
    c.set('user', authenticate(ctx.db, c.req.header('authorization'), ctx.now()));
    await next();
  });

  app.post('/v1/auth/logout', (c) => {
    logout(ctx.db, c.req.header('authorization'));
    return c.json({ ok: true });
  });

  // The app's "Imballati" tab: the same read-only feed as the dashboard.
  app.get('/v1/packed', (c) => {
    c.header('cache-control', 'no-store');
    return c.json(packing.completedOrders(ctx));
  });
  app.get('/v1/admin/completed', (c) => {
    c.header('cache-control', 'no-store');
    return c.json(packing.completedOrders(ctx));
  });
  app.get('/v1/workload',(c) => c.json(packing.workload(ctx, c.get('user'))));
  app.post('/v1/refresh', async (c) => {
    await refresh();
    return c.json(packing.workload(ctx, c.get('user')));
  });

  app.post('/v1/packs', async (c) => {
    const b = await body(c);
    return c.json(packing.openPack(ctx, c.get('user'), str(b.source), str(b.orderId)));
  });
  app.get('/v1/packs/:id', (c) => c.json(packing.viewPack(ctx, c.req.param('id'), c.get('user'))));
  app.post('/v1/packs/:id/scans', async (c) => {
    const b = await body(c);
    return c.json(packing.recordScan(ctx, c.get('user'), c.req.param('id'), str(b.barcode), typeof b.symbology === 'string' ? b.symbology : null, typeof b.lineId === 'string' ? b.lineId : null));
  });
  app.post('/v1/packs/:id/confirm', async (c) => {
    const b = await body(c);
    return c.json(packing.confirmUnit(ctx, c.get('user'), c.req.param('id'), str(b.scanId), str(b.actionId), num(b.version), typeof b.lineId === 'string' && b.lineId ? b.lineId : null));
  });
  app.post('/v1/packs/:id/units/:unitId/remove', async (c) => {
    const b = await body(c);
    return c.json(packing.removeUnit(ctx, c.get('user'), c.req.param('id'), c.req.param('unitId'), str(b.reason), str(b.actionId), num(b.version)));
  });
  app.post('/v1/packs/:id/lines/:lineId/short', async (c) => {
    const b = await body(c);
    return c.json(packing.markShort(ctx, c.get('user'), c.req.param('id'), c.req.param('lineId'), typeof b.quantity === 'number' ? b.quantity : -1, str(b.actionId), num(b.version)));
  });
  app.post('/v1/packs/:id/discrepancies/:discrepancyId/resolve', async (c) => {
    const b = await body(c);
    return c.json(packing.resolveDiscrepancy(ctx, c.get('user'), c.req.param('id'), c.req.param('discrepancyId'), str(b.resolution), str(b.actionId), num(b.version)));
  });
  for (const [path, action] of Object.entries({
    reconcile: packing.reconcile, takeover: packing.takeOver, restart: packing.restart, complete: packing.complete, reopen: packing.reopen, release: packing.release,
  })) {
    app.post(`/v1/packs/:id/${path}`, async (c) => {
      const b = await body(c);
      return c.json(action(ctx, c.get('user'), c.req.param('id'), str(b.actionId), num(b.version)));
    });
  }

  // Fixture servers only, so order changes and outages can be shown in the Simulator.
  if (fixture) {
    app.post('/v1/dev/fixture', async (c) => {
      const b = await body(c);
      if (b.action === 'reduce') {
        const line = fixture.orders.find((o) => o.orderId === str(b.orderId))?.lines[0];
        if (line) line.required = Math.max(1, line.required - 1);
      }
      if (b.action === 'cancel') {
        const order = fixture.orders.find((o) => o.orderId === str(b.orderId));
        if (order) { order.eligible = false; order.ineligibleReason = 'Annullato alla fonte.'; }
      }
      if (b.action === 'outage') fixture.failing = b.on === true;
      return c.json({ ok: true });
    });
  }
  return app;
}
