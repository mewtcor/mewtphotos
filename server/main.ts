// Entry point: `npm start` or scripts/start-backup.ps1.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import QRCode from 'qrcode';
import { buildApp } from './app.ts';
import { dataDir, dbFile } from './config.ts';
import { openDb } from './db.ts';
import { pickLanAddress } from './security.ts';

const port = Number(process.env.MEWTPHOTOS_PORT ?? 8787);
const lanIp = process.env.MEWTPHOTOS_HOST ?? pickLanAddress();
const daemon = process.env.MEWTPHOTOS_DAEMON === '1' || process.argv.includes('--daemon');
const dashboard = `http://127.0.0.1:${port}/dashboard`;
const openDashboard = () => {
  if (!daemon && process.platform === 'win32' && !process.argv.includes('--no-open')) {
    spawn('cmd', ['/c', 'start', '', dashboard], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  }
};

// If a copy of this app already owns the port there is nothing to fix. Checked before the
// database is opened: startup recovery must never run against a database another copy is using.
const running = await fetch(`http://127.0.0.1:${port}/api/v1/health`, { signal: AbortSignal.timeout(3000) })
  .then((r) => r.json() as Promise<{ name?: string }>)
  .catch(() => null);
if (running?.name === 'mewtphotos') {
  console.log('\n  The backup app is already running (in another window, or in the background).');
  console.log(`  Dashboard: ${dashboard}`);
  console.log('  To restart it, close that window (or end "Node.js JavaScript Runtime" in Task Manager) and start again.\n');
  openDashboard();
  process.exit(0);
}

const dir = dataDir();
mkdirSync(dir, { recursive: true });
const logFile = path.join(dir, 'server.log');

const db = openDb(dbFile(dir));
const { app, ctx, pairing, listen } = await buildApp({ db, port, lanIp, logFile, daemon, onStopRequest: (reason) => void shutdown(reason) });

try {
  await listen();
} catch (err) {
  const code = (err as { code?: string }).code;
  if (code === 'EADDRINUSE') {
    console.error(`\nPort ${port} is in use by another program (not this app).`);
    console.error(`Start on a different port:  .\\scripts\\start-backup.ps1 -Port ${port + 1}\n`);
  } else if (code === 'EADDRNOTAVAIL') {
    console.error(`\nCannot listen on ${lanIp}: that address is not on this computer. Check the Wi-Fi connection (or MEWTPHOTOS_HOST).\n`);
  } else {
    console.error('\nThe server could not start:', err);
  }
  await app.close().catch(() => undefined);
  db.close();
  process.exit(1);
}

console.log('\n  iPhone Photo Backup is running\n');
console.log(`  Dashboard (this PC):  ${dashboard}`);
console.log(`  Backup folder:        ${ctx.settings().destination}`);
if (lanIp) {
  const phoneUrl = `http://${lanIp}:${port}`;
  const { code } = pairing.current();
  console.log(`  iPhone address:       ${phoneUrl}`);
  console.log(`  Pairing code:         ${code}  (valid 10 minutes; the dashboard always shows the current one)\n`);
  console.log(await QRCode.toString(`${phoneUrl}/#pair=${code}`, { type: 'terminal', small: true }));
  console.log('  Scan the QR code with the iPhone camera (same Wi-Fi network).');
  console.log('  If Windows asks whether to allow Node.js on the network, allow it for Private networks only.');
  console.log('  Note: traffic is plain HTTP, unencrypted, and stays on your local network.');
} else {
  console.log('\n  No Wi-Fi/Ethernet address was found, so the iPhone cannot connect yet.');
  console.log('  Connect this PC to the same Wi-Fi as the iPhone and restart.');
}
console.log(`\n  Log file: ${logFile}`);
console.log(daemon
  ? '  Running in 24/7 daemon mode (MEWTPHOTOS_DAEMON=1). Send SIGTERM or press Ctrl+C to stop.\n'
  : ctx.settings().stopWithDashboard
    ? '  To stop: close the dashboard tab (the app waits for any running backup), or press Ctrl+C.\n'
    : '  Press Ctrl+C to stop.\n');

openDashboard();

let stopping = false;
async function shutdown(reason?: string): Promise<void> {
  if (stopping) return;
  stopping = true;
  console.log(`\n  ${reason ? `${reason}. ` : ''}Stopping... (partial uploads are kept and can resume)`);
  // In-flight chunks are cut off; their bytes on disk stay as resumable partial uploads.
  await app.close().catch(() => undefined);
  db.close();
  process.exit(0);
}
process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());
process.on('SIGHUP', () => void shutdown());
