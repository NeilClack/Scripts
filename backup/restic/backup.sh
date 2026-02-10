#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# restic-backup — Encrypted incremental backup to Backblaze B2
# Location: ~/Scripts/backup/restic/backup.sh
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PASSWORD_GPG="${SCRIPT_DIR}/.repo-password.gpg"
EXCLUDE_FILE="${SCRIPT_DIR}/backup.exclude"
LOG_DIR="${HOME}/.local/share/restic-backup"
LOG_FILE="${LOG_DIR}/backup.log"

# What to back up — everything in $HOME that isn't excluded
BACKUP_PATH="${HOME}"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
KEEP_YEARLY=1

# ── Color output ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

# ── Environment check ────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in restic gpg; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required commands: ${missing[*]}"
        err "Install with: sudo dnf install ${missing[*]}"
        exit 1
    fi
}

check_env() {
    if [[ -z "${B2_ACCOUNT_ID:-}" || -z "${B2_ACCOUNT_KEY:-}" || -z "${RESTIC_REPOSITORY:-}" ]]; then
        err "Required environment variables not set."
        err "Export these in your shell or add them to a secure env file:"
        echo ""
        echo "  export B2_ACCOUNT_ID=\"your-key-id\""
        echo "  export B2_ACCOUNT_KEY=\"your-application-key\""
        echo "  export RESTIC_REPOSITORY=\"b2:your-bucket-name:\""
        echo ""
        err "See: backup.sh help for setup instructions."
        exit 1
    fi
}

# ── Password management ──────────────────────────────────────────────
get_repo_password() {
    if [[ ! -f "$REPO_PASSWORD_GPG" ]]; then
        err "Encrypted password file not found: ${REPO_PASSWORD_GPG}"
        err "Run 'backup.sh init' first to set up the repository."
        exit 1
    fi
    gpg --quiet --decrypt "$REPO_PASSWORD_GPG" 2>/dev/null
}

export_password() {
    export RESTIC_PASSWORD
    RESTIC_PASSWORD="$(get_repo_password)"
}

# ── Logging ──────────────────────────────────────────────────────────
setup_logging() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ── Commands ─────────────────────────────────────────────────────────
cmd_init() {
    header "Initializing restic repository"
    check_deps
    check_env

    if [[ -f "$REPO_PASSWORD_GPG" ]]; then
        warn "Encrypted password file already exists at ${REPO_PASSWORD_GPG}"
        read -rp "Overwrite? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
    fi

    # Generate a strong random password
    info "Generating repository password..."
    local repo_password
    repo_password="$(openssl rand -base64 48)"

    # Find available GPG keys
    info "Available GPG keys:"
    gpg --list-keys --keyid-format long 2>/dev/null
    echo ""
    read -rp "Enter the GPG key ID or email to encrypt with: " gpg_recipient

    # Encrypt the password with the user's GPG key
    echo -n "$repo_password" | gpg --encrypt --recipient "$gpg_recipient" \
        --output "$REPO_PASSWORD_GPG" --trust-model always
    chmod 600 "$REPO_PASSWORD_GPG"
    ok "Repository password encrypted and saved to ${REPO_PASSWORD_GPG}"

    # Initialize the restic repository
    info "Initializing restic repository at ${RESTIC_REPOSITORY}..."
    export RESTIC_PASSWORD="$repo_password"
    restic init
    ok "Repository initialized successfully!"

    echo ""
    warn "CRITICAL: Back up your GPG private key separately!"
    warn "Without it, you cannot decrypt the repo password."
    warn "Your GPG key should already be in Proton Drive — verify this now."
    echo ""
    info "Run 'backup.sh backup' to start your first backup."
}

cmd_backup() {
    header "Starting backup — $(date '+%Y-%m-%d %H:%M:%S')"
    check_deps
    check_env
    export_password
    setup_logging

    info "Backing up ${BACKUP_PATH} to ${RESTIC_REPOSITORY}"
    restic backup \
        --exclude-file="$EXCLUDE_FILE" \
        --exclude-caches \
        --one-file-system \
        --tag "scheduled" \
        --verbose \
        "$BACKUP_PATH"

    ok "Backup completed — $(date '+%Y-%m-%d %H:%M:%S')"
}

