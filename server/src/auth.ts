import type { DatabaseSync } from 'node:sqlite';
import { createHash, randomBytes, scrypt, scryptSync, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { ApiError } from './types.ts';
import type { User } from './types.ts';

const SESSION_MS = 12 * 60 * 60_000;
const LOCK_MS = 15 * 60_000;
const MAX_FAILURES = 5;
const DUMMY_HASH = hashPassword('packy-timing-placeholder');

export function hashPassword(password: string): string {
  const salt = randomBytes(16);
  return `${salt.toString('hex')}:${scryptSync(password, salt, 32).toString('hex')}`;
}

const scryptAsync = promisify(scrypt) as (password: string, salt: Buffer, keylen: number) => Promise<Buffer>;

async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [salt, hash] = stored.split(':');
  const derived = await scryptAsync(password, Buffer.from(salt, 'hex'), 32);
  return timingSafeEqual(derived, Buffer.from(hash, 'hex'));
}

const tokenHash = (token: string) => createHash('sha256').update(token).digest('hex');

export function addOperator(db: DatabaseSync, username: string, displayName: string, password: string): void {
  if (password.length < 10) throw new Error('Password must be at least 10 characters.');
  db.prepare(`INSERT INTO users (username, display_name, password_hash) VALUES (?,?,?)
    ON CONFLICT (username) DO UPDATE SET display_name = excluded.display_name, password_hash = excluded.password_hash, active = 1, failed_logins = 0, locked_until = 0`)
    .run(username, displayName, hashPassword(password));
}

interface UserRow { id: number; username: string; display_name: string; password_hash: string; active: number; failed_logins: number; locked_until: number }

export async function login(db: DatabaseSync, username: string, password: string, now: number): Promise<{ token: string; user: User; expiresAt: number }> {
  const row = db.prepare('SELECT * FROM users WHERE username = ?').get(username) as UserRow | undefined;
  const invalid = new ApiError(401, 'invalid_login', 'Wrong username or password.');
  if (row && row.locked_until > now) throw new ApiError(429, 'locked', 'Too many attempts. Try again in 15 minutes.');
  const ok = await verifyPassword(password, row?.password_hash ?? DUMMY_HASH);
  if (!row || !row.active || !ok) {
    if (row) {
      const failures = row.failed_logins + 1;
      db.prepare('UPDATE users SET failed_logins = ?, locked_until = ? WHERE id = ?')
        .run(failures >= MAX_FAILURES ? 0 : failures, failures >= MAX_FAILURES ? now + LOCK_MS : 0, row.id);
    }
    throw invalid;
  }
  db.prepare('UPDATE users SET failed_logins = 0, locked_until = 0 WHERE id = ?').run(row.id);
  db.prepare('DELETE FROM auth_sessions WHERE expires_at < ?').run(now);
  const token = randomBytes(32).toString('base64url');
  const expiresAt = now + SESSION_MS;
  db.prepare('INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?,?,?)').run(tokenHash(token), row.id, expiresAt);
  return { token, user: { id: row.id, username: row.username, displayName: row.display_name }, expiresAt };
}

export function authenticate(db: DatabaseSync, header: string | undefined, now: number): User {
  const token = header?.startsWith('Bearer ') ? header.slice(7) : null;
  const row = token
    ? (db.prepare(`SELECT u.id, u.username, u.display_name FROM auth_sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ? AND s.expires_at > ? AND u.active = 1`).get(tokenHash(token), now) as { id: number; username: string; display_name: string } | undefined)
    : undefined;
  if (!row) throw new ApiError(401, 'unauthenticated', 'Please sign in.');
  return { id: row.id, username: row.username, displayName: row.display_name };
}

export function logout(db: DatabaseSync, header: string | undefined): void {
  if (header?.startsWith('Bearer ')) db.prepare('DELETE FROM auth_sessions WHERE token_hash = ?').run(tokenHash(header.slice(7)));
}
