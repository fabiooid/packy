// Faire connector: translates Faire's brand orders (External API v2) into the Packy connector format.
// Read-only: GET requests only. Never accepts, ships or cancels anything.
//
// NOT YET CHECKED AGAINST A LIVE ACCOUNT. Field names come from Faire's v2 API as documented before this build;
// Faire's current docs could not be read here. Every field read is in FaireOrder below, and normalizeFaireOrder
// rejects shapes it does not understand (fails closed) instead of guessing. Check the first real pull.
import type { Order, OrderLine } from '../../spec/connector-v1.ts';
import type { Handlers } from './serve.ts';

const BASE = 'https://www.faire.com/external-api/v2';
const PAGE_SIZE = 50;
const MAX_PAGES = 100;
/** Orders untouched for longer than this are not read. Open Faire orders change state well within it. */
const LOOKBACK_DAYS = 90;

/** States still to pack. PRE_TRANSIT: a label exists but nothing has moved, so the box may still be open. */
const PACKABLE = new Set(['PROCESSING', 'PRE_TRANSIT']);
/** Open, but not to pack now. Shown with the reason so nobody wonders where they are. */
const WAITING: Record<string, string> = {
  NEW: 'Da accettare su Faire.',
  BACKORDERED: 'In attesa di disponibilità su Faire.',
};

export interface FaireItem {
  id: string;
  product_id?: string | null;
  variant_id?: string | null;
  sku?: string | null;
  product_name?: string | null;
  variant_name?: string | null;
  quantity: number;
  includes_tester?: boolean | null;
  state?: string | null;
}

export interface FaireOrder {
  id: string;
  display_id?: string | null;
  state: string;
  created_at: string;
  updated_at: string;
  address?: { name?: string | null; company_name?: string | null } | null;
  items: FaireItem[];
}

/** Pure mapping, so the rules are testable without network access. Returns null for orders that are not open. */
export function normalizeFaireOrder(o: FaireOrder): Order | null {
  if (typeof o.id !== 'string' || typeof o.state !== 'string' || !Array.isArray(o.items)) throw new Error('faire_bad_response');
  const packable = PACKABLE.has(o.state);
  if (!packable && !(o.state in WAITING)) return null;

  const lines: OrderLine[] = [];
  for (const item of o.items) {
    if (typeof item.id !== 'string' || typeof item.quantity !== 'number') throw new Error('faire_bad_response');
    if (item.quantity < 1 || /CANCEL/i.test(item.state ?? '')) continue;
    const keys: OrderLine['keys'] = [];
    if (item.product_id) keys.push({ type: 'product_id', value: item.product_id });
    if (item.variant_id) keys.push({ type: 'variant_id', value: item.variant_id });
    const title = item.product_name?.trim() || 'Prodotto Faire';
    const variantTitle = item.variant_name?.trim() || null;
    lines.push({
      lineId: item.id, sku: item.sku?.trim() || null, title, variantTitle,
      required: item.quantity, kind: 'physical', kindReason: null, keys,
    });
    if (item.includes_tester) {
      // Faire marks a tester on the item. Whether it is an extra piece is not certain, so it is confirmed by hand.
      lines.push({
        lineId: `${item.id}:tester`, sku: null, title: `Tester: ${title}`, variantTitle,
        required: 1, kind: 'uncertain', kindReason: 'Faire indica un tester per questo prodotto. Controlla se va nella scatola.',
      });
    }
  }

  let ineligibleReason: string | null = WAITING[o.state] ?? null;
  if (!ineligibleReason && lines.length === 0) ineligibleReason = 'Nessun prodotto da spedire.';
  return {
    orderId: o.id,
    reference: o.display_id ? `#${o.display_id}` : o.id,
    recipient: o.address?.name?.trim() || o.address?.company_name?.trim() || null,
    createdAt: o.created_at,
    sourceUpdatedAt: o.updated_at,
    eligible: ineligibleReason === null,
    ineligibleReason,
    lines,
    nonPhysical: [],
  };
}

type Fetch = typeof fetch;

export function faireConnector(accessToken: string, options: { fetch?: Fetch; now?: () => number } = {}): Handlers {
  const fetchImpl = options.fetch ?? fetch;
  const now = options.now ?? Date.now;
  return {
    async orders() {
      const since = new Date(now() - LOOKBACK_DAYS * 86_400_000).toISOString();
      const orders: Order[] = [];
      for (let page = 1; page <= MAX_PAGES; page++) {
        const url = `${BASE}/orders?limit=${PAGE_SIZE}&page=${page}&updated_at_min=${encodeURIComponent(since)}`;
        const res = await fetchImpl(url, {
          headers: { 'X-FAIRE-ACCESS-TOKEN': accessToken, accept: 'application/json' },
          signal: AbortSignal.timeout(15_000),
          redirect: 'error',
        });
        if (res.status === 401 || res.status === 403) throw new Error('faire_unauthorized');
        if (res.status === 429) throw new Error('faire_rate_limited');
        if (!res.ok) throw new Error(`faire_http_${res.status}`);
        const body = (await res.json().catch(() => null)) as { orders?: unknown } | null;
        if (!body || !Array.isArray(body.orders)) throw new Error('faire_bad_response');
        for (const raw of body.orders as FaireOrder[]) {
          const o = normalizeFaireOrder(raw);
          if (o) orders.push(o);
        }
        if (body.orders.length < PAGE_SIZE) return orders;
      }
      // Too many pages: an incomplete list would make orders look closed, so fail instead.
      throw new Error('faire_too_many_orders');
    },
  };
}
