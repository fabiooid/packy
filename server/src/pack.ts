import type { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { tx } from './db.ts';
import { lookupBarcode, productName, resolveIdentity, resolveVerification } from './catalog.ts';
import type { Identity, Policies, Verification } from './catalog.ts';
import { ApiError } from './types.ts';
import type { NonPhysicalRow, Sources, SourceLine, User } from './types.ts';

export interface Ctx {
  db: DatabaseSync;
  now: () => number;
  policies: Policies;
  sources: Sources;
}

export const ORDER_MAX_AGE_MS = 5 * 60_000;
export const CATALOG_MAX_AGE_MS = 24 * 60 * 60_000;
export const SCAN_OFFER_MS = 90_000;
export const LIMITS_NOTE = 'This code identifies the product type, not a single bottle.';

function productLabel(codice: string | null | undefined, name: string | null | undefined, fallback = 'this product'): string {
  if (codice && name) return `${name} (${codice})`;
  if (name) return name;
  if (codice) return codice;
  return fallback;
}

function stillNeeded(view: PackView): string {
  return view.lines
    .filter((l) => l.remaining > 0 || l.uncertain > 0 || l.state === 'blocked')
    .map((l) => productLabel(l.identity.codice, l.identity.ficName, l.identity.sourceTitle))
    .join(', ');
}

const RESOLUTIONS: Record<string, string[]> = {
  wrong_product: ['set_aside', 'never_in_box'],
  unknown_code: ['set_aside', 'never_in_box'],
  ambiguous_code: ['set_aside', 'never_in_box'],
  excess: ['set_aside', 'repeat_read'],
  order_reduced: ['set_aside'],
};

interface OrderRow {
  source: string; order_id: string; reference: string; recipient: string | null; eligible: number;
  ineligible_reason: string | null; lines: string; non_physical: string; pulled_at: number;
}
interface PackRow {
  id: string; source: string; order_id: string; status: string; owner_user_id: number; version: number;
  accepted_lines: string; created_at: number; updated_at: number; completed_at: number | null; completed_by: number | null;
}
interface UnitRow { id: string; line_id: string; codice: string; barcode: string; status: string; confirmed_by: number; confirmed_at: number }
interface DiscrepancyRow { id: string; kind: string; barcode: string | null; codice: string | null; title: string; detail: string; read_count: number; created_at: number }
interface ScanRow { id: string; pack_id: string; barcode: string; outcome: string; line_id: string | null; user_id: number; expires_at: number | null; consumed_at: number | null }

export interface LineView {
  lineId: string;
  kind: 'physical' | 'uncertain';
  kindReason: string | null;
  required: number;
  verified: number;
  uncertain: number;
  remaining: number;
  state: 'todo' | 'partial' | 'done' | 'recheck' | 'blocked';
  identity: Identity;
  verification: Verification | null;
  units: { id: string; status: string; confirmedAt: number; confirmedBy: string }[];
}

export interface Blocker { code: string; message: string; lineId?: string }
export interface Change { lineId: string; kind: 'added' | 'removed' | 'quantity' | 'identity'; message: string }

export interface PackView {
  id: string; source: string; orderId: string; reference: string; recipient: string | null;
  status: string; version: number; isOwner: boolean; ownerName: string; fixture: boolean;
  eligible: boolean; ineligibleReason: string | null;
  freshness: { state: 'current' | 'cached' | 'unavailable'; pulledAt: number; message: string | null };
  lines: LineView[]; nonPhysical: NonPhysicalRow[];
  discrepancies: { id: string; kind: string; barcode: string | null; codice: string | null; title: string; detail: string; readCount: number; resolutions: string[] }[];
  changes: Change[]; blockers: Blocker[]; canComplete: boolean;
  completedAt: number | null; completedByName: string | null; changedAfterCompletion: boolean; limitsNote: string;
  hasRecordedCount: boolean; canLeave: boolean;
}

function getOrder(db: DatabaseSync, source: string, orderId: string): OrderRow {
  const row = db.prepare('SELECT * FROM orders WHERE source = ? AND order_id = ?').get(source, orderId) as OrderRow | undefined;
  if (!row) throw new ApiError(404, 'order_not_found', 'This order is not in the current workload.');
  return row;
}

function getPack(db: DatabaseSync, packId: string): PackRow {
  const row = db.prepare('SELECT * FROM packs WHERE id = ?').get(packId) as PackRow | undefined;
  if (!row) throw new ApiError(404, 'pack_not_found', 'This packing record does not exist.');
  return row;
}

/** The pack still tied to this order. Released packs are closed and do not count. */
export function findLivePack(db: DatabaseSync, source: string, orderId: string): PackRow | undefined {
  return db.prepare(`SELECT * FROM packs WHERE source = ? AND order_id = ? AND status IN ('active','completed')`).get(source, orderId) as PackRow | undefined;
}

function classifyLine(db: DatabaseSync, line: SourceLine, policies: Policies): { identity: Identity; verification: Verification | null; blocked: boolean } {
  const identity = resolveIdentity(db, line);
  const verification = identity.status === 'resolved' && identity.codice ? resolveVerification(db, identity.codice, policies) : null;
  const blocked = line.kind === 'uncertain' || identity.status === 'unresolved' || verification?.method !== 'barcode';
  return { identity, verification, blocked };
}

function userName(db: DatabaseSync, id: number | null): string {
  const row = db.prepare('SELECT display_name FROM users WHERE id = ?').get(id) as { display_name: string } | undefined;
  return row?.display_name ?? 'Unknown';
}

function logEvent(ctx: Ctx, packId: string, type: string, userId: number, data: unknown = null): void {
  ctx.db.prepare('INSERT INTO events (pack_id, type, user_id, data, created_at) VALUES (?,?,?,?,?)')
    .run(packId, type, userId, data === null ? null : JSON.stringify(data), ctx.now());
}

function bump(ctx: Ctx, packId: string): void {
  ctx.db.prepare('UPDATE packs SET version = version + 1, updated_at = ? WHERE id = ?').run(ctx.now(), packId);
}

function diffLines(accepted: SourceLine[], current: SourceLine[]): Change[] {
  const changes: Change[] = [];
  const label = (l: SourceLine) => l.sku ?? l.title;
  const currentById = new Map(current.map((l) => [l.lineId, l]));
  for (const before of accepted) {
    const after = currentById.get(before.lineId);
    if (!after) changes.push({ lineId: before.lineId, kind: 'removed', message: `${label(before)} is no longer on the order.` });
    else if (after.sku !== before.sku || after.kind !== before.kind) changes.push({ lineId: before.lineId, kind: 'identity', message: `${label(before)} changed identity or type at the source.` });
    else if (after.required !== before.required) changes.push({ lineId: before.lineId, kind: 'quantity', message: `${label(after)} quantity changed from ${before.required} to ${after.required}.` });
  }
  const acceptedIds = new Set(accepted.map((l) => l.lineId));
  for (const after of current) {
    if (!acceptedIds.has(after.lineId)) changes.push({ lineId: after.lineId, kind: 'added', message: `${label(after)} was added to the order.` });
  }
  return changes;
}

function freshness(ctx: Ctx, order: OrderRow): PackView['freshness'] {
  const status = ctx.db.prepare('SELECT status FROM source_status WHERE source = ?').get(order.source) as { status: string } | undefined;
  if (status?.status !== 'ok') {
    return { state: 'unavailable', pulledAt: order.pulled_at, message: 'The order source could not be reached. This is the last saved copy.' };
  }
  if (ctx.now() - order.pulled_at > ORDER_MAX_AGE_MS) {
    return { state: 'cached', pulledAt: order.pulled_at, message: 'This saved copy is too old to certify. Refresh before completing.' };
  }
  return { state: 'current', pulledAt: order.pulled_at, message: null };
}

function catalogProblem(ctx: Ctx): string | null {
  const row = ctx.db.prepare(`SELECT last_success_at FROM source_status WHERE source = 'fic'`).get() as { last_success_at: number | null } | undefined;
  if (!row?.last_success_at) return 'The FIC catalog has never been read, so product identity cannot be confirmed.';
  if (ctx.now() - row.last_success_at > CATALOG_MAX_AGE_MS) return 'The FIC catalog copy is more than a day old. Refresh before completing.';
  return null;
}

export function buildView(ctx: Ctx, pack: PackRow, user: User): PackView {
  const { db } = ctx;
  const order = getOrder(db, pack.source, pack.order_id);
  const current = JSON.parse(order.lines) as SourceLine[];
  const accepted = JSON.parse(pack.accepted_lines) as SourceLine[];
  const changes = diffLines(accepted, current);
  const units = db.prepare(`SELECT * FROM units WHERE pack_id = ? AND status != 'removed' ORDER BY confirmed_at`).all(pack.id) as unknown as UnitRow[];

  const lines: LineView[] = accepted.map((line) => {
    const { identity, verification, blocked } = classifyLine(db, line, ctx.policies);
    const own = units.filter((u) => u.line_id === line.lineId);
    const verified = own.filter((u) => u.status === 'verified').length;
    const uncertain = own.length - verified;
    const remaining = Math.max(0, line.required - own.length);
    const state: LineView['state'] = blocked ? 'blocked' : uncertain > 0 ? 'recheck' : remaining === 0 ? 'done' : verified > 0 ? 'partial' : 'todo';
    return {
      lineId: line.lineId, kind: line.kind, kindReason: line.kindReason, required: line.required, verified, uncertain, remaining, state, identity, verification,
      units: own.map((u) => ({ id: u.id, status: u.status, confirmedAt: u.confirmed_at, confirmedBy: userName(db, u.confirmed_by) })),
    };
  });

  const open = db.prepare(`SELECT * FROM discrepancies WHERE pack_id = ? AND status = 'open' ORDER BY created_at`).all(pack.id) as unknown as DiscrepancyRow[];
  const fresh = freshness(ctx, order);
  const blockers: Blocker[] = [];
  if (!order.eligible) blockers.push({ code: 'order_ineligible', message: order.ineligible_reason ?? 'This order cannot be packed.' });
  if (changes.length > 0) blockers.push({ code: 'order_changed', message: 'The order changed since packing began. Review the changes.' });
  if (fresh.state !== 'current') blockers.push({ code: 'stale_data', message: fresh.message ?? 'Order data is not current.' });
  const catalog = catalogProblem(ctx);
  if (catalog) blockers.push({ code: 'catalog_stale', message: catalog });
  for (const line of lines) {
    const name = line.identity.codice ?? 'Unresolved line';
    if (line.kind === 'uncertain') blockers.push({ code: 'classification_uncertain', lineId: line.lineId, message: line.kindReason ?? 'This row may be a physical item.' });
    if (line.identity.status === 'unresolved') blockers.push({ code: 'identity_unresolved', lineId: line.lineId, message: line.identity.reason ?? 'Product identity is unresolved.' });
    else if (line.verification?.blockCode) blockers.push({ code: line.verification.blockCode, lineId: line.lineId, message: line.verification.reason ?? 'This product cannot be verified.' });
    if (line.uncertain > 0) blockers.push({ code: 'units_uncertain', lineId: line.lineId, message: `${name}: ${line.uncertain} unit(s) must be checked again.` });
    if (line.remaining > 0) blockers.push({ code: 'units_missing', lineId: line.lineId, message: `${name}: ${line.remaining} of ${line.required} still to verify.` });
  }
  for (const d of open) blockers.push({ code: 'discrepancy_open', message: d.title });

  const hasRecordedCount = units.length > 0;
  const isOwner = pack.owner_user_id === user.id;
  return {
    id: pack.id, source: pack.source, orderId: pack.order_id, reference: order.reference, recipient: order.recipient,
    status: pack.status, version: pack.version, isOwner, ownerName: userName(db, pack.owner_user_id),
    fixture: ctx.sources.fixture, eligible: Boolean(order.eligible), ineligibleReason: order.ineligible_reason, freshness: fresh,
    lines, nonPhysical: JSON.parse(order.non_physical) as NonPhysicalRow[],
    discrepancies: open.map((d) => ({ id: d.id, kind: d.kind, barcode: d.barcode, codice: d.codice, title: d.title, detail: d.detail, readCount: d.read_count, resolutions: RESOLUTIONS[d.kind] ?? [] })),
    changes, blockers, canComplete: blockers.length === 0 && pack.status === 'active' && isOwner,
    completedAt: pack.completed_at, completedByName: pack.completed_by ? userName(db, pack.completed_by) : null,
    changedAfterCompletion: pack.status === 'completed' && (changes.length > 0 || !order.eligible), limitsNote: LIMITS_NOTE,
    hasRecordedCount, canLeave: pack.status === 'active' && isOwner && !hasRecordedCount,
  };
}

export function viewPack(ctx: Ctx, packId: string, user: User): PackView {
  return buildView(ctx, getPack(ctx.db, packId), user);
}

/** The order this person already has open, if it is not the pack they are acting on. */
function otherOpenOrder(db: DatabaseSync, userId: number, exceptPackId: string | null): string | undefined {
  const row = db.prepare(`
    SELECT o.reference FROM packs p
    JOIN orders o ON o.source = p.source AND o.order_id = p.order_id
    WHERE p.owner_user_id = ? AND p.status = 'active' AND (? IS NULL OR p.id != ?)
  `).get(userId, exceptPackId, exceptPackId) as { reference: string } | undefined;
  return row?.reference;
}

function refuseSecondOrder(reference: string): never {
  throw new ApiError(409, 'order_already_open', `Finish ${reference} first. One order at a time.`);
}

/** Opens the live pack for an order, creating it for an eligible order. Opening never takes over from someone else. */
export function openPack(ctx: Ctx, user: User, source: string, orderId: string): PackView {
  return tx(ctx.db, () => {
    const order = getOrder(ctx.db, source, orderId);
    const existing = findLivePack(ctx.db, source, orderId);
    if (existing) return buildView(ctx, existing, user);
    const already = otherOpenOrder(ctx.db, user.id, null);
    if (already) refuseSecondOrder(already);
    if (!order.eligible) throw new ApiError(409, 'order_ineligible', order.ineligible_reason ?? 'This order cannot be packed.');
    const id = randomUUID();
    ctx.db.prepare('INSERT INTO packs (id, source, order_id, status, owner_user_id, accepted_lines, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)')
      .run(id, source, orderId, 'active', user.id, order.lines, ctx.now(), ctx.now());
    logEvent(ctx, id, 'started', user.id);
    return buildView(ctx, getPack(ctx.db, id), user);
  });
}

interface Guard { pack: PackRow; view: PackView }

function guardWrite(ctx: Ctx, packId: string, user: User, version: number | null): Guard {
  const pack = getPack(ctx.db, packId);
  const view = buildView(ctx, pack, user);
  if (pack.status !== 'active') throw new ApiError(409, 'pack_not_active', 'This packing record is closed.', { pack: view });
  if (pack.owner_user_id !== user.id) throw new ApiError(403, 'not_owner', `${view.ownerName} is packing this order.`, { pack: view });
  if (version !== null && version !== pack.version) throw new ApiError(409, 'stale_version', 'This order changed on another screen. Check the latest progress.', { pack: view });
  return { pack, view };
}

/** Replays the stored result of an action id, so a retried tap can never add a second unit. */
function idempotent<T>(ctx: Ctx, actionId: string, packId: string, fn: () => T): T {
  if (!actionId) throw new ApiError(400, 'action_id_required', 'Every action needs an action id.');
  return tx(ctx.db, () => {
    const stored = ctx.db.prepare('SELECT pack_id, response FROM actions WHERE action_id = ?').get(actionId) as { pack_id: string; response: string } | undefined;
    if (stored) {
      if (stored.pack_id !== packId) throw new ApiError(409, 'action_id_reused', 'This action id belongs to another order.');
      return JSON.parse(stored.response) as T;
    }
    const result = fn();
    ctx.db.prepare('INSERT INTO actions (action_id, pack_id, response, created_at) VALUES (?,?,?,?)').run(actionId, packId, JSON.stringify(result), ctx.now());
    return result;
  });
}

function requireScannable(view: PackView): void {
  if (!view.eligible) throw new ApiError(409, 'order_ineligible', view.ineligibleReason ?? 'This order cannot be packed.', { pack: view });
  if (view.changes.length > 0) throw new ApiError(409, 'order_changed', 'The order changed. Review the changes before packing more.', { pack: view });
}

export type ScanOutcome = 'eligible' | 'wrong_product' | 'excess' | 'unknown_code' | 'ambiguous_code' | 'line_blocked';

export interface ScanResult {
  scan: {
    id: string; outcome: ScanOutcome; barcode: string; lineId: string | null; codice: string | null; productName: string | null;
    message: string; unitNumber: number | null; required: number | null; recheck: boolean; expiresAt: number | null; discrepancyId: string | null;
  };
  pack: PackView;
}

function raiseDiscrepancy(ctx: Ctx, packId: string, kind: string, barcode: string, codice: string | null, title: string, detail: string): string {
  const existing = ctx.db.prepare(`SELECT id FROM discrepancies WHERE pack_id = ? AND status = 'open' AND kind = ? AND barcode = ?`).get(packId, kind, barcode) as { id: string } | undefined;
  if (existing) {
    ctx.db.prepare('UPDATE discrepancies SET read_count = read_count + 1 WHERE id = ?').run(existing.id);
    return existing.id;
  }
  const id = randomUUID();
  ctx.db.prepare(`INSERT INTO discrepancies (id, pack_id, kind, barcode, codice, title, detail, status, created_at) VALUES (?,?,?,?,?,?,?,'open',?)`)
    .run(id, packId, kind, barcode, codice, title, detail, ctx.now());
  return id;
}

/** Classifies a camera read. It never adds credit. An eligible read only yields a single-use offer to confirm. */
export function recordScan(ctx: Ctx, user: User, packId: string, barcode: string, symbology: string | null): ScanResult {
  if (typeof barcode !== 'string' || barcode.length === 0 || barcode.length > 128) throw new ApiError(400, 'bad_barcode', 'The scan payload was empty or invalid.');
  return tx(ctx.db, () => {
    const { pack, view } = guardWrite(ctx, packId, user, null);
    requireScannable(view);

    const scanId = randomUUID();
    let outcome: ScanOutcome;
    let lineId: string | null = null;
    let codice: string | null = null;
    let name: string | null = null;
    let message: string;
    let discrepancyId: string | null = null;
    let unitNumber: number | null = null;
    let required: number | null = null;
    let recheck = false;
    let expiresAt: number | null = null;

    const needed = stillNeeded(view);
    const lookup = lookupBarcode(ctx.db, barcode);

    if (lookup.status === 'unknown') {
      outcome = 'unknown_code';
      message = 'This code is not linked to any product. It earns no credit.';
      discrepancyId = raiseDiscrepancy(ctx, pack.id, outcome, barcode, null, `Unknown code ${barcode}`, 'If this item is in the box, take it out. It stays unresolved until you account for it.');
    } else if (lookup.status === 'conflict') {
      outcome = 'ambiguous_code';
      message = `${lookup.reason} It earns no credit.`;
      discrepancyId = raiseDiscrepancy(ctx, pack.id, outcome, barcode, null, `Conflicting code ${barcode}`, `${lookup.reason} If this item is in the box, take it out.`);
    } else {
      codice = lookup.codice;
      name = productName(ctx.db, codice);
      const matching = view.lines.filter((l) => l.identity.codice === codice);
      const open = matching.find((l) => l.state !== 'blocked' && (l.uncertain > 0 || l.remaining > 0));
      const label = `${codice} ${name ?? '(not in FIC catalog)'}`;
      if (matching.length === 0) {
        outcome = 'wrong_product';
        message = needed
          ? `Wrong product. Not counted. This order still needs ${needed}.`
          : `Wrong product. Not counted. ${productLabel(codice, name)} is not on this order.`;
        discrepancyId = raiseDiscrepancy(
          ctx, pack.id, outcome, barcode, codice,
          `Wrong product: ${productLabel(codice, name)}`,
          `${productLabel(codice, name)} is not on this order. It was not counted. Account for the physical item.`,
        );
      } else if (matching.every((l) => l.state === 'blocked')) {
        outcome = 'line_blocked';
        message = matching[0].verification?.reason ?? matching[0].kindReason ?? 'This line cannot be verified yet.';
      } else if (open) {
        outcome = 'eligible';
        lineId = open.lineId;
        recheck = open.uncertain > 0;
        required = open.required;
        unitNumber = recheck ? open.verified + 1 : open.verified + open.uncertain + 1;
        expiresAt = ctx.now() + SCAN_OFFER_MS;
        message = recheck ? `${label}: check unit ${unitNumber} of ${required} again.` : `${label}: unit ${unitNumber} of ${required}.`;
      } else {
        outcome = 'excess';
        const total = matching.reduce((sum, l) => sum + l.required, 0);
        message = `${productLabel(codice, name)}: extra item. The order needs ${total}. Not counted.`;
        discrepancyId = raiseDiscrepancy(
          ctx, pack.id, outcome, barcode, codice,
          `Extra item: ${productLabel(codice, name)}`,
          `${productLabel(codice, name)} is extra. The order needs ${total}. It was not counted. Account for the physical item.`,
        );
      }
    }

    ctx.db.prepare('INSERT INTO scans (id, pack_id, barcode, symbology, outcome, line_id, user_id, created_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?)')
      .run(scanId, pack.id, barcode, symbology, outcome, lineId, user.id, ctx.now(), expiresAt);
    logEvent(ctx, pack.id, 'scan', user.id, { outcome, barcode });
    if (discrepancyId) bump(ctx, pack.id);
    return {
      scan: { id: scanId, outcome, barcode, lineId, codice, productName: name, message, unitNumber, required, recheck, expiresAt, discrepancyId },
      pack: viewPack(ctx, pack.id, user),
    };
  });
}

/** The deliberate tap. This is the only way a unit earns credit. */
export function confirmUnit(ctx: Ctx, user: User, packId: string, scanId: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const { pack, view } = guardWrite(ctx, packId, user, version);
    requireScannable(view);
    const scan = ctx.db.prepare('SELECT * FROM scans WHERE id = ? AND pack_id = ?').get(scanId, pack.id) as ScanRow | undefined;
    if (!scan || scan.outcome !== 'eligible' || !scan.line_id) throw new ApiError(409, 'scan_not_eligible', 'This scan cannot be confirmed.', { pack: view });
    if (scan.user_id !== user.id) throw new ApiError(403, 'not_owner', 'Only the person who scanned can confirm.', { pack: view });
    if (scan.consumed_at) throw new ApiError(409, 'scan_used', 'This scan was already used. Scan the next unit.', { pack: view });
    if ((scan.expires_at ?? 0) < ctx.now()) throw new ApiError(409, 'scan_expired', 'This scan expired. Scan the item again.', { pack: view });
    const line = view.lines.find((l) => l.lineId === scan.line_id);
    if (!line || line.state === 'blocked' || !line.identity.codice) throw new ApiError(409, 'line_blocked', 'This line cannot be verified now.', { pack: view });

    const recheck = ctx.db.prepare(`SELECT id FROM units WHERE pack_id = ? AND line_id = ? AND status = 'uncertain' ORDER BY confirmed_at LIMIT 1`).get(pack.id, line.lineId) as { id: string } | undefined;
    if (recheck) {
      ctx.db.prepare(`UPDATE units SET status = 'verified', barcode = ?, confirmed_by = ?, confirmed_at = ? WHERE id = ?`).run(scan.barcode, user.id, ctx.now(), recheck.id);
    } else {
      if (line.remaining <= 0) throw new ApiError(409, 'line_complete', 'This line is already complete. Nothing was added.', { pack: view });
      ctx.db.prepare(`INSERT INTO units (id, pack_id, line_id, codice, barcode, status, confirmed_by, confirmed_at) VALUES (?,?,?,?,?,'verified',?,?)`)
        .run(randomUUID(), pack.id, line.lineId, line.identity.codice, scan.barcode, user.id, ctx.now());
    }
    ctx.db.prepare('UPDATE scans SET consumed_at = ? WHERE id = ?').run(ctx.now(), scan.id);
    logEvent(ctx, pack.id, 'unit_confirmed', user.id, { lineId: line.lineId, recheck: Boolean(recheck) });
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

export function removeUnit(ctx: Ctx, user: User, packId: string, unitId: string, reason: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const { pack } = guardWrite(ctx, packId, user, version);
    if (!['damaged', 'miscounted', 'other'].includes(reason)) throw new ApiError(400, 'bad_reason', 'Choose why the unit came out.');
    const done = ctx.db.prepare(`UPDATE units SET status = 'removed', removed_by = ?, removed_at = ?, removal_reason = ? WHERE id = ? AND pack_id = ? AND status != 'removed'`)
      .run(user.id, ctx.now(), reason, unitId, pack.id);
    if (done.changes === 0) throw new ApiError(404, 'unit_not_found', 'This unit is not counted on this order.');
    logEvent(ctx, pack.id, 'unit_removed', user.id, { unitId, reason });
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

export function resolveDiscrepancy(ctx: Ctx, user: User, packId: string, discrepancyId: string, resolution: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const { pack } = guardWrite(ctx, packId, user, version);
    const row = ctx.db.prepare(`SELECT kind FROM discrepancies WHERE id = ? AND pack_id = ? AND status = 'open'`).get(discrepancyId, pack.id) as { kind: string } | undefined;
    if (!row) throw new ApiError(404, 'discrepancy_not_found', 'This discrepancy is not open.');
    if (!RESOLUTIONS[row.kind]?.includes(resolution)) throw new ApiError(400, 'bad_resolution', 'That answer does not apply here.');
    ctx.db.prepare(`UPDATE discrepancies SET status = 'resolved', resolution = ?, resolved_by = ?, resolved_at = ? WHERE id = ?`).run(resolution, user.id, ctx.now(), discrepancyId);
    logEvent(ctx, pack.id, 'discrepancy_resolved', user.id, { discrepancyId, resolution });
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

/** Accepts the current order as the obligation. Credit above the new quantity is withdrawn and must be physically taken out. */
export function reconcile(ctx: Ctx, user: User, packId: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const { pack, view } = guardWrite(ctx, packId, user, version);
    if (view.changes.length === 0) throw new ApiError(409, 'nothing_to_reconcile', 'The order has not changed.', { pack: view });
    const order = getOrder(ctx.db, pack.source, pack.order_id);
    const current = JSON.parse(order.lines) as SourceLine[];
    const units = ctx.db.prepare(`SELECT * FROM units WHERE pack_id = ? AND status != 'removed' ORDER BY status ASC, confirmed_at DESC`).all(pack.id) as unknown as UnitRow[];
    const lineIds = new Set([...units.map((u) => u.line_id)]);
    for (const lineId of lineIds) {
      const own = units.filter((u) => u.line_id === lineId);
      const change = view.changes.find((c) => c.lineId === lineId);
      const after = current.find((l) => l.lineId === lineId);
      const keep = change?.kind === 'identity' ? 0 : after?.required ?? 0;
      const excess = own.slice(0, Math.max(0, own.length - keep));
      if (excess.length === 0) continue;
      for (const unit of excess) {
        ctx.db.prepare(`UPDATE units SET status = 'removed', removed_by = ?, removed_at = ?, removal_reason = 'order_changed' WHERE id = ?`).run(user.id, ctx.now(), unit.id);
      }
      raiseDiscrepancy(ctx, pack.id, 'order_reduced', own[0].barcode, own[0].codice, `Take out ${excess.length} x ${own[0].codice}`,
        'The order no longer needs these units. Their credit is gone. Take them out of the box.');
    }
    ctx.db.prepare('UPDATE packs SET accepted_lines = ? WHERE id = ?').run(order.lines, pack.id);
    logEvent(ctx, pack.id, 'reconciled', user.id, view.changes);
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

function markAllUncertain(ctx: Ctx, packId: string): void {
  ctx.db.prepare(`UPDATE units SET status = 'uncertain' WHERE pack_id = ? AND status = 'verified'`).run(packId);
}

function requireCurrentVersion(ctx: Ctx, pack: PackRow, user: User, version: number): void {
  if (pack.version !== version) {
    throw new ApiError(409, 'stale_version', 'This order changed. Check the latest progress.', { pack: buildView(ctx, pack, user) });
  }
}

/** Another person cannot vouch for a box they did not fill, so credit becomes "check again", not verified. */
export function takeOver(ctx: Ctx, user: User, packId: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const pack = getPack(ctx.db, packId);
    if (pack.status !== 'active') throw new ApiError(409, 'pack_not_active', 'This packing record is closed.');
    requireCurrentVersion(ctx, pack, user, version);
    if (pack.owner_user_id === user.id) return buildView(ctx, pack, user);
    const already = otherOpenOrder(ctx.db, user.id, pack.id);
    if (already) refuseSecondOrder(already);
    markAllUncertain(ctx, pack.id);
    ctx.db.prepare('UPDATE packs SET owner_user_id = ? WHERE id = ?').run(user.id, pack.id);
    logEvent(ctx, pack.id, 'taken_over', user.id, { from: pack.owner_user_id });
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

export function complete(ctx: Ctx, user: User, packId: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const { pack, view } = guardWrite(ctx, packId, user, version);
    if (view.blockers.length > 0) throw new ApiError(409, 'completion_blocked', 'This order cannot be completed yet.', { pack: view });
    ctx.db.prepare(`UPDATE packs SET status = 'completed', completed_at = ?, completed_by = ? WHERE id = ?`).run(ctx.now(), user.id, pack.id);
    logEvent(ctx, pack.id, 'completed', user.id);
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

export function reopen(ctx: Ctx, user: User, packId: string, actionId: string, version: number): PackView {
  return idempotent(ctx, actionId, packId, () => {
    const pack = getPack(ctx.db, packId);
    if (pack.status !== 'completed') throw new ApiError(409, 'pack_not_completed', 'Only a packed order can be reopened.');
    requireCurrentVersion(ctx, pack, user, version);
    const already = otherOpenOrder(ctx.db, user.id, pack.id);
    if (already) refuseSecondOrder(already);
    if (pack.owner_user_id !== user.id) markAllUncertain(ctx, pack.id);
    ctx.db.prepare(`UPDATE packs SET status = 'active', owner_user_id = ?, completed_at = NULL, completed_by = NULL WHERE id = ?`).run(user.id, pack.id);
    logEvent(ctx, pack.id, 'reopened', user.id);
    bump(ctx, pack.id);
    return viewPack(ctx, pack.id, user);
  });
}

/** The operator states the box is empty. All credit goes and the record closes. */
export function release(ctx: Ctx, user: User, packId: string, actionId: string, version: number): { released: true } {
  return idempotent(ctx, actionId, packId, () => {
    const pack = getPack(ctx.db, packId);
    if (pack.status === 'released') throw new ApiError(409, 'pack_not_active', 'This packing record is closed.');
    if (pack.owner_user_id !== user.id) throw new ApiError(403, 'not_owner', 'Only the current packer can empty this box.');
    if (pack.version !== version) throw new ApiError(409, 'stale_version', 'This order changed. Check the latest progress.');
    if (pack.status === 'active') {
      const counted = ctx.db.prepare(`SELECT id FROM units WHERE pack_id = ? AND status != 'removed' LIMIT 1`).get(pack.id);
      if (counted) {
        throw new ApiError(409, 'session_locked', 'This order already has a count. Stay on it until it is packed.', { pack: buildView(ctx, pack, user) });
      }
    }
    ctx.db.prepare(`UPDATE units SET status = 'removed', removed_by = ?, removed_at = ?, removal_reason = 'box_emptied' WHERE pack_id = ? AND status != 'removed'`).run(user.id, ctx.now(), pack.id);
    ctx.db.prepare(`UPDATE discrepancies SET status = 'resolved', resolution = 'box_emptied', resolved_by = ?, resolved_at = ? WHERE pack_id = ? AND status = 'open'`).run(user.id, ctx.now(), pack.id);
    ctx.db.prepare(`UPDATE packs SET status = 'released' WHERE id = ?`).run(pack.id);
    logEvent(ctx, pack.id, 'released', user.id);
    bump(ctx, pack.id);
    return { released: true as const };
  });
}

export interface WorkloadView {
  fixture: boolean;
  sources: { name: string; status: string; errorCode: string | null; lastSuccessAt: number | null }[];
  orders: {
    source: string; orderId: string; reference: string; recipient: string | null; createdAt: string; eligible: boolean; ineligibleReason: string | null;
    units: number; packId: string | null; packStatus: string | null; ownerName: string | null; isOwner: boolean; verified: number;
    changedAfterCompletion: boolean; blockedLines: number; freshness: PackView['freshness'];
  }[];
}

export function workload(ctx: Ctx, user: User): WorkloadView {
  const { db } = ctx;
  const statuses = db.prepare('SELECT * FROM source_status ORDER BY source').all() as { source: string; status: string; error_code: string | null; last_success_at: number | null }[];
  const rows = db.prepare('SELECT * FROM orders ORDER BY created_at').all() as unknown as (OrderRow & { created_at: string })[];
  const orders = rows.map((o) => {
    const pack = findLivePack(db, o.source, o.order_id);
    const view = pack ? buildView(ctx, pack, user) : null;
    const lines = JSON.parse(o.lines) as SourceLine[];
    const blockedLines = lines.filter((l) => classifyLine(db, l, ctx.policies).blocked).length;
    return {
      source: o.source, orderId: o.order_id, reference: o.reference, recipient: o.recipient, createdAt: o.created_at,
      eligible: Boolean(o.eligible), ineligibleReason: o.ineligible_reason, units: lines.reduce((s, l) => s + l.required, 0),
      packId: pack?.id ?? null, packStatus: pack?.status ?? null, ownerName: view?.ownerName ?? null, isOwner: view?.isOwner ?? false,
      verified: view?.lines.reduce((s, l) => s + l.verified, 0) ?? 0, changedAfterCompletion: view?.changedAfterCompletion ?? false,
      blockedLines, freshness: freshness(ctx, o),
    };
  });
  return {
    fixture: ctx.sources.fixture,
    sources: statuses.map((s) => ({ name: s.source, status: s.status, errorCode: s.error_code, lastSuccessAt: s.last_success_at })),
    orders,
  };
}
