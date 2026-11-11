// Usage: PACKY_OPERATOR_PASSWORD=... npm run operator -- <username> "<Display Name>"
import { addOperator } from '../src/auth.ts';
import { openDb } from '../src/db.ts';

const [username, displayName] = process.argv.slice(2);
const password = process.env.PACKY_OPERATOR_PASSWORD;
if (!username || !displayName || !password) {
  console.error('Usage: PACKY_OPERATOR_PASSWORD=... npm run operator -- <username> "<Display Name>"');
  process.exit(1);
}
addOperator(openDb(process.env.PACKY_DB ?? 'data/packy.db'), username, displayName, password);
console.log(`Operator ${username} saved.`);
