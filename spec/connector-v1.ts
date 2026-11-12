// Packy connector contract, version 1. Shared by Packy (which reads connectors) and by connectors (which serve it).
// Packy itself knows no platform. A connector translates one platform (Shopify, Faire, an ERP...) into these shapes.
// See spec/connector-v1.md for the HTTP side. This file has no dependencies so any connector can copy or import it.

export const SPEC = 'packy-connector/1';

export type Capability = 'orders' | 'products' | 'barcodes';

/** GET {base}/ */
export interface Manifest {
  spec: typeof SPEC;
  /** Short lowercase name, for example "shopify". Used as the order source name and in product links. */
  name: string;
  provides: Capability[];
}

export type LineKind = 'physical' | 'uncertain';
export type KeyType = 'sku' | 'product_id' | 'variant_id';

export interface OrderLine {
  /** Stable within the order. */
  lineId: string;
  /** Exact text, leading zeroes kept. null when the platform has none. */
  sku: string | null;
  title: string;
  variantTitle: string | null;
  /** Pieces still to pack. Whole number, at least 1. */
  required: number;
  /** "uncertain" when the platform cannot say whether this is a physical item. */
  kind: LineKind;
  kindReason: string | null;
  /** A shipping method row: confirmed by hand (label on the box), never counted as a piece. */
  shipping?: boolean;
  /** The platform's own ids for the product, matched through Packy's product links. */
  keys?: { type: KeyType; value: string }[];
}

export interface Order {
  /** Stable id on the platform. */
  orderId: string;
  /** What people see, for example "#1042". */
  reference: string;
  recipient: string | null;
  /** ISO 8601. */
  createdAt: string;
  /** ISO 8601. Changes whenever the order changes. */
  sourceUpdatedAt: string;
  /** false when it must not be packed now (unpaid, cancelled, on hold...). Say why in ineligibleReason. */
  eligible: boolean;
  ineligibleReason: string | null;
  lines: OrderLine[];
  /** Rows that are never packed (fees, gift cards...). Shown for information only. */
  nonPhysical: { title: string; reason: string }[];
}

export interface Product {
  /** Your product code. Order lines match it by SKU or through product links. Exact text. */
  code: string;
  /** Full name exactly as in your product system, size included. */
  name: string;
  /** The product's id in that system, for troubleshooting. */
  externalId: string | null;
}

export interface Barcode {
  /** Exact text: EAN, UPC... leading zeroes kept. */
  barcode: string;
  /** Product code it belongs to. */
  code: string;
  /** Where it came from, for troubleshooting (a variant id, a file name...). */
  sourceRef: string | null;
}

/** GET {base}/orders: the open orders, newest first or in any order. */
export interface OrdersResponse { spec: typeof SPEC; orders: Order[] }
/** GET {base}/products: the whole product list, every time. */
export interface ProductsResponse { spec: typeof SPEC; products: Product[] }
/** GET {base}/barcodes: every barcode the connector knows, every time. */
export interface BarcodesResponse { spec: typeof SPEC; barcodes: Barcode[] }

// ---- Validation. Packy rejects the whole response if anything is off and keeps the last good data. ----

