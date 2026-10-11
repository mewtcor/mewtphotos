// The page the iPhone opens in Safari: pair once, then pick photos and watch them transfer.
import { useEffect, useReducer, useRef, useState, type ChangeEvent, type FormEvent } from 'react';
import { COVERAGE_NOTICE, type ClientStatus, type SessionSummary, type UploadResult } from '../../shared/schemas.ts';
import { api, ApiError, deviceToken, formatBytes, NetworkError } from './api.ts';
import { UnavailableError, uploadFile } from './uploader.ts';

type ItemStatus = 'queued' | 'checking' | 'uploading' | 'verifying' | 'verified' | 'duplicate' | 'failed' | 'unavailable' | 'cancelled';

interface Item {
  key: number;
  file: File;
  status: ItemStatus;
  sent: number;
  error?: string;
  result?: UploadResult;
  uploadId?: string;
}

const LABELS: Record<ItemStatus, string> = {
  queued: 'Waiting',
  checking: 'Checking',
  uploading: 'Sending',
  verifying: 'Verifying on PC',
  verified: 'Stored & verified',
  duplicate: 'Already backed up',
  failed: 'Failed',
  unavailable: 'Unavailable on iPhone',
  cancelled: 'Cancelled',
};
const DONE: ItemStatus[] = ['verified', 'duplicate'];
const RETRYABLE: ItemStatus[] = ['failed', 'unavailable', 'cancelled'];

function Pair({ onPaired }: { onPaired: () => void }) {
  const fromLink = new URLSearchParams(location.hash.slice(1)).get('pair') ?? '';
  const [code, setCode] = useState(fromLink);
  const [name, setName] = useState('iPhone');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      const { token } = await api<{ token: string }>('POST', '/pair', { code, deviceName: name });
      deviceToken.set(token);
      history.replaceState(null, '', location.pathname); // drop the one-time code from the address bar
      onPaired();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Pairing failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>Pair this iPhone</h2>
      <p className="muted">Enter the pairing code shown on the Windows dashboard. Scanning its QR code fills this in for you. You only do this once.</p>
      <label>
        Pairing code
        <input value={code} onChange={(e) => setCode(e.target.value)} autoCapitalize="characters" autoCorrect="off" spellCheck={false} required />
      </label>
      <label>
        Name for this device
        <input value={name} onChange={(e) => setName(e.target.value)} maxLength={80} required />
      </label>
      {error && <p className="error">{error}</p>}
      <button className="primary" disabled={busy}>{busy ? 'Pairing…' : 'Pair'}</button>
    </form>
  );
}

function Limits() {
  return (
    <details className="card">
      <summary>What this page can and cannot do</summary>
      <ul className="notes">
        <li><b>It cannot see your whole Photos library.</b> Safari only receives the items you pick, so the app can confirm that your selection is safe, never that every photo on the iPhone is backed up.</li>
        <li><b>Originals vs. converted copies.</b> When you pick from <i>Photo Library</i>, iOS may hand Safari a converted copy (HEIC as JPEG, video re-encoded). In the picker, tap <i>Options</i> and choose <i>Actual Size</i> and <i>Current</i> format where offered. The file list here shows the type and size iOS actually delivered.</li>
        <li><b>Live Photos</b> arrive as the still image only; the paired video is not provided to web pages.</li>
        <li><b>Keep this page open and the screen on.</b> iOS pauses Safari when the phone locks or you switch apps. Interrupted files resume when you return.</li>
        <li><b>Nothing is ever deleted from the iPhone.</b></li>
        <li>Traffic is plain HTTP on your Wi-Fi: private to your network, but not encrypted.</li>
      </ul>
    </details>
  );
}

/** Values to paste into the optional Apple Shortcut (docs/ios-shortcut.md). */
function ShortcutSetup() {
  return (
    <details className="card">
      <summary>Use with Apple Shortcuts (optional)</summary>
      <p className="muted small">Follow docs/ios-shortcut.md on the PC to build the Shortcut, and copy these two values into it. Treat the key like a password: anyone on your Wi-Fi who has it can upload to your backup.</p>
      <label>
        Upload address
        <input readOnly value={`${location.origin}/api/v1/files`} onFocus={(e) => e.target.select()} />
      </label>
      <label>
        Authorization header value
        <input readOnly value={`Bearer ${deviceToken.get() ?? ''}`} onFocus={(e) => e.target.select()} />
      </label>
    </details>
  );
}

