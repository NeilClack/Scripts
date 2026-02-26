# 🔒 Restic + Backblaze B2 Backup System

**Encrypted, deduplicated, incremental backups for your home directory.**

This guide covers everything from creating your Backblaze account to restoring your entire `~/Work` directory after a catastrophic drive failure. Read it once now. You'll be grateful later.

---

## Table of Contents

1. [Backblaze B2 Setup](#1--backblaze-b2-setup)
2. [Install & Configure Restic](#2--install--configure-restic)
3. [Initialize the Repository](#3--initialize-the-repository)
4. [Enable Automated Backups](#4--enable-automated-backups)
5. [Restoring Your Data](#5--restoring-your-data)
6. [Day-to-Day Commands](#6--day-to-day-commands)
7. [Troubleshooting](#7--troubleshooting)
8. [VPN Bypass & Polkit](#8--vpn-bypass--polkit)
9. [Architecture Reference](#9--architecture-reference)

---

## 1 · Backblaze B2 Setup

### Create an Account

Head to [backblaze.com](https://www.backblaze.com/cloud-storage) and sign up for a B2 Cloud Storage account. The first 10 GB are free. After that, pricing is:

| Resource       | Cost            |
|----------------|-----------------|
| Storage        | $0.006 / GB·mo  |
| Downloads      | $0.01 / GB      |
| Free egress    | 10 GB / day     |
| API calls      | Negligible      |

> **💡 Tip** — A 500 GB backup costs about **$3/month** to store. You'll barely notice it.

### Create a Bucket

1. Log in to the [B2 Console](https://secure.backblaze.com/b2_buckets.htm)
2. Click **Create a Bucket**
3. Configure it:
   - **Bucket Name:** Something unique, e.g. `neil-workstation-backup`
   - **Files in Bucket:** **Private**
   - **Default Encryption:** **Enable** (server-side; your data is *also* encrypted client-side by restic)
   - **Object Lock:** Leave disabled unless you want immutable backups
   - **Lifecycle Rules:** Leave default (keep all versions)
4. Click **Create a Bucket**

> **⚠️ Important** — Bucket names are globally unique across all of Backblaze. If your name is taken, add a random suffix.

Write down the bucket name. You'll need it.

### Create an Application Key

1. Go to [App Keys](https://secure.backblaze.com/app_keys.htm)
2. Click **Add a New Application Key**
3. Configure it:
   - **Name:** `restic-backup` (or whatever you like)
   - **Bucket:** Select your bucket (restricting scope is good practice)
   - **Type of Access:** **Read and Write**
   - **File Name Prefix:** Leave blank
   - **Duration:** Leave default
4. Click **Create New Key**

You'll see two values:

| Field            | What it is                        | Maps to              |
|------------------|-----------------------------------|----------------------|
| **keyID**        | The short identifier              | `B2_ACCOUNT_ID`      |
| **applicationKey** | The long secret key             | `B2_ACCOUNT_KEY`     |

> **🚨 Critical** — The `applicationKey` is shown **exactly once**. Copy it now. If you lose it, you'll need to generate a new one.

### Store Your Credentials

Create a secure environment file that the systemd service will read:

```bash
mkdir -p ~/.config/restic
cat > ~/.config/restic/b2.env << 'EOF'
B2_ACCOUNT_ID="004a1b2c3d4e5f0000000001"
B2_ACCOUNT_KEY="K004xYzAbCdEfGhIjKlMnOpQrStUvWx"
RESTIC_REPOSITORY="b2:neil-workstation-backup:"
EOF
chmod 600 ~/.config/restic/b2.env
```

> **🔐 Note** — The trailing colon in `b2:bucket-name:` is **required**. It tells restic to use the bucket root. Always quote the values to avoid issues with special characters in keys.

To use these credentials in your current shell:

```bash
set -a && source ~/.config/restic/b2.env && set +a
```

---

## 2 · Install & Configure Restic

### Install

```bash
# Fedora
sudo dnf install restic

# Ubuntu / Debian
sudo apt install restic

# Or grab the latest binary directly
curl -LO https://github.com/restic/restic/releases/latest/download/restic_0.17.3_linux_amd64.bz2
bunzip2 restic_*.bz2
chmod +x restic_*
sudo mv restic_* /usr/local/bin/restic
```

Verify:

```bash
restic version
```

### Place the Backup Scripts

```bash
mkdir -p ~/Scripts/backup/restic
# Move all files into this directory:
#   backup.sh, backup.exclude
#   rbackup.sh, rbackup.exclude
#   restic-backup.service, restic-backup.timer
#   rbackup.service, rbackup.timer

chmod +x ~/Scripts/backup/restic/backup.sh
chmod +x ~/Scripts/backup/restic/rbackup.sh
```

### Create Command Symlinks

```bash
mkdir -p ~/.local/bin
ln -sf ~/Scripts/backup/restic/backup.sh ~/.local/bin/backup
ln -sf ~/Scripts/backup/restic/rbackup.sh ~/.local/bin/rbackup
```

Your directory should look like:

```
~/Scripts/backup/restic/
├── backup.sh                            # Cloud backup script (restic + B2)
├── backup.exclude                       # Cloud backup exclude patterns
├── 49-restic-backup-ip-route.rules      # Polkit rule for VPN bypass (see §8)
├── restic-backup.service                # systemd service (cloud, every 30 min)
├── restic-backup.timer                  # systemd timer (cloud)
├── rbackup.sh                           # Local backup script (rsync)
├── rbackup.exclude                      # Local backup exclude patterns (+ lock files)
├── rbackup.service                      # systemd service (local, every 10 min)
├── rbackup.timer                        # systemd timer (local)
├── restic-backblaze-setup-guide.md      # This guide
└── .repo-password.gpg                   # Created during init (GPG-encrypted repo password)
```

---

## 3 · Initialize the Repository

Load your credentials and run init:

```bash
set -a && source ~/.config/restic/b2.env && set +a
cd ~/Scripts/backup/restic
./backup.sh init
```

This will:

1. Generate a strong random password for the restic repository
2. Show your available GPG keys and ask which one to use
3. Encrypt the password with your GPG key → `.repo-password.gpg`
4. Initialize the restic repository in your B2 bucket

> **🔐 Your encryption chain:**
>
> ```
> Your data
>   └─ encrypted by → restic (AES-256-CTR + Poly1305)
>       └─ repo password encrypted by → your GPG key
>           └─ GPG private key stored in → Proton Drive
> ```
>
> To access your backups you need: **restic** + **the `.repo-password.gpg` file** + **your GPG private key**.
> Lose any one of these and your backups are unrecoverable.

### Verify the Repo Password

To confirm the encrypted password file works:

```bash
gpg --decrypt ~/Scripts/backup/restic/.repo-password.gpg
```

This will prompt for your GPG passphrase and print the raw restic repo password.

### Run Your First Backup

```bash
./backup.sh backup
```

> **💡 Tip** — The first backup uploads everything and will take a while depending on the size of `~/Work` and your upload speed. Run it manually and watch it. Every backup after this is incremental and fast.

---

## 4 · Enable Automated Backups

### Cloud Backup (restic, every 30 minutes)

```bash
backup install
```

### Local Backup (rsync, every 10 minutes)

```bash
rbackup --install
```

Both commands walk you through the setup interactively. Or do it manually:

```bash
mkdir -p ~/.config/systemd/user

# Cloud backup
ln -sf ~/Scripts/backup/restic/restic-backup.service ~/.config/systemd/user/
ln -sf ~/Scripts/backup/restic/restic-backup.timer   ~/.config/systemd/user/

# Local backup
ln -sf ~/Scripts/backup/restic/rbackup.service ~/.config/systemd/user/
ln -sf ~/Scripts/backup/restic/rbackup.timer   ~/.config/systemd/user/

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now restic-backup.timer
systemctl --user enable --now rbackup.timer
```

### Verify They're Running

```bash
systemctl --user list-timers
```

### Enable Linger

Without this, your user timers **stop when you log out**:

```bash
loginctl enable-linger $(whoami)
```

> **⚠️ Important** — This is required for backups to run when you're logged out, SSHing in, or if your machine reboots into a login screen without you signing in. Don't skip it.

---

## 5 · Restoring Your Data

**This is the part that matters. Read this section now, while your backups are working. Not when you're panicking.**

### Scenario: Fresh OS Install, Need Everything Back

You've written an installer to the wrong drive. Again. Here's how to get back:

#### Step 1 — Install restic and GPG on the fresh system

```bash
sudo dnf install restic gnupg2    # or apt install
```

#### Step 2 — Recover your GPG private key from Proton Drive

Log into [Proton Drive](https://drive.proton.me) from a browser, download your GPG private key, and import it:

```bash
gpg --import /path/to/your-private-key.asc
# Verify it's there
gpg --list-secret-keys
```

#### Step 3 — Recreate your credentials

You'll need your B2 credentials. Log into [Backblaze](https://secure.backblaze.com/app_keys.htm) and create a new application key (the old one was in `~/.config/restic/b2.env` which is in your backup, but you need credentials to access the backup).

```bash
mkdir -p ~/.config/restic
cat > ~/.config/restic/b2.env << 'EOF'
B2_ACCOUNT_ID="your-key-id"
B2_ACCOUNT_KEY="your-application-key"
RESTIC_REPOSITORY="b2:your-bucket-name:"
EOF
chmod 600 ~/.config/restic/b2.env
set -a && source ~/.config/restic/b2.env && set +a
```

#### Step 4 — Get the encrypted repo password

The `.repo-password.gpg` file was in your backup (it's inside `~/Scripts/backup/restic/`). But you need it *to access* the backup. Chicken-and-egg problem.

> **🚨 Solve this NOW while things are working:**
>
> ```bash
> # Upload .repo-password.gpg to Proton Drive alongside your GPG key
> # This is your recovery lifeline
> ```
>
> You can also print the decrypted password and store it physically:
>
> ```bash
> gpg --decrypt ~/Scripts/backup/restic/.repo-password.gpg
> # Write this down. Put it somewhere safe and offline.
> ```

Once you have the `.repo-password.gpg` file on the fresh system:

```bash
mkdir -p ~/Scripts/backup/restic
cp /path/to/.repo-password.gpg ~/Scripts/backup/restic/
```

#### Step 5 — Decrypt the repo password and export it

```bash
export RESTIC_PASSWORD=$(gpg --quiet --decrypt ~/Scripts/backup/restic/.repo-password.gpg)
```

#### Step 6 — Browse available snapshots

```bash
restic snapshots --compact
```

You'll see output like:

```
ID        Time                 Host        Tags
────────────────────────────────────────────────
a1b2c3d4  2026-02-09 14:30:00  neil-pc     scheduled
e5f6a7b8  2026-02-09 14:00:00  neil-pc     scheduled
c9d0e1f2  2026-02-09 13:30:00  neil-pc     scheduled
...
```

#### Step 7 — Restore

**Option A: Restore everything to a staging directory (safest)**

```bash
restic restore latest --target ~/Restore
```

Then move things into place:

```bash
# Inspect what's there
ls ~/Restore/home/neil/

# Move what you need
cp -a ~/Restore/home/neil/Work ~/Work
cp -a ~/Restore/home/neil/.config ~/.config
cp -a ~/Restore/home/neil/.ssh ~/.ssh
cp -a ~/Restore/home/neil/Scripts ~/Scripts
# ... etc
```

**Option B: Restore directly to home (faster, riskier)**

```bash
restic restore latest --target /
```

> **⚠️ Warning** — This overwrites existing files. On a fresh install this is generally fine, but Option A is safer because you can inspect before committing.

**Option C: Restore specific files or directories**

```bash
# Restore just ~/Work
restic restore latest --target ~/Restore --include /home/neil/Work

# Restore a single file
restic restore latest --target ~/Restore --include /home/neil/.gitconfig
```

**Option D: Browse backups interactively with FUSE mount**

```bash
mkdir -p ~/mnt/restic
restic mount ~/mnt/restic
```

Then in another terminal:

```bash
ls ~/mnt/restic/snapshots/
# Each snapshot is a directory you can browse and copy from
cp ~/mnt/restic/snapshots/latest/home/neil/Work/important-project ~/Work/
```

Press `Ctrl+C` in the first terminal to unmount.

#### Step 8 — Update credentials and re-enable backups

The restored `~/.config/restic/b2.env` will have the old application key. Update it with the new one you created in Step 3, then:

```bash
cd ~/Scripts/backup/restic
chmod +x backup.sh rbackup.sh
mkdir -p ~/.local/bin
ln -sf ~/Scripts/backup/restic/backup.sh ~/.local/bin/backup
ln -sf ~/Scripts/backup/restic/rbackup.sh ~/.local/bin/rbackup
backup install
rbackup --install
```

You're back in business.

---

## 6 · Day-to-Day Commands

### Cloud Backup (restic)

| Command                    | What it does                                    |
|----------------------------|-------------------------------------------------|
| `backup backup`           | Run an incremental backup right now              |
| `backup snapshots`        | List all available snapshots                     |
| `backup stats`            | Show repository size and dedup ratio             |
| `backup check`            | Verify repository integrity (run monthly)        |
| `backup prune`            | Apply retention policy and free space            |
| `backup restore`          | Restore latest snapshot to `~/Restore`           |
| `backup restore <id>`     | Restore a specific snapshot                      |
| `backup mount`            | FUSE-mount the repo for browsing                 |
| `backup unlock`           | Clear stale locks after interrupted backup       |
| `backup journal`          | Show recent systemd journal entries              |
| `backup install`          | Walk through systemd timer setup                 |
| `backup help`             | Full help text                                   |

### Local Backup (rsync)

| Command                      | What it does                                  |
|------------------------------|-----------------------------------------------|
| `rbackup`                   | Mirror home → backup drive                     |
| `rbackup --restore`         | Restore backup → home (safe, no deletes)       |
| `rbackup --restore --delete`| Restore backup → home (full mirror)            |
| `rbackup --dry-run`         | Preview what would change                      |
| `rbackup --status`          | Show backup age, size, drive space             |
| `rbackup --journal`         | Show recent systemd journal entries            |
| `rbackup --install`         | Walk through systemd timer setup               |
| `rbackup --help`            | Full help text                                 |

---

## 7 · Troubleshooting

### "Fatal: unable to open config file" / 401 errors

The repository can't be reached, or your credentials are wrong.

```bash
# Verify your env vars are loaded
echo $RESTIC_REPOSITORY    # Should show b2:bucket-name:
echo $B2_ACCOUNT_ID        # Should show your key ID

# Re-source if needed
set -a && source ~/.config/restic/b2.env && set +a
```

> **⚠️ Common gotcha** — The trailing colon in `b2:bucket-name:` is required. Without it, restic can't parse the path and auth fails before reaching Backblaze.

> **⚠️ Special characters** — If your application key contains `/` or other special characters, make sure the values in `b2.env` are quoted.

### "Fatal: wrong password or no key found"

Your `RESTIC_PASSWORD` doesn't match the repository. This means either:

- The `.repo-password.gpg` file is from a different repository
- Your GPG key can't decrypt it (wrong key or corrupted keyring)

```bash
# Test GPG decryption directly
gpg --decrypt ~/Scripts/backup/restic/.repo-password.gpg
```

### Backup seems stuck or slow

```bash
# Check what restic is doing
backup journal

# If it's locked from a previous interrupted run
backup unlock
```

### Timer not firing

```bash
# Is the timer active?
systemctl --user status restic-backup.timer

# Is linger enabled?
loginctl show-user $(whoami) | grep Linger
# Should show Linger=yes

# Did systemd see the files?
systemctl --user daemon-reload
systemctl --user list-timers
```

### GPG asks for passphrase and hangs in systemd

The systemd service runs non-interactively. If your GPG key has a passphrase (it should), you need `gpg-agent` to cache it:

```bash
# Pre-cache your GPG passphrase for the session
gpg --decrypt ~/Scripts/backup/restic/.repo-password.gpg > /dev/null

# Extend agent cache timeout (add to ~/.gnupg/gpg-agent.conf)
default-cache-ttl 86400
max-cache-ttl 86400
```

Then reload: `gpgconf --kill gpg-agent`

> **💡 Tip** — Alternatively, you can configure `pinentry-gnome3` or `pinentry-tty` depending on your session type. See `man gpg-agent` for details.

### Backup hangs or times out with Proton VPN active

The VPN bypass should handle this automatically. If it's not working:

```bash
# Is the polkit rule installed?
ls -la /etc/polkit-1/rules.d/49-restic-backup-ip-route.rules

# If missing, install it:
backup install   # Follow the polkit step

# Test pkexec manually (should NOT prompt for password):
pkexec /usr/bin/ip route show
```

If `pkexec` still prompts for a password, the polkit rule isn't being picked up. Check that the file is owned by root and has mode 644.

### No desktop notifications from systemd timer

The service files pass `DISPLAY`, `WAYLAND_DISPLAY`, and `DBUS_SESSION_BUS_ADDRESS` to enable notifications. If they're not working:

```bash
# Check if the variables are set in your session
echo $DISPLAY $WAYLAND_DISPLAY $DBUS_SESSION_BUS_ADDRESS

# Test notify-send directly
notify-send "Test" "Does this work?"
```

---

## 8 · VPN Bypass & Polkit

### The Problem

When Proton VPN is active, all traffic routes through the VPN tunnel. Backblaze B2 connections hang or time out through the Proton tunnel, causing backups to fail. This is a known issue with Proton VPN and certain cloud storage providers.

### The Solution

The backup script detects when Proton VPN is active (by checking for a `proton*` network device in the default route) and temporarily adds **host routes** for Backblaze B2 IP addresses. These routes send B2 traffic via the local (non-VPN) gateway instead of through the tunnel.

How it works:

1. **`setup_vpn_bypass()`** — Runs before any restic command that contacts B2. Resolves all Backblaze endpoints (`api.backblazeb2.com`, `f000-f005.backblazeb2.com`) to IP addresses, then adds a `/32` host route for each IP via the local gateway using `pkexec /usr/bin/ip route add`.
2. **`teardown_vpn_bypass()`** — Registered as an `EXIT` trap. Removes all the host routes that were added, restoring normal routing.

When no VPN is detected, both functions are no-ops.

### Why pkexec + polkit (not sudo)

Adding routes requires root privileges. The options were:

| Approach | Problem |
|----------|---------|
| `sudo` with NOPASSWD sudoers rule | Works, but requires maintaining a sudoers drop-in file and `sudo` in non-interactive systemd services can be finicky |
| `pkexec` with polkit rule | Native D-Bus privilege escalation, designed for exactly this use case, works cleanly from systemd user services |

The polkit approach is the standard Freedesktop way to grant specific root privileges to a user without a password.

### The Polkit Rule

The file `49-restic-backup-ip-route.rules` contains:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.policykit.exec" &&
        action.lookup("program") === "/usr/bin/ip" &&
        subject.user === "nclack") {
        return polkit.Result.YES;
    }
});
```

**What this allows:** User `nclack` can run `/usr/bin/ip` (and only `/usr/bin/ip`) via `pkexec` without a password prompt.

**What this does NOT allow:** It does not grant blanket root access. Only the `ip` command is authorized, and only via `pkexec` (not `sudo`). Other users are unaffected.

**File naming:** The `49-` prefix controls evaluation order. Polkit processes rules files in lexicographic order; `49` runs before the default `50-default.rules` that would otherwise prompt for a password.

### Installing the Rule

The rule file lives in the script directory and gets copied to the system polkit directory during setup:

```bash
# Automatic (via the install command)
backup install    # Offers to install the polkit rule as step 1

# Manual
sudo cp ~/Scripts/backup/restic/49-restic-backup-ip-route.rules /etc/polkit-1/rules.d/
sudo chmod 644 /etc/polkit-1/rules.d/49-restic-backup-ip-route.rules
```

No restart is needed — polkit picks up new rules immediately.

### Verifying It Works

```bash
# Should run without a password prompt:
pkexec /usr/bin/ip route show

# With Proton VPN connected, run any B2-contacting command:
backup snapshots
# Check that bypass routes were added:
ip route | grep backblaze  # (nothing after the command completes — cleanup removes them)
```

### Security Considerations

- The rule is scoped to a single user (`nclack`) and a single program (`/usr/bin/ip`)
- `ip route add/del` only modifies the routing table — it cannot read files, execute programs, or escalate further
- On a new system, you must explicitly install the rule via `backup install` (it's not automatic)
- If you change your username, update the `subject.user` field in the rules file

---

## 9 · Architecture Reference

### What Gets Backed Up

Everything in `$HOME` that isn't explicitly excluded. See `backup.exclude` and `rbackup.exclude` for the full list of exclusions.

### What Gets Excluded (both backups)

| Pattern              | Why                                                    |
|----------------------|--------------------------------------------------------|
| `~/Downloads`        | Transient junk                                         |
| `**/.cache`          | Regenerable app caches                                 |
| `**/__pycache__`     | Python bytecode — recreated on import                  |
| `**/node_modules`    | Massive, fully reproducible from package.json          |
| `**/.venv`, `**/venv`| Python venvs — reproducible from requirements.txt      |
| `**/target/`         | Rust/Java build output                                 |
| `**/*.iso`, `**/*.img`| Disk images — kept on a second drive                  |
| `**/*.o`, `**/*.so`  | Compiled objects — rebuilt by make/gcc                  |
| `.Trash*`            | Trash contents                                         |
| `.mozilla`, browsers | Huge profiles, synced via browser accounts             |
| `.local/share/Steam` | Game installs, re-downloadable                         |
| `.local/share/flatpak`| App installs, reinstallable from repos               |
| Containers/Podman    | Reproducible from Containerfiles                       |

### Additional Excludes (local backup only)

| Pattern              | Why                                                    |
|----------------------|--------------------------------------------------------|
| `**/*.lock`          | Runtime lock files (not dependency manifests)           |
| `**/SingletonLock`   | Browser singleton locks                                |
| `.gnupg/*.lock`      | GPG agent locks                                        |
| `.dbus`              | Desktop bus runtime                                    |

> **Note** — Dependency lock files (`package-lock.json`, `Cargo.lock`, `poetry.lock`, `yarn.lock`, `Gemfile.lock`, `composer.lock`, `flake.lock`) are explicitly **preserved** via `!` exceptions.

### Retention Policy (cloud)

| Window  | Kept     |
|---------|----------|
| Daily   | 7 days   |
| Weekly  | 4 weeks  |
| Monthly | 6 months |
| Yearly  | 1 year   |

### Timer Schedule

| Backup | Interval    | Notes                                        |
|--------|-------------|----------------------------------------------|
| Cloud  | 30 minutes  | 2-min jitter, persistent across sleep         |
| Local  | 10 minutes  | 30-sec jitter, skips if drive not mounted     |

---

## Recovery Checklist

Print this. Pin it to your wall. Tape it inside your laptop lid.

```
┌─────────────────────────────────────────────────────────┐
│               DISASTER RECOVERY CHECKLIST                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ☐ GPG private key        →  Proton Drive               │
│  ☐ .repo-password.gpg     →  Proton Drive               │
│  ☐ Restic repo password   →  Written down, stored safe  │
│  ☐ B2 account email       →  You remember it, right?    │
│  ☐ B2 bucket name         →  ___________________        │
│                                                         │
│  RESTORE STEPS:                                         │
│  1. Install Fedora                                      │
│  2. sudo dnf install restic gnupg2                      │
│  3. Import GPG key from Proton Drive                    │
│  4. Download .repo-password.gpg from Proton Drive       │
│  5. Log into Backblaze, create new app key              │
│  6. Create ~/.config/restic/b2.env (QUOTE THE VALUES)   │
│  7. set -a && source ~/.config/restic/b2.env && set +a  │
│  8. export RESTIC_PASSWORD=$(gpg -qd .repo-password.gpg)│
│  9. restic snapshots --compact                          │
│  10. restic restore latest --target ~/Restore           │
│  11. Move files into place                              │
│  12. Update b2.env with new app key                     │
│  13. Re-run backup install & rbackup --install          │
│      (installs polkit rule + systemd timers)            │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

*Last updated: February 2026*
