import { serve } from '@hono/node-server';
import { readFileSync } from 'node:fs';
import { createApp } from './app.ts';
import { loadPolicies, replaceFeed } from './catalog.ts';
import { openDb } from './db.ts';
import { ficCatalog } from './sources/fic.ts';
import { fixtureSources } from './sources/fixture.ts';
import type { FixtureControl } from './sources/fixture.ts';
import { shopifySources } from './sources/shopify.ts';
import type { BarcodeEntry, Sources } from './types.ts';

const env = process.env;
const fixtures = env.PACKY_FIXTURES === '1';
if (fixtures && env.NODE_ENV === 'production') throw new Error('Fixture mode must not run in production.');

const db = openDb(env.PACKY_DB ?? 'data/packy.db');
const dataDir = new URL('../../data/', import.meta.url);
const policies = loadPolicies(new URL('policies.json', dataDir).pathname);

let fixture: FixtureControl | null = null;
let sources: Sources;
if (fixtures) {
  fixture = fixtureSources();
  sources = fixture.sources;
} else {
  const shopDomain = env.SHOPIFY_SHOP_DOMAIN;
  const hasShopifyCreds = Boolean(env.SHOPIFY_ADMIN_ACCESS_TOKEN || (env.SHOPIFY_CLIENT_ID && env.SHOPIFY_CLIENT_SECRET));
  const shopify = shopDomain && hasShopifyCreds
    ? shopifySources({ shopDomain, accessToken: env.SHOPIFY_ADMIN_ACCESS_TOKEN || undefined, clientId: env.SHOPIFY_CLIENT_ID, clientSecret: env.SHOPIFY_CLIENT_SECRET })
    : null;
  if (env.FATTURE_IN_CLOUD_API_KEY && !env.FIC_COMPANY_ID) {
    throw new Error('FIC_COMPANY_ID is required when FATTURE_IN_CLOUD_API_KEY is set.');
  }
  const artifact = JSON.parse(readFileSync(new URL('barcode-map.json', dataDir), 'utf8')) as { entries: BarcodeEntry[] };
  replaceFeed(db, 'marketplace_register', artifact.entries.filter((e) => e.provenance === 'marketplace_register'), Date.now());
  sources = {
    fixture: false,
    orders: shopify ? [shopify.orders] : [],
    catalog: env.FATTURE_IN_CLOUD_API_KEY && env.FIC_COMPANY_ID
      ? ficCatalog(env.FATTURE_IN_CLOUD_API_KEY, env.FIC_COMPANY_ID)
      : null,
    barcodes: shopify ? [shopify.barcodes] : [],
    notConnected: [
      ...(shopify ? [] : [{ name: 'shopify', reason: 'No credentials provisioned.' }]),
      { name: 'faire', reason: 'No authorized token.' },
      { name: 'ankorstore', reason: 'No authorized token.' },
      { name: 'orderchamp', reason: 'No authorized token.' },
    ],
  };
}

const port = Number(env.PORT ?? 8787);
serve({ fetch: createApp({ db, now: Date.now, policies, sources }, fixture).fetch, port, hostname: '0.0.0.0' });
console.log(`packy server on ${port}${fixtures ? ' (FIXTURE DATA)' : ''}`);