cmd_prune() {
    header "Applying retention policy"
    check_deps
    check_env
    export_password

    info "Retention: ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m / ${KEEP_YEARLY}y"
    restic forget \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --keep-yearly "$KEEP_YEARLY" \
        --prune \
        --verbose

    ok "Prune completed."
}

cmd_snapshots() {
    header "Repository snapshots"
    check_deps
    check_env
    export_password

    restic snapshots --compact
}

cmd_stats() {
    header "Repository statistics"
    check_deps
    check_env
    export_password

    restic stats
    echo ""
    restic stats --mode raw-data
}

cmd_check() {
    header "Verifying repository integrity"
    check_deps
    check_env
    export_password

    restic check --verbose
    ok "Repository integrity verified."
}

cmd_restore() {
    header "Restore from backup"
    check_deps
    check_env
    export_password

    local snapshot="${1:-latest}"
    local target="${2:-${HOME}/Restore}"

    warn "This will restore snapshot '${snapshot}' to: ${target}"
    read -rp "Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

    mkdir -p "$target"
    restic restore "$snapshot" --target "$target" --verbose
    ok "Restored to ${target}"
}

cmd_mount() {
    header "Mounting repository (FUSE)"
    check_deps
    check_env
    export_password

    local mountpoint="${1:-${HOME}/mnt/restic}"
    mkdir -p "$mountpoint"
    info "Mounting at ${mountpoint} — press Ctrl+C to unmount"
    restic mount "$mountpoint"
}

cmd_unlock() {
    header "Removing stale repository locks"
    check_deps
    check_env
    export_password

    restic unlock
    ok "Repository unlocked."
}

cmd_install() {
    header "systemd timer installation"

    local service_src="${SCRIPT_DIR}/restic-backup.service"
    local timer_src="${SCRIPT_DIR}/restic-backup.timer"
    local systemd_dir="${HOME}/.config/systemd/user"

    if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
        err "Service/timer files not found in ${SCRIPT_DIR}"
        exit 1
    fi

    echo -e "This will set up the systemd user timer for automated backups.\n"
    echo -e "${BOLD}Steps:${NC}\n"

    echo "  1. Create the systemd user directory (if needed):"
    echo -e "     ${CYAN}mkdir -p ${systemd_dir}${NC}\n"

    echo "  2. Symlink the service and timer files:"
    echo -e "     ${CYAN}ln -sf ${service_src} ${systemd_dir}/restic-backup.service${NC}"
    echo -e "     ${CYAN}ln -sf ${timer_src} ${systemd_dir}/restic-backup.timer${NC}\n"

    echo "  3. Create your environment file for B2 credentials:"
    echo -e "     ${CYAN}mkdir -p ${HOME}/.config/restic${NC}"
    echo -e "     ${CYAN}cat > ${HOME}/.config/restic/b2.env << 'EOF'"
    echo "B2_ACCOUNT_ID=your-key-id"
    echo "B2_ACCOUNT_KEY=your-application-key"
    echo "RESTIC_REPOSITORY=b2:your-bucket-name:"
    echo -e "EOF${NC}"
    echo -e "     ${CYAN}chmod 600 ${HOME}/.config/restic/b2.env${NC}\n"

    echo "  4. Reload systemd and enable the timer:"
    echo -e "     ${CYAN}systemctl --user daemon-reload${NC}"
    echo -e "     ${CYAN}systemctl --user enable --now restic-backup.timer${NC}\n"

    echo "  5. Verify it's active:"
    echo -e "     ${CYAN}systemctl --user status restic-backup.timer${NC}"
    echo -e "     ${CYAN}systemctl --user list-timers${NC}\n"

    echo -e "  6. (Optional) Test a manual run:"
    echo -e "     ${CYAN}systemctl --user start restic-backup.service${NC}"
    echo -e "     ${CYAN}journalctl --user -u restic-backup.service -f${NC}\n"

    echo -e "${YELLOW}NOTE:${NC} For timers to run when you're not logged into a GUI session:"
    echo -e "     ${CYAN}loginctl enable-linger \$(whoami)${NC}\n"

    read -rp "Run steps 1-2 now (symlink only)? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mkdir -p "$systemd_dir"
        ln -sf "$service_src" "${systemd_dir}/restic-backup.service"
        ln -sf "$timer_src" "${systemd_dir}/restic-backup.timer"
        ok "Symlinks created. Complete steps 3-6 manually."
    else
        info "No changes made. Run the commands above when ready."
    fi
}

