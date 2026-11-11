import type { BarcodeEntry, BarcodeFeed, NonPhysicalRow, OrderSource, SourceLine, SourceOrder } from '../types.ts';

const API_VERSION = '2026-10';
const ELIGIBLE_PAYMENT = new Set(['PAID', 'PARTIALLY_REFUNDED']);
const COUNTED_FO = new Set(['OPEN', 'IN_PROGRESS', 'ON_HOLD', 'SCHEDULED', 'INCOMPLETE']);
const HOLDING_FO = new Set(['ON_HOLD', 'SCHEDULED', 'INCOMPLETE']);

// Validated against the live store with the read-only Admin connector on 2026-11-07.
export const ORDERS_QUERY = `query Orders($after: String) {
  orders(first: 50, after: $after, sortKey: CREATED_AT, reverse: true, query: "status:open") {
    nodes {
      id name createdAt updatedAt cancelledAt closed displayFinancialStatus
      shippingAddress { name }
      lineItems(first: 100) {
        nodes { id sku title variantTitle quantity currentQuantity requiresShipping }
        pageInfo { hasNextPage }
      }
      fulfillmentOrders(first: 20) {
        nodes { status lineItems(first: 100) { nodes { remainingQuantity lineItem { id } } pageInfo { hasNextPage } } }
        pageInfo { hasNextPage }
      }
      shippingLines(first: 10) { nodes { title } }
    }
    pageInfo { hasNextPage endCursor }
  }
}`;

export const VARIANTS_QUERY = `query Variants($after: String) {
  productVariants(first: 100, after: $after, query: "product_status:active") {
    nodes { id sku barcodes(first: 20) { nodes { value } } }
    pageInfo { hasNextPage endCursor }
  }
}`;

interface ShopifyLineItem {
  id: string; sku: string | null; title: string; variantTitle: string | null;
  quantity: number; currentQuantity: number; requiresShipping: boolean;
}

export interface ShopifyOrderNode {
  id: string; name: string; createdAt: string; updatedAt: string; cancelledAt: string | null; closed: boolean;
  displayFinancialStatus: string | null;
  shippingAddress?: { name: string | null } | null;
  lineItems: { nodes: ShopifyLineItem[]; pageInfo?: { hasNextPage: boolean } };
  fulfillmentOrders: {
    nodes: { status: string; lineItems: { nodes: { remainingQuantity: number; lineItem: { id: string } }[]; pageInfo?: { hasNextPage: boolean } } }[];
    pageInfo?: { hasNextPage: boolean };
  };
  shippingLines: { nodes: { title: string }[] };
}

/** Pure mapping, so eligibility rules are testable without network access. */
export function normalizeOrder(node: ShopifyOrderNode): SourceOrder {
  const remaining = new Map<string, number>();
  let held = false;
  for (const fo of node.fulfillmentOrders.nodes) {
    if (!COUNTED_FO.has(fo.status)) continue;
    for (const item of fo.lineItems.nodes) {
      if (item.remainingQuantity > 0 && HOLDING_FO.has(fo.status)) held = true;
      remaining.set(item.lineItem.id, (remaining.get(item.lineItem.id) ?? 0) + item.remainingQuantity);
    }
  }

  const lines: SourceLine[] = [];
  for (const item of node.lineItems.nodes) {
    const base = { lineId: item.id, sku: item.sku, title: item.title, variantTitle: item.variantTitle };
    if (item.requiresShipping) {
      const required = remaining.get(item.id) ?? 0;
      if (required > 0) lines.push({ ...base, required, kind: 'physical', kindReason: null });
    } else if (item.currentQuantity > 0) {
      lines.push({
        ...base, required: item.currentQuantity, kind: 'uncertain',
        kindReason: 'Per Shopify questa riga non va spedita, ma non è detto che non sia un prodotto fisico.',
      });
    }
  }

  node.shippingLines.nodes.forEach((s, index) => {
    lines.push({
      lineId: `shipping:${index}:${s.title}`, sku: null, title: s.title, variantTitle: null,
      required: 1, kind: 'physical', kindReason: null,
    });
  });
  const nonPhysical: NonPhysicalRow[] = [];
  const truncated = Boolean(
    node.lineItems.pageInfo?.hasNextPage || node.fulfillmentOrders.pageInfo?.hasNextPage ||
    node.fulfillmentOrders.nodes.some((fo) => fo.lineItems.pageInfo?.hasNextPage),
  );

  let ineligibleReason: string | null = null;
  if (node.cancelledAt) ineligibleReason = 'Annullato alla fonte.';
  else if (node.closed) ineligibleReason = 'Chiuso alla fonte.';
  else if (truncated) ineligibleReason = 'Ordine troppo grande per essere letto per intero, quindi non si può certificare.';
  else if (!ELIGIBLE_PAYMENT.has(node.displayFinancialStatus ?? '')) ineligibleReason = `Stato del pagamento: ${node.displayFinancialStatus ?? 'sconosciuto'}.`;
  else if (held) ineligibleReason = 'Evasione sospesa o programmata alla fonte.';
  else if (lines.length === 0) ineligibleReason = 'In questo ordine non resta nulla di fisico da spedire.';

  return {
    source: 'shopify', orderId: node.id, reference: node.name, recipient: node.shippingAddress?.name ?? null,
    createdAt: node.createdAt, sourceUpdatedAt: node.updatedAt,
    eligible: ineligibleReason === null, ineligibleReason, lines, nonPhysical,
  };
}

