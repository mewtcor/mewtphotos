// The Windows-side dashboard, served only to the computer the backup app runs on.
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { API, type Overview, type PairingInfo, type SessionSummary, type Settings } from '../../shared/schemas.ts';
import { api, ApiError, formatBytes, formatTime } from './api.ts';

const GB = 1024 ** 3;

function Tile({ label, value, bad }: { label: string; value: string | number; bad?: boolean }) {
  return (
    <div className={`tile ${bad ? 'bad' : ''}`}>
      <div className="value">{value}</div>
      <div className="label">{label}</div>
    </div>
  );
}

function Connect({ pairing, server }: { pairing: PairingInfo | null; server: Overview['server'] }) {
  if (!server.lanUrl || !pairing?.qrSvg) {
    return (
      <section className="card warn">
        <h2>iPhone cannot connect yet</h2>
        <p>No Wi-Fi or Ethernet address was found on this computer. Connect it to the same Wi-Fi network as the iPhone, then restart the backup app.</p>
      </section>
    );
  }
  return (
    <section className="card connect">
      <img alt="QR code to open the backup page on the iPhone" src={`data:image/svg+xml;utf8,${encodeURIComponent(pairing.qrSvg)}`} />
      <div>
        <h2>Connect the iPhone</h2>
        <ol>
          <li>Put the iPhone on the same Wi-Fi network as this computer.</li>
          <li>Scan the QR code with the iPhone camera, or open <code>{server.lanUrl}</code> in Safari.</li>
          <li>First time only: confirm the pairing code <code className="code">{pairing.code}</code></li>
        </ol>
        <p className="muted small">The code changes after each use and every 10 minutes. An already-paired iPhone just opens the page.</p>
        <p className="muted small">Traffic uses plain HTTP: it never leaves your local network, but it is not encrypted. Use it on Wi-Fi you trust.</p>
        <p className="muted small">iPhone cannot open the page? Check both devices are on the same Wi-Fi (not a guest network), and that Windows Firewall allows Node.js on <i>Private</i> networks. See docs/troubleshooting.md.</p>
      </div>
    </section>
  );
}

function SessionCounts({ s }: { s: SessionSummary }) {
  return (
    <>
      <div className="tiles">
        <Tile label="In iPhone library" value={s.libraryCount ?? 'Unknown'} />
        <Tile label="Selected" value={s.selected} />
        <Tile label="Submitted" value={s.submitted} />
        <Tile label="Received" value={s.received} />
        <Tile label="Verified" value={s.verified} />
        <Tile label="Duplicates skipped" value={s.duplicates} />
        <Tile label="Failed" value={s.failed} bad={s.failed > 0} />
        <Tile label="Unavailable on iPhone" value={s.unavailable} bad={s.unavailable > 0} />
      </div>
      <p><b>{s.message}</b></p>
      {s.libraryCount === null && (
        <p className="muted small">“In iPhone library” is unknown because Safari and Shortcuts cannot count the Photos library. Only the files you selected are accounted for.</p>
      )}
    </>
  );
}

function SettingsForm({ settings, onSaved }: { settings: Settings; onSaved: () => void }) {
  const [draft, setDraft] = useState(settings);
  const [message, setMessage] = useState('');
  useEffect(() => setDraft(settings), [settings]);
  const set = <K extends keyof Settings>(key: K, value: Settings[K]) => setDraft((d) => ({ ...d, [key]: value }));
  const gb = (key: 'quotaBytes' | 'minFreeBytes' | 'maxFileBytes') => (
    <input type="number" min={0} step="any" value={draft[key] / GB} onChange={(e) => set(key, Math.round(Number(e.target.value) * GB))} />
  );

  async function save(e: FormEvent) {
    e.preventDefault();
    try {
      await api('PUT', '/admin/settings', draft);
      setMessage('Saved.');
      onSaved();
    } catch (err) {
      setMessage(err instanceof Error ? err.message : 'Could not save.');
    }
  }

  return (
    <form className="card" onSubmit={save}>
      <h2>Backup folder &amp; settings</h2>
      <label>
        Backup folder (full path)
        <input value={draft.destination} onChange={(e) => set('destination', e.target.value)} spellCheck={false} />
      </label>
      <p className="muted small">Changing the folder affects new uploads only. Files already backed up stay where they are and still count for duplicate detection.</p>
      <label className="check">
        <input type="checkbox" checked={draft.organizeByDate} onChange={(e) => set('organizeByDate', e.target.checked)} />
        <span>Organize into Year\Month folders by capture date (falls back to the file date, then the upload date, when a photo has no capture date)</span>
      </label>
      <label className="check">
        <input type="checkbox" checked={draft.stopWithDashboard} onChange={(e) => set('stopWithDashboard', e.target.checked)} />
        <span>Stop the backup app when I close this dashboard (it waits until no backup is running; untick to keep it running in the background)</span>
      </label>
      <div className="grid">
        <label>Parallel uploads<input type="number" min={1} max={6} value={draft.concurrency} onChange={(e) => set('concurrency', Number(e.target.value))} /></label>
        <label>Largest allowed file (GB){gb('maxFileBytes')}</label>
        <label>Keep free on disk (GB){gb('minFreeBytes')}</label>
        <label>Backup size limit (GB, 0 = none){gb('quotaBytes')}</label>
      </div>
      <button className="primary">Save</button> {message && <span className="muted">{message}</span>}
    </form>
  );
}

