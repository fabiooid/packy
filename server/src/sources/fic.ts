import type { CatalogProduct, CatalogSource } from '../types.ts';

/** Read-only pull of FIC Prodotti e servizi. `code` is the Codice and is never rewritten. */
export function ficCatalog(apiKey: string, companyId: string): CatalogSource {
  return {
    name: 'fic',
    async pull() {
      const products: CatalogProduct[] = [];
      for (let page = 1; ; page++) {
        const res = await fetch(`https://api-v2.fattureincloud.it/c/${companyId}/products?per_page=100&page=${page}`, {
          headers: { authorization: `Bearer ${apiKey}`, accept: 'application/json' },
          signal: AbortSignal.timeout(10_000),
        });
        if (!res.ok) throw new Error(`fic_http_${res.status}`);
        const body: unknown = await res.json();
        if (typeof body !== 'object' || body === null) throw new Error('fic_bad_response');
        const pageBody = body as { data?: unknown; last_page?: unknown };
        if (!Array.isArray(pageBody.data) || typeof pageBody.last_page !== 'number') throw new Error('fic_bad_response');
        for (const item of pageBody.data) {
          if (typeof item !== 'object' || item === null) continue;
          const p = item as { id?: unknown; name?: unknown; code?: unknown };
          if (typeof p.code === 'string' && p.code && typeof p.name === 'string' && p.name) {
            products.push({ code: p.code, name: p.name, ficId: String(p.id) });
          }
        }
        if (page >= pageBody.last_page) return products;
      }
    },
  };
}
