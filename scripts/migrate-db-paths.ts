// CLI: rewrite stored Windows backup paths in mewtphotos.db for a Linux Mint (or relocated) server.
// Usage:
//   node --disable-warning=ExperimentalWarning scripts/migrate-db-paths.ts \
//     --db /var/lib/mewtphotos/mewtphotos.db \
//     --from "C:\Users\mewt\Pictures\iPhone Backup" \
//     --to "/srv/mewtphotos/backup" [--dry-run]
import { existsSync } from 'node:fs';
import { openDb } from '../server/db.ts';
import { migrateDbPaths } from '../server/migrate.ts';

function flag(name: string): string | undefined {
  const idx = process.argv.indexOf(name);
  return idx >= 0 ? process.argv[idx + 1] : undefined;
}

const dbPath = flag('--db');
const fromPrefix = flag('--from');
const toPrefix = flag('--to');
const dryRun = process.argv.includes('--dry-run');

if (!dbPath || !fromPrefix || !toPrefix) {
  console.error('Usage: migrate-db-paths.ts --db <path> --from <old-prefix> --to <new-prefix> [--dry-run]');
  process.exit(2);
}

if (!existsSync(dbPath)) {
  console.error(`Database file not found: ${dbPath}`);
  process.exit(1);
}

const db = openDb(dbPath);
try {
  const report = migrateDbPaths(db, {
    fromPrefix,
    toPrefix,
    dryRun,
    disableStopWithDashboard: true,
  });
  console.log(dryRun ? '\n  Dry run (no changes written):' : '\n  Migration complete:');
  console.log(`  files updated:         ${report.filesUpdated}`);
  console.log(`  files unmatched:       ${report.filesUnmatched}`);
  console.log(`  uploads.final_path:    ${report.uploadsFinalUpdated}`);
  console.log(`  uploads.temp_path:     ${report.uploadsTempUpdated}`);
  console.log(`  settings updated:      ${report.settingsUpdated ? 'yes' : 'no'}\n`);
  if (!dryRun) {
    console.log('  Next: run `npm run verify` with MEWTPHOTOS_DATA_DIR set to confirm every file on disk.\n');
  }
} finally {
  db.close();
}
