// Packy connectors service. Holds the platform keys, so Packy itself never does.
// Each platform is mounted at /<name> only when its keys are set. Packy reads them through PACKY_CONNECTORS.
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { faireConnector } from './faire.ts';
import { fattureInCloudConnector } from './fattureincloud.ts';
import { connectorApp } from './serve.ts';
import { shopifyConnector } from './shopify.ts';

const env = process.env;
const token = env.CONNECTOR_TOKEN ?? '';
if (token.length < 32) throw new Error('CONNECTOR_TOKEN must be set, at least 32 characters.');

const app = new Hono({ strict: false });
app.use('*', async (c, next) => {
  await next();
  c.header('strict-transport-security', 'max-age=31536000');
  c.header('x-content-type-options', 'nosniff');
});
app.get('/healthz', (c) => c.json({ ok: true }));
const mounted: string[] = [];

if (env.SHOPIFY_SHOP_DOMAIN && (env.SHOPIFY_ADMIN_ACCESS_TOKEN || (env.SHOPIFY_CLIENT_ID && env.SHOPIFY_CLIENT_SECRET))) {
  app.route('/shopify', connectorApp('shopify', shopifyConnector({
    shopDomain: env.SHOPIFY_SHOP_DOMAIN,
    accessToken: env.SHOPIFY_ADMIN_ACCESS_TOKEN || undefined,
    clientId: env.SHOPIFY_CLIENT_ID,
    clientSecret: env.SHOPIFY_CLIENT_SECRET,
  }), token));
  mounted.push('shopify');
}

if (env.FATTURE_IN_CLOUD_API_KEY) {
  if (!env.FIC_COMPANY_ID) throw new Error('FIC_COMPANY_ID is required when FATTURE_IN_CLOUD_API_KEY is set.');
  app.route('/fattureincloud', connectorApp('fattureincloud', fattureInCloudConnector(env.FATTURE_IN_CLOUD_API_KEY, env.FIC_COMPANY_ID), token));
  mounted.push('fattureincloud');
}

if (env.FAIRE_ACCESS_TOKEN) {
  app.route('/faire', connectorApp('faire', faireConnector(env.FAIRE_ACCESS_TOKEN), token));
  mounted.push('faire');
}

const port = Number(env.PORT ?? 8790);
serve({ fetch: app.fetch, port, hostname: '0.0.0.0' });
console.log(`packy connectors on ${port}: ${mounted.join(', ') || 'none (no platform keys set)'}`);
