import { Hono } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
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
    return c.json({ error: { code: 'server_error', message: 'Something went wrong. Nothing was recorded.' } }, 500);
  });

  app.get('/healthz', (c) => c.json({ ok: true }));

  const body = async (c: { req: { json: () => Promise<unknown> } }) => {
    const value = await c.req.json().catch(() => null);
    if (typeof value !== 'object' || value === null) throw new ApiError(400, 'bad_json', 'The request body was invalid.');
    return value as Record<string, unknown>;
  };
  const str = (v: unknown) => (typeof v === 'string' ? v : '');
  const num = (v: unknown) => {
    if (typeof v !== 'number') throw new ApiError(400, 'version_required', 'The request is missing the order version.');
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

  app.get('/v1/workload', (c) => c.json(packing.workload(ctx, c.get('user'))));
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
    return c.json(packing.recordScan(ctx, c.get('user'), c.req.param('id'), str(b.barcode), typeof b.symbology === 'string' ? b.symbology : null));
  });
  app.post('/v1/packs/:id/confirm', async (c) => {
    const b = await body(c);
    return c.json(packing.confirmUnit(ctx, c.get('user'), c.req.param('id'), str(b.scanId), str(b.actionId), num(b.version)));
  });
  app.post('/v1/packs/:id/units/:unitId/remove', async (c) => {
    const b = await body(c);
    return c.json(packing.removeUnit(ctx, c.get('user'), c.req.param('id'), c.req.param('unitId'), str(b.reason), str(b.actionId), num(b.version)));
  });
  app.post('/v1/packs/:id/discrepancies/:discrepancyId/resolve', async (c) => {
    const b = await body(c);
    return c.json(packing.resolveDiscrepancy(ctx, c.get('user'), c.req.param('id'), c.req.param('discrepancyId'), str(b.resolution), str(b.actionId), num(b.version)));
  });
  for (const [path, action] of Object.entries({
    reconcile: packing.reconcile, takeover: packing.takeOver, complete: packing.complete, reopen: packing.reopen, release: packing.release,
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
        if (order) { order.eligible = false; order.ineligibleReason = 'Cancelled at the source.'; }
      }
      if (b.action === 'outage') fixture.failing = b.on === true;
      return c.json({ ok: true });
    });
  }
  return app;
}