export interface ShopifyConfig {
  shopDomain: string;
  accessToken?: string;
  clientId?: string;
  clientSecret?: string;
}

class ShopifyClient {
  private token: string | null;
  private readonly config: ShopifyConfig;

  constructor(config: ShopifyConfig) {
    this.config = config;
    this.token = config.accessToken ?? null;
  }

  private async fetchToken(): Promise<string> {
    const res = await fetch(`https://${this.config.shopDomain}/admin/oauth/access_token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: this.config.clientId ?? '',
        client_secret: this.config.clientSecret ?? '',
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) throw new Error(`shopify_auth_${res.status}`);
    return ((await res.json()) as { access_token: string }).access_token;
  }

  async query<T>(query: string, after: string | null): Promise<T> {
    this.token ??= await this.fetchToken();
    const res = await fetch(`https://${this.config.shopDomain}/admin/api/${API_VERSION}/graphql.json`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-shopify-access-token': this.token },
      body: JSON.stringify({ query, variables: { after } }),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 401 && this.config.clientId) this.token = null;
    if (!res.ok) throw new Error(`shopify_http_${res.status}`);
    const body = (await res.json()) as { data?: T; errors?: unknown };
    if (body.errors || !body.data) throw new Error('shopify_graphql_error');
    return body.data;
  }

  async collectPages<T, N>(
    query: string,
    pick: (data: T) => { nodes: N[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } },
  ): Promise<N[]> {
    const nodes: N[] = [];
    let after: string | null = null;
    do {
      const page = pick(await this.query<T>(query, after));
      nodes.push(...page.nodes);
      after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
    } while (after);
    return nodes;
  }
}

export function shopifySources(config: ShopifyConfig): { orders: OrderSource; barcodes: BarcodeFeed } {
  const client = new ShopifyClient(config);
  return {
    orders: {
      name: 'shopify',
      async pull() {
        type Page = { orders: { nodes: ShopifyOrderNode[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } } };
        const nodes = await client.collectPages<Page, ShopifyOrderNode>(ORDERS_QUERY, (data) => data.orders);
        return nodes.map(normalizeOrder);
      },
    },
    barcodes: {
      name: 'shopify_variant',
      async pull() {
        type Variant = { id: string; sku: string | null; barcodes: { nodes: { value: string }[] } };
        type Page = { productVariants: { nodes: Variant[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } } };
        const nodes = await client.collectPages<Page, Variant>(VARIANTS_QUERY, (data) => data.productVariants);
        const entries: BarcodeEntry[] = [];
        for (const v of nodes) {
          if (!v.sku) continue;
          for (const b of v.barcodes.nodes) entries.push({ barcode: b.value, codice: v.sku, provenance: 'shopify_variant', sourceRef: v.id });
        }
        return entries;
      },
    },
  };
}
