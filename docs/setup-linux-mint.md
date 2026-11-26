# Mac mini (Linux Mint) 24/7 Server Setup & Migration Guide

Run Mewt Photos continuously on your Mac mini (`192.168.4.20`) running Linux Mint, storing backups in
`/Media/iphonePhotosBackup` over your home LAN. No cloud, no paid services, and the admin dashboard
stays loopback-only (`127.0.0.1`) so no extra LAN password surface is exposed.

## 1. Prerequisites on the Mac mini (`192.168.4.20`)

1. **Node.js ≥ 22.18 (Node 24 LTS recommended):**
   ```bash
   node -v
   ```
   If older than `22.18`, install Node 24 LTS:
   ```bash
   curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
   sudo apt-get install -y nodejs
   ```

2. **Disable sleep / suspend so backups work 24/7:**
   ```bash
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   ```

3. **Keep `192.168.4.20` pinned** via a static DHCP reservation on your router (or static IP in Linux Mint Network Settings).

4. **Allow port `8787` on your local LAN only (UFW):**
   ```bash
   sudo ufw allow from 192.168.4.0/24 to any port 8787 proto tcp
   sudo ufw status
   ```

## 2. Install Mewt Photos

```bash
sudo useradd --system --create-home --shell /usr/sbin/nologin mewtphotos || true
sudo mkdir -p /opt/mewtphotos /var/lib/mewtphotos /Media/iphonePhotosBackup
sudo git clone <your-repo-url> /opt/mewtphotos
cd /opt/mewtphotos
sudo npm ci
sudo npm run build
sudo chown -R mewtphotos:mewtphotos /opt/mewtphotos /var/lib/mewtphotos /Media/iphonePhotosBackup
```

> **Note on `/Media` permissions:** If `/Media` is an external drive or secondary partition mounted in `/etc/fstab`:
> - Mount it permanently by UUID with `nofail,x-systemd.automount`.
> - Ensure the `mewtphotos` user has read/write permission on `/Media/iphonePhotosBackup` (for `ext4`, `chown -R mewtphotos:mewtphotos /Media/iphonePhotosBackup`; for `exfat`/`ntfs`, set `uid`/`gid` or `umask=000` in `/etc/fstab` or run the service as your Linux user).
> - `mewtphotos.service` already includes `RequiresMountsFor=/Media` so the server will never accidentally write to the root OS partition if `/Media` isn't mounted.

## 3. Configure `systemd` (24/7 Service + Weekly SHA-256 Verify)

`deploy/linux-mint/mewtphotos.env.example` is pre-configured with `MEWTPHOTOS_HOST=192.168.4.20` and `MEWTPHOTOS_BACKUP_DIR=/Media/iphonePhotosBackup`.

```bash
sudo cp /opt/mewtphotos/deploy/linux-mint/mewtphotos.env.example /etc/mewtphotos.env
sudo chmod 640 /etc/mewtphotos.env
sudo chown root:mewtphotos /etc/mewtphotos.env

sudo cp /opt/mewtphotos/deploy/linux-mint/mewtphotos.service /etc/systemd/system/
sudo cp /opt/mewtphotos/deploy/linux-mint/mewtphotos-verify.service /etc/systemd/system/
sudo cp /opt/mewtphotos/deploy/linux-mint/mewtphotos-verify.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now mewtphotos.service
sudo systemctl enable --now mewtphotos-verify.timer
```

Check status and logs (including the startup pairing QR code):
```bash
sudo systemctl status mewtphotos.service
journalctl -u mewtphotos.service -n 50 --no-pager
```

## 4. Accessing the Dashboard from Your Windows PC

The admin dashboard and `/api/v1/admin/*` routes stay bound to `127.0.0.1` on the Mac mini.
Open it safely from Windows via SSH port forwarding:

```powershell
ssh -L 8787:127.0.0.1:8787 <linux-user>@192.168.4.20
```

Then open **http://127.0.0.1:8787/dashboard** in your Windows browser to view live transfers,
logs, settings, paired devices, and the QR pairing code.

## 5. Migrating Existing Windows Backups & `mewtphotos.db`

Because `mewtphotos.db` stores absolute Windows paths (`C:\Users\...\Pictures\iPhone Backup\YYYY\MM\...`),
rewrite them before starting the Linux Mint service so your existing archive, `asset_id` history,
and iPhone device key carry over seamlessly without re-uploading:

1. **Stop Mewt Photos on Windows** (and keep a backup copy of `mewtphotos.db`).
2. **Copy the backup folder** (`iPhone Backup\`) contents from Windows into `/Media/iphonePhotosBackup` on the Mac mini (so `/Media/iphonePhotosBackup/2026/...` matches the folder structure).
3. **Copy `%LOCALAPPDATA%\MewtPhotos\mewtphotos.db`** (and any `-wal`/`-shm` files if present) to `/var/lib/mewtphotos/mewtphotos.db` and set ownership (`sudo chown mewtphotos:mewtphotos /var/lib/mewtphotos/mewtphotos.db*`).
4. **Dry-run, then apply the path migration script** (replace `YourName` with your Windows path):
   ```bash
   # Preview changes first (no writes):
   sudo -u mewtphotos node --disable-warning=ExperimentalWarning /opt/mewtphotos/scripts/migrate-db-paths.ts \
     --db /var/lib/mewtphotos/mewtphotos.db \
     --from "C:\Users\YourName\Pictures\iPhone Backup" \
     --to "/Media/iphonePhotosBackup" \
     --dry-run

   # Apply migration:
   sudo -u mewtphotos node --disable-warning=ExperimentalWarning /opt/mewtphotos/scripts/migrate-db-paths.ts \
     --db /var/lib/mewtphotos/mewtphotos.db \
     --from "C:\Users\YourName\Pictures\iPhone Backup" \
     --to "/Media/iphonePhotosBackup"
   ```
5. **Cryptographically verify every migrated file on disk:**
   ```bash
   sudo -u mewtphotos MEWTPHOTOS_DATA_DIR=/var/lib/mewtphotos npm --prefix /opt/mewtphotos run verify
   ```
   Confirm `0 missing, 0 corrupt, 0 database problems` before starting the service.
6. **Start the service:**
   ```bash
   sudo systemctl start mewtphotos.service
   ```
7. **Point your iPhone at the Mac mini:**
   Open **Mewt Photos** → **Server** tab → **Edit address** → enter **`http://192.168.4.20:8787`** → **Save**.
   Your existing Keychain device key stays valid without re-pairing!