export function Phone() {
  const [paired, setPaired] = useState(() => !!deviceToken.get());
  const [status, setStatus] = useState<ClientStatus | null>(null);
  const [connectError, setConnectError] = useState('');
  const [hash, setHash] = useState(true);
  const [running, setRunning] = useState(false);
  const [summary, setSummary] = useState<SessionSummary | null>(null);
  const [notice, setNotice] = useState('');
  const [, render] = useReducer((n: number) => n + 1, 0);

  const items = useRef<Item[]>([]);
  const session = useRef('');
  const abort = useRef<AbortController | null>(null);
  const runningRef = useRef(false);
  const renderTimer = useRef(0);
  // Progress events arrive many times a second per file; repaint at most 5 times a second.
  const scheduleRender = () => {
    if (!renderTimer.current) {
      renderTimer.current = window.setTimeout(() => {
        renderTimer.current = 0;
        render();
      }, 200);
    }
  };

  async function connect() {
    setConnectError('');
    try {
      setStatus(await api<ClientStatus>('GET', '/status'));
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        deviceToken.clear();
        setPaired(false);
      } else {
        setConnectError('Cannot reach the backup computer. Check that the backup app is running on the PC and that this iPhone is on the same Wi-Fi network.');
      }
    }
  }
  useEffect(() => {
    if (paired) void connect();
  }, [paired]);

  // iOS freezes timers while Safari is in the background; a large gap between ticks reveals it.
  useEffect(() => {
    let last = Date.now();
    const timer = setInterval(() => {
      const gap = Date.now() - last;
      last = Date.now();
      if (gap > 5000 && runningRef.current) {
        setNotice(`iOS paused this page for about ${Math.round(gap / 1000)} seconds, which interrupted the transfer. It is resuming now. Keep Safari open and the screen on until the backup finishes.`);
      }
    }, 1000);
    return () => clearInterval(timer);
  }, []);

  async function run() {
    if (!status) return;
    setRunning(true);
    runningRef.current = true;
    setSummary(null);
    const controller = new AbortController();
    abort.current = controller;

    const worker = async () => {
      for (;;) {
        const item = items.current.find((i) => i.status === 'queued');
        if (!item || controller.signal.aborted) return;
        item.status = 'uploading';
        item.error = undefined;
        try {
          item.result = await uploadFile(item.file, {
            sessionId: session.current,
            chunkSize: status.chunkSize,
            hash,
            signal: controller.signal,
            onUploadId: (id) => (item.uploadId = id),
            onProgress: (bytes, phase) => {
              item.sent = phase === 'checking' ? 0 : bytes; // checking sends nothing
              item.status = phase;
              scheduleRender();
            },
          });
          item.status = item.result.status;
          item.sent = item.file.size;
        } catch (err) {
          if (err instanceof DOMException && err.name === 'AbortError') {
            item.status = 'cancelled';
            if (item.uploadId) void api('DELETE', `/uploads/${item.uploadId}`).catch(() => undefined);
          } else if (err instanceof UnavailableError) {
            item.status = 'unavailable';
            item.error = err.message;
          } else {
            item.status = 'failed';
            item.error = err instanceof NetworkError
              ? `${err.message} The part already sent is kept; tap Retry to continue.`
              : err instanceof Error ? err.message : 'Unknown error.';
          }
        }
        scheduleRender();
      }
    };
    await Promise.all(Array.from({ length: status.concurrency }, worker));

    for (const item of items.current) if (item.status === 'queued') item.status = 'cancelled';
    try {
      const unavailableCount = items.current.filter((i) => i.status === 'unavailable').length;
      setSummary(await api<SessionSummary>('POST', `/sessions/${session.current}/complete`, { unavailableCount }));
    } catch {
      setNotice('The transfer ended but the computer could not be reached for the final report. Check the dashboard on the PC.');
    }
    runningRef.current = false;
    setRunning(false);
  }

  async function pick(e: ChangeEvent<HTMLInputElement>) {
    const files = Array.from(e.target.files ?? []);
    e.target.value = ''; // allow picking the same items again later
    if (files.length === 0) return;
    setNotice('');
    try {
      const created = await api<SessionSummary>('POST', '/sessions', { method: 'safari', selectedCount: files.length });
      session.current = created.id;
    } catch (err) {
      setNotice(err instanceof Error ? err.message : 'Could not start a backup session.');
      return;
    }
    items.current = files.map((file, key) => ({ key, file, status: 'queued', sent: 0 }));
    void run();
  }

  function retryFailed() {
    for (const item of items.current) if (RETRYABLE.includes(item.status)) item.status = 'queued';
    setNotice('');
    void run();
  }

  if (!paired) {
    return (
      <main className="phone">
        <h1>iPhone Photo Backup</h1>
        <Pair onPaired={() => setPaired(true)} />
        <Limits />
      </main>
    );
  }

  const list = items.current;
  const count = (...s: ItemStatus[]) => list.filter((i) => s.includes(i.status)).length;
  const totalBytes = list.reduce((n, i) => n + i.file.size, 0);
  const sentBytes = list.reduce((n, i) => n + (DONE.includes(i.status) ? i.file.size : i.sent), 0);
  const active = list.filter((i) => !DONE.includes(i.status));
  const done = list.filter((i) => DONE.includes(i.status));
  const retryable = count(...RETRYABLE);
  const allGood = summary?.message === COVERAGE_NOTICE;

  return (
    <main className="phone">
      <h1>iPhone Photo Backup</h1>
      {connectError && (
        <div className="card warn">
          <p>{connectError}</p>
          <button onClick={() => void connect()}>Try again</button>
        </div>
      )}
      {status && <p className="muted">Connected to <b>{status.serverName}</b> as “{status.deviceName}”.</p>}
      {notice && <div className="card warn">{notice}</div>}

      {status && !running && (
        <div className="card">
          <label className="pick primary">
            {list.length ? 'Back up more photos & videos' : 'Choose photos & videos'}
            <input type="file" multiple accept="image/*,video/*,.heic,.heif,.dng" onChange={pick} hidden />
          </label>
          <label className="pick">
            Choose from Files instead (keeps originals as stored)
            <input type="file" multiple onChange={pick} hidden />
          </label>
          <label className="check">
            <input type="checkbox" checked={hash} onChange={(e) => setHash(e.target.checked)} />
            <span>Check each file on the iPhone first: photos already backed up are skipped without being sent, and new ones are proven to arrive unchanged</span>
          </label>
          <details className="hint">
            <summary>How do I select everything?</summary>
            <p className="muted small">iOS does not let a web page select your whole library, and its photo picker has no “Select All” button. Two ways around it:</p>
            <ul className="notes">
              <li><b>Swipe to select.</b> In the picker, touch one photo and slide your finger across the row, then down the screen, to select hundreds at once. Keep holding at the edge to keep scrolling.</li>
              <li><b>Use the Shortcut.</b> The optional Apple Shortcut has a “back up everything” mode that needs no picking at all (docs/ios-shortcut.md on the PC).</li>
            </ul>
            <p className="muted small">Selecting photos that are already backed up costs almost nothing: each one is checked on the iPhone and skipped without being sent.</p>
          </details>
          <p className="muted">Tip: use Share → Add to Home Screen to open this page with one tap next time.</p>
        </div>
      )}

      {list.length > 0 && (
        <div className="card">
          <div className="bar"><div style={{ width: `${totalBytes ? (sentBytes / totalBytes) * 100 : 0}%` }} /></div>
          <p className="counts">
            <span>Selected <b>{list.length}</b></span>
            <span>Stored &amp; verified <b>{count('verified')}</b></span>
            <span>Already backed up <b>{count('duplicate')}</b></span>
            <span className={count('failed') ? 'bad' : ''}>Failed <b>{count('failed')}</b></span>
            <span className={count('unavailable') ? 'bad' : ''}>Unavailable <b>{count('unavailable')}</b></span>
          </p>
          <p className="muted">{formatBytes(sentBytes)} of {formatBytes(totalBytes)}</p>
          {running && <button onClick={() => abort.current?.abort()}>Cancel</button>}
          {!running && retryable > 0 && <button className="primary" onClick={retryFailed}>Retry {retryable} unfinished</button>}
        </div>
      )}

      {summary && !running && (
        <div className={`card ${allGood ? 'ok' : 'warn'}`}>
          <b>{summary.message}</b>
          {!allGood && <p className="muted">Only files marked “Stored &amp; verified” or “Already backed up” are safely on the PC.</p>}
        </div>
      )}

      {active.length > 0 && (
        <ul className="files">
          {active.map((item) => <Row key={item.key} item={item} />)}
        </ul>
      )}
      {done.length > 0 && (
        <details className="card">
          <summary>{done.length} safely stored</summary>
          <ul className="files">
            {done.map((item) => <Row key={item.key} item={item} />)}
          </ul>
        </details>
      )}

      <Limits />
      {status && !running && <ShortcutSetup />}
    </main>
  );
}

function Row({ item }: { item: Item }) {
  const { file, status } = item;
  const bad = status === 'failed' || status === 'unavailable';
  return (
    <li className={bad ? 'bad' : ''}>
      <div className="row">
        <span className="name">{file.name || 'unnamed'}</span>
        <span className={`badge ${status}`}>{LABELS[status]}</span>
      </div>
      <div className="muted small">
        {file.type || 'unknown type'} · {formatBytes(file.size)}
        {item.result && (item.result.endToEndVerified ? ' · end-to-end verified' : ' · hashed on PC only')}
      </div>
      {status === 'checking' && <div className="muted small">Checking whether the PC already has this…</div>}
      {(status === 'uploading' || status === 'verifying') && (
        <div className="bar thin"><div style={{ width: `${(item.sent / file.size) * 100}%` }} /></div>
      )}
      {item.error && <div className="error small">{item.error}</div>}
    </li>
  );
}