cmd_help() {
    cat <<EOF

${BOLD}restic-backup${NC} — Encrypted incremental backup to Backblaze B2

${BOLD}USAGE${NC}
    backup.sh <command> [options]

${BOLD}COMMANDS${NC}
    ${GREEN}init${NC}          Generate repo password, encrypt with GPG, initialize repo
    ${GREEN}backup${NC}        Run an incremental backup now
    ${GREEN}prune${NC}         Apply retention policy and reclaim space
    ${GREEN}snapshots${NC}     List all snapshots in the repository
    ${GREEN}stats${NC}         Show repository size and statistics
    ${GREEN}check${NC}         Verify repository integrity
    ${GREEN}restore${NC}       Restore a snapshot (default: latest → ~/Restore)
    ${GREEN}mount${NC}         FUSE-mount the repo for browsing (default: ~/mnt/restic)
    ${GREEN}unlock${NC}        Remove stale locks (after interrupted backup)
    ${GREEN}install${NC}       Walk through systemd timer setup with symlink commands
    ${GREEN}help${NC}          Show this help message

${BOLD}ENVIRONMENT${NC}
    B2_ACCOUNT_ID       Backblaze B2 application key ID
    B2_ACCOUNT_KEY      Backblaze B2 application key
    RESTIC_REPOSITORY   Repository path (e.g., b2:my-backup-bucket:)

${BOLD}FILES${NC}
    ${SCRIPT_DIR}/
    ├── backup.sh               This script
    ├── backup.exclude           Exclude patterns
    ├── restic-backup.service    systemd service unit
    ├── restic-backup.timer      systemd timer (30 min)
    └── .repo-password.gpg       GPG-encrypted repo password

${BOLD}FIRST-TIME SETUP${NC}
    1. Install restic:          sudo dnf install restic
    2. Create a B2 bucket at:   https://secure.backblaze.com/b2_buckets.htm
    3. Create an app key at:    https://secure.backblaze.com/app_keys.htm
    4. Export your credentials:  (see 'install' command for env file setup)
    5. Initialize the repo:     ./backup.sh init
    6. Set up the timer:        ./backup.sh install
    7. First backup:            ./backup.sh backup

${BOLD}RESTORE EXAMPLES${NC}
    backup.sh restore                          # Latest → ~/Restore
    backup.sh restore latest /tmp/restore      # Latest → /tmp/restore
    backup.sh restore abc123ef /tmp/restore    # Specific snapshot

${BOLD}BROWSE BACKUPS${NC}
    backup.sh mount                # Mount at ~/mnt/restic
    ls ~/mnt/restic/snapshots/     # Browse snapshots like directories
    # Ctrl+C to unmount

EOF
}

# ── Main dispatch ────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init)       cmd_init "$@" ;;
        backup)     cmd_backup "$@" ;;
        prune)      cmd_prune "$@" ;;
        snapshots)  cmd_snapshots "$@" ;;
        stats)      cmd_stats "$@" ;;
        check)      cmd_check "$@" ;;
        restore)    cmd_restore "$@" ;;
        mount)      cmd_mount "$@" ;;
        unlock)     cmd_unlock "$@" ;;
        install)    cmd_install "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            err "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
