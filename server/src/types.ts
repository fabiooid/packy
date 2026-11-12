export type LineKind = 'physical' | 'uncertain';

/** One standardized source row that may need packing. Nonphysical rows are kept apart in `nonPhysical`. */
export interface SourceLine {
  lineId: string;
  sku: string | null;
  title: string;
  variantTitle: string | null;
  required: number;
  kind: LineKind;
  kindReason: string | null;
  /** A shipping method row. It is confirmed by hand (label on the box) but is not a piece in the box. */
  shipping?: boolean;
  /** The source's own ids for the product (a marketplace product or variant id...). Matched through product links. */
  keys?: { type: ProductKeyType; value: string }[];
}

export type ProductKeyType = 'sku' | 'product_id' | 'variant_id';

/** "This source calls our product <codice> by <key>". Loaded once from data/product-links.json. */
export interface ProductLink {
  source: string;
  keyType: ProductKeyType;
  key: string;
  codice: string;
}

export interface NonPhysicalRow {
  title: string;
  reason: string;
}

export interface SourceOrder {
  source: string;
  orderId: string;
  reference: string;
  recipient: string | null;
  createdAt: string;
  sourceUpdatedAt: string;
  eligible: boolean;
  ineligibleReason: string | null;
  lines: SourceLine[];
  nonPhysical: NonPhysicalRow[];
}

export interface OrderSource {
  name: string;
  pull(): Promise<SourceOrder[]>;
}

/** Status key of the product list, whichever connector provides it. */
export const PRODUCTS_STATUS = 'products';

export interface CatalogProduct {
  code: string;
  name: string;
  externalId: string | null;
}

export interface CatalogSource {
  name: string;
  pull(): Promise<CatalogProduct[]>;
}

export interface BarcodeEntry {
  barcode: string;
  codice: string;
  provenance: string;
  sourceRef: string | null;
}

export interface BarcodeFeed {
  name: string;
  pull(): Promise<BarcodeEntry[]>;
}

export interface Sources {
  orders: OrderSource[];
  catalog: CatalogSource | null;
  barcodes: BarcodeFeed[];
  /** Known sources with no authorized access. Reported as not connected, never as empty. */
  notConnected: { name: string; reason: string }[];
  /** Runs before each refresh. Connectors read their manifests here. Returns sources that could not be reached. */
  prepare?: () => Promise<{ name: string; code: string }[]>;
  fixture: boolean;
}

export interface User {
  id: number;
  username: string;
  displayName: string;
}

export class ApiError extends Error {
  status: number;
  code: string;
  extra: Record<string, unknown>;
  constructor(status: number, code: string, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}
