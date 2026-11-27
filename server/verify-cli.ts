// `npm run verify`: re-hash every stored file and check the database. Exit code 1 on problems.
import { existsSync } from 'node:fs';
import { dataDir, dbFile as findDbFile, loadSettings } from './config.ts';
import { openDb } from './db.ts';
import { verifyBackup } from './verify.ts';

const dbFile = findDbFile(dataDir());
if (!existsSync(dbFile)) {
  console.error(`No backup database found at ${dbFile}. Nothing has been backed up yet.`);
  process.exit(1);
}
const db = openDb(dbFile);
const { destination } = loadSettings(db);
console.log(`Verifying backup (current folder: ${destination}) ...`);
const report = await verifyBackup(db, destination, (done, total) => {
  if (done % 50 === 0 || done === total) process.stdout.write(`\r  ${done} / ${total} files re-hashed`);
});
db.close();

const list = (title: string, items: string[]) => {
  if (items.length === 0) return;
  console.log(`\n${title} (${items.length}):`);
  for (const item of items) console.log(`  ${item}`);
};
console.log(`\n\nChecked ${report.checked} files: ${report.ok} OK, ${report.missing.length} missing, ${report.corrupt.length} corrupted.`);
list('MISSING', report.missing);
list('CORRUPTED (content no longer matches recorded SHA-256)', report.corrupt);
list('DATABASE PROBLEMS', report.databaseProblems);
list('Files in the backup folder that are not in the database (not verified)', report.untracked);
const bad = report.missing.length + report.corrupt.length + report.databaseProblems.length;
console.log(bad === 0 ? '\nResult: PASS - every recorded file is present and intact.' : '\nResult: PROBLEMS FOUND - re-upload the affected photos from the iPhone.');
process.exit(bad === 0 ? 0 : 1);
