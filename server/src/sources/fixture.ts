import type { BarcodeEntry, CatalogProduct, SourceOrder, Sources } from '../types.ts';

/**
 * Local test data only. Every response from a fixture server is flagged, and the app shows a banner.
 * MS001, MS002, their EANs and the MS024 and MS040 barcodes come from the brief. The other names are placeholders.
 */
const physical = (lineId: string, sku: string | null, title: string, required: number) =>
  ({ lineId, sku, title, variantTitle: null, required, kind: 'physical' as const, kindReason: null });

const shipping = (lineId: string, title: string) => ({ ...physical(lineId, null, title, 1), shipping: true });

const order = (id: string, reference: string, partial: Partial<SourceOrder>): SourceOrder => ({
  source: 'fixture', orderId: id, reference, recipient: 'Cliente di prova',
  createdAt: '2026-11-07T09:00:00Z', sourceUpdatedAt: '2026-11-07T09:00:00Z',
  eligible: true, ineligibleReason: null, lines: [], nonPhysical: [], ...partial,
});

export function fixtureOrders(): SourceOrder[] {
  return [
    order('f1', '#FIX-1001', {
      lines: [physical('f1-a', 'MS001', 'Sapone mani piccolo', 3), physical('f1-b', 'MS024', 'Candela', 1), shipping('f1-ship', 'Express')],
    }),
    order('f2', '#FIX-1002 free sample', {
      lines: [physical('f2-a', 'MS002', 'Sapone mani grande', 1), physical('f2-b', 'MS040', 'SAMPLE gratis', 1), shipping('f2-ship', 'Standard')],
    }),
    order('f3', '#FIX-1003 blank SKU', {
      lines: [
        physical('f3-a', null, 'Discovery Set / Profumi in Olio', 1),
        physical('f3-b', 'MS001', 'Sapone mani', 1),
        physical('f3-promo', null, 'Materiale promozionale', 2),
      ],
    }),
    order('f4', '#FIX-1004 kit', { lines: [physical('f4-a', 'MS010', 'Travel Kit', 1)] }),
    order('f5', '#FIX-1005 uncertain row', {
      lines: [
        physical('f5-a', 'MS002', 'Sapone mani', 1),
        { lineId: 'f5-b', sku: null, title: 'Omaggio', variantTitle: null, required: 1, kind: 'uncertain', kindReason: 'La fonte non dice se questa riga è un prodotto fisico.' },
      ],
    }),
    order('f6', '#FIX-1006 unpaid', { eligible: false, ineligibleReason: 'Stato del pagamento: PENDING.', lines: [physical('f6-a', 'MS001', 'Sapone mani', 1)] }),
  ];
}

export const FIXTURE_CATALOG: CatalogProduct[] = [
  { code: 'MS001', name: 'Cardamomo Sapone Mani 250ml', ficId: 'fixture-1' },
  { code: 'MS002', name: 'Cardamomo Sapone Mani 500ml', ficId: 'fixture-2' },
  { code: 'MS010', name: 'Travel Kit', ficId: 'fixture-10' },
  { code: 'MS024', name: 'Prodotto di prova MS024', ficId: 'fixture-24' },
  { code: 'MS040', name: 'Prodotto di prova MS040', ficId: 'fixture-40' },
];

export const FIXTURE_BARCODES: BarcodeEntry[] = [
  { barcode: '8050038450997', codice: 'MS001', provenance: 'fixture', sourceRef: null },
  { barcode: '8050038450980', codice: 'MS002', provenance: 'fixture', sourceRef: null },
  { barcode: '0806812399109', codice: 'MS024', provenance: 'fixture', sourceRef: null },
  { barcode: '0806812399192', codice: 'MS040', provenance: 'fixture', sourceRef: null },
];

export interface FixtureControl {
  sources: Sources;
  orders: SourceOrder[];
  failing: boolean;
}

export function fixtureSources(): FixtureControl {
  const control: FixtureControl = {
    orders: fixtureOrders(),
    failing: false,
    sources: {
      fixture: true,
      orders: [{
        name: 'fixture',
        async pull() {
          if (control.failing) throw new Error('fixture_unavailable');
          return structuredClone(control.orders);
        },
      }],
      catalog: { name: 'fic', pull: async () => FIXTURE_CATALOG },
      barcodes: [{ name: 'fixture', pull: async () => FIXTURE_BARCODES }],
      notConnected: [{ name: 'faire', reason: 'No authorized token.' }],
    },
  };
  return control;
}
