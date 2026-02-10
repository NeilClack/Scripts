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
8. [Architecture Reference](#8--architecture-reference)

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
B2_ACCOUNT_ID=004a1b2c3d4e5f0000000001
B2_ACCOUNT_KEY=K004xYzAbCdEfGhIjKlMnOpQrStUvWx
RESTIC_REPOSITORY=b2:nclack-restic-backup:
EOF
chmod 600 ~/.config/restic/b2.env
```

> **🔐 Note** — The trailing colon in `b2:bucket-name:` is required. It tells restic to use the bucket root.

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
# Move all four files into this directory:
#   backup.sh
#   backup.exclude
#   restic-backup.service
#   restic-backup.timer

chmod +x ~/Scripts/backup/restic/backup.sh
```

Your directory should look like:

```
~/Scripts/backup/restic/
├── backup.sh                 # Main script — all commands live here
├── backup.exclude            # Exclude patterns (node_modules, caches, etc.)
├── restic-backup.service     # systemd service unit
├── restic-backup.timer       # systemd timer (every 30 minutes)
└── .repo-password.gpg        # Created during init (GPG-encrypted repo password)
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

### Run Your First Backup

```bash
./backup.sh backup
```

> **💡 Tip** — The first backup uploads everything and will take a while depending on the size of `~/Work` and your upload speed. Run it manually and watch it. Every backup after this is incremental and fast.

---

## 4 · Enable Automated Backups

The `install` command walks you through everything interactively:

```bash
./backup.sh install
```

Or do it manually:

```bash
# Create the systemd user directory
mkdir -p ~/.config/systemd/user

# Symlink (not copy!) so edits to the originals take effect immediately
ln -sf ~/Scripts/backup/restic/restic-backup.service ~/.config/systemd/user/
ln -sf ~/Scripts/backup/restic/restic-backup.timer   ~/.config/systemd/user/

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now restic-backup.timer
```

### Verify It's Running

```bash
# Check the timer
systemctl --user status restic-backup.timer

# See upcoming schedule
systemctl --user list-timers

# Watch a backup in real time
journalctl --user -u restic-backup.service -f
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

You'll need your B2 credentials. If you don't have them memorized (you shouldn't), log into [Backblaze](https://secure.backblaze.com/app_keys.htm) and create a new application key.

```bash
mkdir -p ~/.config/restic
cat > ~/.config/restic/b2.env << 'EOF'
B2_ACCOUNT_ID=your-key-id
B2_ACCOUNT_KEY=your-application-key
RESTIC_REPOSITORY=b2:neil-workstation-backup:
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

#### Step 8 — Re-enable automated backups

```bash
# Grab the backup scripts from the restore
cd ~/Scripts/backup/restic
./backup.sh install
```

You're back in business.

---

## 6 · Day-to-Day Commands

| Command                    | What it does                                    |
|----------------------------|-------------------------------------------------|
| `backup.sh backup`        | Run an incremental backup right now              |
| `backup.sh snapshots`     | List all available snapshots                     |
| `backup.sh stats`         | Show repository size and dedup ratio             |
| `backup.sh check`         | Verify repository integrity (run monthly)        |
| `backup.sh prune`         | Apply retention policy and free space            |
| `backup.sh restore`       | Restore latest snapshot to `~/Restore`           |
| `backup.sh restore <id>`  | Restore a specific snapshot                      |
| `backup.sh mount`         | FUSE-mount the repo for browsing                 |
| `backup.sh unlock`        | Clear stale locks after interrupted backup       |
| `backup.sh install`       | Walk through systemd timer setup                 |
| `backup.sh help`          | Full help text                                   |

---

## 7 · Troubleshooting

### "Fatal: unable to open config file"

The repository hasn't been initialized, or your credentials are wrong.

```bash
# Verify your env vars are loaded
echo $RESTIC_REPOSITORY    # Should show b2:bucket-name:
echo $B2_ACCOUNT_ID        # Should show your key ID

# Re-source if needed
set -a && source ~/.config/restic/b2.env && set +a
```

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
journalctl --user -u restic-backup.service -f

# If it's locked from a previous interrupted run
./backup.sh unlock
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

---

## 8 · Architecture Reference

### What Gets Backed Up

| Path                 | Why                                                    |
|----------------------|--------------------------------------------------------|
| `~/Work`             | All project files — the primary target                 |
| `~/Scripts`          | Automation and tooling (including this backup system)  |
| `~/.config`          | Application configs, desktop settings, terminal prefs  |
| `~/.local/share`     | App data, keyrings, fonts, bash history                |
| `~/.ssh`             | SSH keys and config                                    |
| `~/.gnupg`           | GPG keyring and trust database                         |
| `~/.bashrc`          | Shell configuration                                    |
| `~/.bash_profile`    | Login shell configuration                              |
| `~/.profile`         | Session-wide environment                               |
| `~/.bash_aliases`    | Shell aliases                                          |
| `~/.gitconfig`       | Git configuration                                      |
| `~/.tmux.conf`       | tmux configuration                                     |

### What Gets Excluded

| Pattern              | Why                                                    |
|----------------------|--------------------------------------------------------|
| `~/Downloads`        | Transient junk                                         |
| `**/.cache`          | Regenerable app caches                                 |
| `**/__pycache__`     | Python bytecode — recreated on import                  |
| `**/node_modules`    | Massive, fully reproducible from package.json          |
| `**/.venv`, `**/venv`| Python venvs — reproducible from requirements.txt      |
| `**/target/`         | Rust/Java build output                                 |
| `**/*.iso`, `**/*.img`| Disk images — you're keeping these on a second drive  |
| `**/*.o`, `**/*.so`  | Compiled objects — rebuilt by make/gcc                  |
| `.Trash*`            | Trash contents                                         |

### Retention Policy

| Window  | Kept     |
|---------|----------|
| Daily   | 7 days   |
| Weekly  | 4 weeks  |
| Monthly | 6 months |
| Yearly  | 1 year   |

### Timer Schedule

Backups fire every **30 minutes** with a 2-minute jitter window. Missed backups (laptop sleep, reboot) are caught up automatically via `Persistent=true`.

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
│  6. restic restore latest --target ~/Restore            │
│  7. Move files into place                               │
│  8. Re-run backup.sh install                            │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

*Last updated: February 2026*
