# Mac mini (`mewtMini` · Linux Mint) 24/7 Server Setup & Migration Guide

Run Mewt Photos continuously on your Mac mini (`mewtMini`, `192.168.4.20`, Linux Mint 22.3),
storing backups on the external 1 TB drive at `/mnt/external/Media/iphonePhotosBackup`
(shared over Samba as `\\192.168.4.20\External\Media\iphonePhotosBackup`).

> **Port note:** Port `8787` on `mewtMini` is already used by `altkeeper`. Mewt Photos runs on
> port **`8788`** (`http://192.168.4.20:8788` for the iPhone; `http://127.0.0.1:8788/dashboard`
> for the loopback-only admin dashboard).

## 1. Docker Compose Deployment (Recommended — Matches `mewtplay-server` & `audiobookshelf`)

The server lives in `/home/mewt/codes/mewtphotos` and runs as `mewtphotos-server` via Docker Compose
(`network_mode: host`, `user: 1000:1000`, `restart: unless-stopped`):

```bash
cd /home/mewt/codes/mewtphotos
mkdir -p data /mnt/external/Media/iphonePhotosBackup
docker compose -f deploy/linux-mint/docker-compose.yml up -d --build
```

Check status, health, and logs (including the startup pairing QR code):
```bash
docker ps --filter name=mewtphotos-server
docker logs --tail 50 mewtphotos-server
curl -s http://127.0.0.1:8788/api/v1/health
```

Run an on-demand full SHA-256 verification pass inside the container:
```bash
docker exec mewtphotos-server npm run verify
```

## 2. Accessing the Dashboard from Your Windows PC

The admin dashboard and `/api/v1/admin/*` routes stay strictly bound to `127.0.0.1:8788` on `mewtMini`.
Open it safely from Windows via SSH port forwarding:

```powershell
ssh -L 8788:127.0.0.1:8788 mewt@192.168.4.20
```

Then open **http://127.0.0.1:8788/dashboard** in your Windows browser to view live transfers,
logs, settings, paired devices, and the QR pairing code.

## 3. Optional Native `systemd` Units

If you ever prefer running directly with host Node.js (≥ 22.18) instead of Docker, pre-configured
units are also provided in `deploy/linux-mint/`:
- `mewtphotos.env.example` (pinned to `192.168.4.20:8788` and `/mnt/external/Media/iphonePhotosBackup`)
- `mewtphotos.service` (includes `RequiresMountsFor=/mnt/external`)
- `mewtphotos-verify.service` & `mewtphotos-verify.timer` (weekly SHA-256 integrity check)

If you enable UFW on `mewtMini`, allow your `/22` LAN subnet on port `8788`:
```bash
sudo ufw allow from 192.168.4.0/22 to any port 8788 proto tcp
```

## 4. Migrating Existing Windows Backups & `mewtphotos.db`

Because `mewtphotos.db` stores absolute Windows paths (`C:\Users\...\Pictures\iPhone Backup\YYYY\MM\...`),
rewrite them before starting `mewtphotos-server` on migrated data so your existing archive, `asset_id`
history, and iPhone device key carry over seamlessly without re-uploading:

1. **Stop Mewt Photos** on Windows and stop the container on `mewtMini`:
   ```bash
   docker stop mewtphotos-server
   ```
2. **Copy the backup folder contents** from Windows into `/mnt/external/Media/iphonePhotosBackup`
   (e.g., via Samba `\\192.168.4.20\External\Media\iphonePhotosBackup` or `rsync`, preserving `YYYY/MM/...`).
3. **Copy `%LOCALAPPDATA%\MewtPhotos\mewtphotos.db`** (plus any `-wal`/`-shm` files if present)
   to `/home/mewt/codes/mewtphotos/data/mewtphotos.db` (keep a backup copy on Windows).
4. **Dry-run, then apply the path migration script** (replace `YourName` with your Windows path):
   ```bash
   docker run --rm --user 1000:1000 \
     -v /home/mewt/codes/mewtphotos/data:/home/mewt/codes/mewtphotos/data \
     linux-mint-mewtphotos \
     node --disable-warning=ExperimentalWarning scripts/migrate-db-paths.ts \
     --db /home/mewt/codes/mewtphotos/data/mewtphotos.db \
     --from "C:\Users\YourName\Pictures\iPhone Backup" \
     --to "/mnt/external/Media/iphonePhotosBackup" \
     --dry-run
   ```
   Remove `--dry-run` to apply.
5. **Cryptographically verify every migrated file on disk:**
   ```bash
   docker start mewtphotos-server
   docker exec mewtphotos-server npm run verify
   ```
   Confirm `0 missing, 0 corrupt, 0 database problems`.
6. **Point your iPhone at `mewtMini`:**
   Open **Mewt Photos** → **Server** tab → **Edit address** → enter **`http://192.168.4.20:8788`** → **Save**.
   Your existing Keychain device key stays valid without re-pairing!
