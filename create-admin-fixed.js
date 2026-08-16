/**
 * Schema-aware admin creator (matches actual db/schema.sql).
 * Usage: node create-admin-fixed.js <email> <password> [name]
 */
import 'dotenv/config';
import { query, shutdown } from '../src/db.js';
import { hashPassword } from '../src/auth/password.js';

async function main() {
  const [email, password, name] = process.argv.slice(2);
  if (!email || !password) {
    console.error('Usage: node create-admin-fixed.js <email> <password> [name]');
    process.exit(1);
  }
  // verifyPassword() expects the full "pbkdf2$<salt>$<hash>" in password_hash.
  const stored = await hashPassword(password);
  const [, salt] = stored.split('$');

  const existing = await query(
    `SELECT id FROM internal_auth WHERE LOWER(email)=LOWER($1) LIMIT 1`,
    [email]
  );
  if (existing.rowCount) {
    await query(
      `UPDATE internal_auth
       SET password_hash=$2, password_salt=$3, password_iterations=100000, password_algo='pbkdf2-sha256',
           role='admin', full_name=COALESCE($4, full_name),
           failed_login_attempts=0, locked_until=NULL, is_active=true
       WHERE id=$1`,
      [existing.rows[0].id, stored, salt, name || null]
    );
    console.log(`✅ Updated admin ${email}`);
  } else {
    await query(
      `INSERT INTO internal_auth
        (email, password_hash, password_salt, password_iterations, password_algo, role, full_name, is_active)
       VALUES (LOWER($1), $2, $3, 100000, 'pbkdf2-sha256', 'admin', $4, true)`,
      [email, stored, salt, name || email.split('@')[0]]
    );
    console.log(`✅ Created admin ${email}`);
  }
  await shutdown();
}

main().catch(async (e) => {
  console.error('❌', e.message || e);
  await shutdown().catch(() => {});
  process.exit(1);
});