export function Dashboard() {
  const [data, setData] = useState<Overview | null>(null);
  const [pairing, setPairing] = useState<PairingInfo | null>(null);
  const [error, setError] = useState('');
  const [live, setLive] = useState(false);
  const [speed, setSpeed] = useState(0);
  const [verifyProgress, setVerifyProgress] = useState<{ done: number; total: number } | null>(null);
  const [stopped, setStopped] = useState(false);
  const refreshTimer = useRef(0);

  async function refresh() {
    try {
      const [overview, pair] = await Promise.all([api<Overview>('GET', '/admin/overview'), api<PairingInfo>('GET', '/admin/pairing')]);
      setData(overview);
      setPairing(pair);
      if (!overview.verifyRunning) setVerifyProgress(null);
      setError('');
    } catch (err) {
      setError(err instanceof ApiError && err.status === 403
        ? 'The dashboard can only be opened on the Windows computer running the backup app (http://127.0.0.1). On the iPhone, open the main page instead.'
        : 'The backup app is not responding. Is it still running?');
    }
  }

  useEffect(() => {
    void refresh();
    const events = new EventSource(`${API}/admin/events`);
    events.onopen = () => {
      setLive(true);
      void refresh();
    };
    events.onerror = () => setLive(false);
    // Many small events arrive during a transfer; collapse them into one reload.
    events.addEventListener('change', () => {
      clearTimeout(refreshTimer.current);
      refreshTimer.current = window.setTimeout(() => void refresh(), 300);
    });
    events.addEventListener('speed', (e) => setSpeed((JSON.parse((e as MessageEvent<string>).data) as { bytesPerSecond: number }).bytesPerSecond));
    events.addEventListener('verify', (e) => setVerifyProgress(JSON.parse((e as MessageEvent<string>).data) as { done: number; total: number }));
    const poll = setInterval(() => void refresh(), 60_000); // keeps the pairing code and free space current
    return () => {
      events.close();
      clearInterval(poll);
    };
  }, []);

  async function stop() {
    if (!window.confirm('Stop the backup app? A backup that is still running will be interrupted and can resume next time.')) return;
    await api('POST', '/admin/shutdown').catch(() => undefined);
    setStopped(true);
  }

  if (stopped) return <main className="dash"><h1>iPhone Photo Backup</h1><div className="card ok"><b>The backup app has been stopped.</b> You can close this tab. Start it again with “Start Backup”.</div></main>;
  if (error && !data) return <main className="dash"><h1>iPhone Photo Backup</h1><div className="card warn">{error}</div></main>;
  if (!data) return <main className="dash"><p className="muted">Loading…</p></main>;

  const { server, settings, storage, totals, sessions, failures, logs, devices, lastVerify } = data;
  const current = sessions[0];
  const verifyBad = lastVerify ? lastVerify.missing.length + lastVerify.corrupt.length + lastVerify.databaseProblems.length : 0;

  return (
    <main className="dash">
      <header>
        <h1>iPhone Photo Backup</h1>
        <span className={`badge ${live ? 'verified' : 'failed'}`}>{live ? 'Server running' : 'Server not responding'}</span>
        <span className="muted small">v{server.version} · port {server.port} · started {formatTime(server.startedAt)}</span>
        <button className="stop" onClick={() => void stop()}>Stop backup app</button>
      </header>
      {error && <div className="card warn">{error}</div>}
      {server.restartRequired && <div className="card warn"><b>Server restart required.</b> This computer’s network address changed. Close the backup app, start it again, and reconnect the iPhone.</div>}

      <Connect pairing={pairing} server={server} />

      <section className="card">
        <h2>Backup totals</h2>
        <div className="tiles">
          <Tile label="Files stored" value={totals.files} />
          <Tile label="Total size" value={formatBytes(totals.bytes)} />
          <Tile label="Verified end to end" value={totals.endToEndVerified} />
          <Tile label="Duplicates skipped" value={totals.duplicates} />
          <Tile label="Failed uploads" value={totals.failed} bad={totals.failed > 0} />
          <Tile label="Transfer speed" value={`${formatBytes(speed)}/s`} />
          <Tile label="Free disk space" value={formatBytes(storage.freeBytes)} bad={storage.freeBytes < settings.minFreeBytes * 2} />
        </div>
        <p className="muted small">Backup folder: <code>{settings.destination}</code></p>
      </section>

      <section className="card">
        <h2>{current && !current.completedAt ? 'Current backup session' : 'Latest backup session'}</h2>
        {current ? (
          <>
            <p className="muted small">{current.deviceName} · {current.method} · started {formatTime(current.startedAt)}{current.completedAt ? ` · finished ${formatTime(current.completedAt)}` : ''}</p>
            <SessionCounts s={current} />
          </>
        ) : <p className="muted">No backups yet. Connect the iPhone to start.</p>}
      </section>

      <section className="card">
        <h2>Verify stored files</h2>
        <p className="muted small">Re-reads every backed-up file from disk and compares it with the SHA-256 recorded when it was stored. Also available as <code>npm run verify</code>.</p>
        <button className="primary" disabled={data.verifyRunning} onClick={() => void api('POST', '/admin/verify').then(refresh, refresh)}>
          {data.verifyRunning ? `Verifying… ${verifyProgress ? `${verifyProgress.done} / ${verifyProgress.total}` : ''}` : 'Verify now'}
        </button>
        {lastVerify && (
          <div className={verifyBad ? 'result bad' : 'result'}>
            <p><b>{verifyBad ? 'Problems found' : 'All recorded files are present and intact'}</b> — {formatTime(lastVerify.finishedAt)}: {lastVerify.checked} checked, {lastVerify.ok} OK, {lastVerify.missing.length} missing, {lastVerify.corrupt.length} corrupted.</p>
            {lastVerify.missing.length > 0 && <details open><summary>Missing files</summary><ul>{lastVerify.missing.map((p) => <li key={p}><code>{p}</code></li>)}</ul></details>}
            {lastVerify.corrupt.length > 0 && <details open><summary>Corrupted files</summary><ul>{lastVerify.corrupt.map((p) => <li key={p}><code>{p}</code></li>)}</ul></details>}
            {lastVerify.databaseProblems.length > 0 && <ul>{lastVerify.databaseProblems.map((p) => <li key={p}>{p}</li>)}</ul>}
            {lastVerify.untracked.length > 0 && <details><summary>{lastVerify.untracked.length} file(s) in the backup folder that this app did not store (not verified)</summary><ul>{lastVerify.untracked.map((p) => <li key={p}><code>{p}</code></li>)}</ul></details>}
          </div>
        )}
      </section>

      <SettingsForm settings={settings} onSaved={() => void refresh()} />

      <section className="card">
        <h2>Failed uploads</h2>
        {failures.length === 0 ? <p className="muted">None.</p> : (
          <div className="scroll"><table>
            <thead><tr><th>When</th><th>File</th><th>Reason</th><th>Device</th></tr></thead>
            <tbody>{failures.map((f) => <tr key={f.id}><td>{formatTime(f.at)}</td><td>{f.filename}</td><td>{f.error}</td><td>{f.device}</td></tr>)}</tbody>
          </table></div>
        )}
      </section>

      <section className="card">
        <h2>Backup history</h2>
        {sessions.length === 0 ? <p className="muted">No sessions yet.</p> : (
          <div className="scroll"><table>
            <thead><tr><th>Started</th><th>Device</th><th>Via</th><th>Selected</th><th>Verified</th><th>Duplicates</th><th>Failed</th><th>Unavailable</th><th>Size</th></tr></thead>
            <tbody>{sessions.map((s) => (
              <tr key={s.id} title={s.message}>
                <td>{formatTime(s.startedAt)}</td><td>{s.deviceName}</td><td>{s.method}</td><td>{s.selected}</td><td>{s.verified}</td><td>{s.duplicates}</td>
                <td className={s.failed ? 'bad' : ''}>{s.failed}</td><td className={s.unavailable ? 'bad' : ''}>{s.unavailable}</td><td>{formatBytes(s.bytesStored)}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </section>

      <section className="card">
        <h2>Paired devices</h2>
        {devices.length === 0 ? <p className="muted">No devices paired.</p> : (
          <ul className="plain">{devices.map((d) => (
            <li key={d.id}>
              <b>{d.name}</b> <span className="muted small">paired {formatTime(d.createdAt)}{d.lastSeenAt ? ` · last seen ${formatTime(d.lastSeenAt)}` : ''}</span>{' '}
              <button onClick={() => void api('DELETE', `/admin/devices/${d.id}`).then(refresh, refresh)}>Remove</button>
            </li>
          ))}</ul>
        )}
      </section>

      <section className="card">
        <h2>Log</h2>
        <div className="scroll log">
          {logs.length === 0 && <p className="muted">Nothing logged yet.</p>}
          {logs.map((l, i) => <div key={i} className={l.level}><span className="muted">{formatTime(l.ts)}</span> {l.message}</div>)}
        </div>
      </section>
    </main>
  );
}
