// Packy reads every order source and the product list through connectors that follow spec/connector-v1.
// Nothing here knows any platform. A connector is a URL and a token, set as deployment variables.
import { parseBarcodes, parseManifest, parseOrders, parseProducts, SpecError } from '../../../spec/connector-v1.ts';
import type { Capability, Manifest } from '../../../spec/connector-v1.ts';
import { PRODUCTS_STATUS } from '../types.ts';
import type { BarcodeEntry, BarcodeFeed, CatalogSource, OrderSource, Sources } from '../types.ts';

export interface ConnectorConfig {
  name: string;
  url: string;
  token: string;
}

type Fetch = typeof fetch;
const TIMEOUT_MS = 20_000;
const NAME = /^[a-z0-9][a-z0-9_-]{0,39}$/;

/**
 * Reads PACKY_CONNECTORS="name=https://...,other=https://..." and PACKY_CONNECTOR_TOKEN_<NAME> for each.
 * Fails at startup on a malformed list, so a typo never looks like "no orders".
 */
export function connectorConfigFromEnv(env: Record<string, string | undefined>): ConnectorConfig[] {
  const list = (env.PACKY_CONNECTORS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const seen = new Set<string>();
  return list.map((entry) => {
    const eq = entry.indexOf('=');
    const name = entry.slice(0, eq).trim();
    const url = entry.slice(eq + 1).trim().replace(/\/+$/, '');
    if (eq < 1 || !NAME.test(name)) throw new Error(`PACKY_CONNECTORS: "${name || entry}" is not a valid name (lowercase letters, digits, - or _).`);
    if (seen.has(name)) throw new Error(`PACKY_CONNECTORS: "${name}" is listed twice.`);
    seen.add(name);
    let parsed: URL;
    try { parsed = new URL(url); } catch { throw new Error(`PACKY_CONNECTORS: the address for "${name}" is not a URL.`); }
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname) || parsed.hostname.endsWith('.internal');
    if (parsed.protocol !== 'https:' && !local) throw new Error(`PACKY_CONNECTORS: "${name}" must use https.`);
    const tokenVar = `PACKY_CONNECTOR_TOKEN_${name.toUpperCase().replace(/-/g, '_')}`;
    const token = env[tokenVar];
    if (!token) throw new Error(`${tokenVar} is required for connector "${name}".`);
    return { name, url, token };
  });
}

/** Errors become short codes. Response bodies, tokens and order data never reach logs. */
async function getJson(fetchImpl: Fetch, c: ConnectorConfig, path: string): Promise<unknown> {
  let res: Response;
  try {
    res = await fetchImpl(`${c.url}${path}`, {
      headers: { authorization: `Bearer ${c.token}`, accept: 'application/json' },
      signal: AbortSignal.timeout(TIMEOUT_MS),
      redirect: 'error', // a redirect would carry the token to another host
    });
  } catch (error) {
    throw new Error(error instanceof Error && error.name === 'TimeoutError' ? 'connector_timeout' : 'connector_unreachable');
  }
  if (res.status === 401 || res.status === 403) throw new Error('connector_unauthorized');
  if (!res.ok) throw new Error(`connector_http_${res.status}`);
  try {
    return await res.json();
  } catch {
    throw new Error('connector_bad_response');
  }
}

/** A response that breaks the spec is rejected whole. The field path is logged (never its value) so the connector can be fixed. */
function validated<T>(name: string, parse: (body: unknown) => T, body: unknown): T {
  try {
    return parse(body);
  } catch (error) {
    if (error instanceof SpecError) {
      console.error(`connector ${name}: connector_bad_response at ${error.path}`);
      throw new Error('connector_bad_response');
    }
    throw error;
  }
}

class Connector {
  manifest: Manifest | null = null;
  readonly config: ConnectorConfig;
  private readonly fetchImpl: Fetch;
  constructor(config: ConnectorConfig, fetchImpl: Fetch) {
    this.config = config;
    this.fetchImpl = fetchImpl;
  }

  async discover(): Promise<Manifest> {
    const m = validated(this.config.name, parseManifest, await getJson(this.fetchImpl, this.config, '/'));
    if (m.name !== this.config.name) throw new Error('connector_name_mismatch');
    this.manifest = m;
    return m;
  }

  provides(c: Capability): boolean {
    return this.manifest?.provides.includes(c) ?? false;
  }

  get = (path: string) => getJson(this.fetchImpl, this.config, path);
}

/**
 * Builds Packy's sources from connectors. Each refresh first reads every manifest, so a connector can start
 * providing something new without a Packy restart. One connector provides the product list: the one named in
 * PACKY_PRODUCTS_FROM, or the only one that offers products.
 */
export function connectorSources(
  configs: ConnectorConfig[],
  options: { productsFrom?: string; fetch?: Fetch } = {},
): Sources {
  const fetchImpl = options.fetch ?? fetch;
  const connectors = configs.map((c) => new Connector(c, fetchImpl));
  if (options.productsFrom && !connectors.some((c) => c.config.name === options.productsFrom)) {
    throw new Error(`PACKY_PRODUCTS_FROM: "${options.productsFrom}" is not in PACKY_CONNECTORS.`);
  }

  const orderSource = (c: Connector): OrderSource => ({
    name: c.config.name,
    async pull() {
      const body = validated(c.config.name, parseOrders, await c.get('/orders'));
      return body.orders.map((o) => ({ ...o, source: c.config.name }));
    },
  });
  const barcodeFeed = (c: Connector): BarcodeFeed => ({
    name: c.config.name,
    async pull() {
      const body = validated(c.config.name, parseBarcodes, await c.get('/barcodes'));
      return body.barcodes.map((b): BarcodeEntry => ({ barcode: b.barcode, codice: b.code, provenance: c.config.name, sourceRef: b.sourceRef }));
    },
  });
  const catalogSource = (c: Connector): CatalogSource => ({
    name: PRODUCTS_STATUS,
    async pull() {
      return validated(c.config.name, parseProducts, await c.get('/products')).products;
    },
  });

  const sources: Sources = {
    fixture: false,
    orders: [],
    catalog: null,
    barcodes: [],
    notConnected: [],
    async prepare() {
      const failed: { name: string; code: string }[] = [];
      await Promise.all(connectors.map(async (c) => {
        try {
          await c.discover();
        } catch (error) {
          // Keep what it offered last time, so a blip still shows the order source as unavailable, not gone.
          const code = error instanceof Error && /^[a-z0-9_]+$/.test(error.message) ? error.message : 'connector_unreachable';
          failed.push({ name: c.config.name, code });
        }
      }));
      const known = connectors.filter((c) => c.manifest);
      sources.orders = known.filter((c) => c.provides('orders')).map(orderSource);
      sources.barcodes = known.filter((c) => c.provides('barcodes')).map(barcodeFeed);
      const productConnectors = options.productsFrom
        ? known.filter((c) => c.config.name === options.productsFrom && c.provides('products'))
        : known.filter((c) => c.provides('products'));
      sources.catalog = productConnectors.length === 1 ? catalogSource(productConnectors[0]) : null;
      if (productConnectors.length > 1) console.error('connectors: more than one offers products; set PACKY_PRODUCTS_FROM');
      return failed;
    },
  };
  return sources;
}