export class SpecError extends Error {
  readonly path: string;
  constructor(path: string, problem: string) {
    super(`${path}: ${problem}`);
    this.path = path;
  }
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
function obj(v: unknown, path: string): Obj {
  if (!isObj(v)) throw new SpecError(path, 'must be an object');
  return v;
}
function str(o: Obj, key: string, path: string, opts: { nullable?: boolean; nonEmpty?: boolean } = {}): string | null {
  const v = o[key];
  if (v === null && opts.nullable) return null;
  if (typeof v !== 'string') throw new SpecError(`${path}.${key}`, opts.nullable ? 'must be a string or null' : 'must be a string');
  if (opts.nonEmpty && v.trim() === '') throw new SpecError(`${path}.${key}`, 'must not be empty');
  return v;
}
function bool(o: Obj, key: string, path: string): boolean {
  if (typeof o[key] !== 'boolean') throw new SpecError(`${path}.${key}`, 'must be true or false');
  return o[key] as boolean;
}
function arr(o: Obj, key: string, path: string): unknown[] {
  if (!Array.isArray(o[key])) throw new SpecError(`${path}.${key}`, 'must be a list');
  return o[key] as unknown[];
}
function spec(o: Obj, path: string): void {
  if (o.spec !== SPEC) throw new SpecError(`${path}.spec`, `must be "${SPEC}"`);
}
const isoDate = (s: string) => !Number.isNaN(Date.parse(s));
const NAME = /^[a-z0-9][a-z0-9_-]{0,39}$/;

export function parseManifest(body: unknown): Manifest {
  const o = obj(body, 'manifest');
  spec(o, 'manifest');
  const name = str(o, 'name', 'manifest', { nonEmpty: true })!;
  if (!NAME.test(name)) throw new SpecError('manifest.name', 'must be lowercase letters, digits, - or _');
  const provides = arr(o, 'provides', 'manifest').map((c, i) => {
    if (c !== 'orders' && c !== 'products' && c !== 'barcodes') throw new SpecError(`manifest.provides[${i}]`, 'must be orders, products or barcodes');
    return c as Capability;
  });
  return { spec: SPEC, name, provides };
}

function parseLine(v: unknown, path: string): OrderLine {
  const o = obj(v, path);
  const required = o.required;
  if (typeof required !== 'number' || !Number.isInteger(required) || required < 1) throw new SpecError(`${path}.required`, 'must be a whole number of at least 1');
  if (o.kind !== 'physical' && o.kind !== 'uncertain') throw new SpecError(`${path}.kind`, 'must be physical or uncertain');
  const line: OrderLine = {
    lineId: str(o, 'lineId', path, { nonEmpty: true })!,
    sku: str(o, 'sku', path, { nullable: true }),
    title: str(o, 'title', path)!,
    variantTitle: str(o, 'variantTitle', path, { nullable: true }),
    required,
    kind: o.kind,
    kindReason: str(o, 'kindReason', path, { nullable: true }),
  };
  if (o.shipping !== undefined) {
    if (typeof o.shipping !== 'boolean') throw new SpecError(`${path}.shipping`, 'must be true or false');
    line.shipping = o.shipping;
  }
  if (o.keys !== undefined) {
    line.keys = arr(o, 'keys', path).map((k, i) => {
      const ko = obj(k, `${path}.keys[${i}]`);
      if (ko.type !== 'sku' && ko.type !== 'product_id' && ko.type !== 'variant_id') throw new SpecError(`${path}.keys[${i}].type`, 'must be sku, product_id or variant_id');
      return { type: ko.type, value: str(ko, 'value', `${path}.keys[${i}]`, { nonEmpty: true })! };
    });
  }
  return line;
}

function parseOrder(v: unknown, path: string): Order {
  const o = obj(v, path);
  const createdAt = str(o, 'createdAt', path)!;
  const sourceUpdatedAt = str(o, 'sourceUpdatedAt', path)!;
  if (!isoDate(createdAt)) throw new SpecError(`${path}.createdAt`, 'must be an ISO 8601 date');
  if (!isoDate(sourceUpdatedAt)) throw new SpecError(`${path}.sourceUpdatedAt`, 'must be an ISO 8601 date');
  const lines = arr(o, 'lines', path).map((l, i) => parseLine(l, `${path}.lines[${i}]`));
  const ids = new Set(lines.map((l) => l.lineId));
  if (ids.size !== lines.length) throw new SpecError(`${path}.lines`, 'lineId must be unique within the order');
  return {
    orderId: str(o, 'orderId', path, { nonEmpty: true })!,
    reference: str(o, 'reference', path, { nonEmpty: true })!,
    recipient: str(o, 'recipient', path, { nullable: true }),
    createdAt, sourceUpdatedAt,
    eligible: bool(o, 'eligible', path),
    ineligibleReason: str(o, 'ineligibleReason', path, { nullable: true }),
    lines,
    nonPhysical: arr(o, 'nonPhysical', path).map((n, i) => {
      const no = obj(n, `${path}.nonPhysical[${i}]`);
      return { title: str(no, 'title', `${path}.nonPhysical[${i}]`)!, reason: str(no, 'reason', `${path}.nonPhysical[${i}]`)! };
    }),
  };
}

export function parseOrders(body: unknown): OrdersResponse {
  const o = obj(body, 'response');
  spec(o, 'response');
  const orders = arr(o, 'orders', 'response').map((v, i) => parseOrder(v, `orders[${i}]`));
  const ids = new Set(orders.map((x) => x.orderId));
  if (ids.size !== orders.length) throw new SpecError('orders', 'orderId must be unique');
  return { spec: SPEC, orders };
}

export function parseProducts(body: unknown): ProductsResponse {
  const o = obj(body, 'response');
  spec(o, 'response');
  const products = arr(o, 'products', 'response').map((v, i) => {
    const p = obj(v, `products[${i}]`);
    return {
      code: str(p, 'code', `products[${i}]`, { nonEmpty: true })!,
      name: str(p, 'name', `products[${i}]`, { nonEmpty: true })!,
      externalId: str(p, 'externalId', `products[${i}]`, { nullable: true }),
    };
  });
  const codes = new Set(products.map((p) => p.code));
  if (codes.size !== products.length) throw new SpecError('products', 'code must be unique');
  return { spec: SPEC, products };
}

export function parseBarcodes(body: unknown): BarcodesResponse {
  const o = obj(body, 'response');
  spec(o, 'response');
  return {
    spec: SPEC,
    barcodes: arr(o, 'barcodes', 'response').map((v, i) => {
      const b = obj(v, `barcodes[${i}]`);
      const barcode = str(b, 'barcode', `barcodes[${i}]`, { nonEmpty: true })!;
      if (/e\+/i.test(barcode)) throw new SpecError(`barcodes[${i}].barcode`, 'looks like a spreadsheet number, not exact text');
      return { barcode, code: str(b, 'code', `barcodes[${i}]`, { nonEmpty: true })!, sourceRef: str(b, 'sourceRef', `barcodes[${i}]`, { nullable: true }) };
    }),
  };
}
