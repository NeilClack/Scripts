#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# restic-backup — Encrypted incremental backup to Backblaze B2
# Location: ~/Scripts/backup/restic/backup.sh
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

# ── Desktop notifications ────────────────────────────────────────────
notify() {
    local urgency="$1" title="$2" body="$3"
    if command -v notify-send &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        notify-send --urgency="$urgency" --app-name="restic-backup" "$title" "$body" 2>/dev/null || true
    fi
}

notify_ok()   { notify "normal"   "☁️ Restic Backup" "$1"; }
notify_err()  { notify "critical" "⚠️ Restic Backup" "$1"; }

# ── Error trap ───────────────────────────────────────────────────────
backup_trap() {
    notify_err "Backup failed — check 'backup journal' for details"
}

# ── VPN bypass for Backblaze B2 ─────────────────────────────────────
# When Proton VPN is active, Backblaze traffic hangs. These functions
# add host routes via the local (non-VPN) gateway so B2 traffic
# bypasses the VPN tunnel. No-ops when no VPN is detected.
IP_CMD="$(command -v ip)"
LOCAL_GW=""
LOCAL_IF=""
VPN_BYPASS_ROUTES=()

detect_local_gateway() {
    # Find the non-VPN default route (skip proton* devices)
    local route
    route="$($IP_CMD route show default | grep -v proton | head -1)"
    if [[ -z "$route" ]]; then
        return 1
    fi
    LOCAL_GW="$(echo "$route" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
    LOCAL_IF="$(echo "$route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
    if [[ -z "$LOCAL_GW" || -z "$LOCAL_IF" ]]; then
        return 1
    fi
}

setup_vpn_bypass() {
    # Only needed when Proton VPN is active
    if ! $IP_CMD route show default | grep -q proton; then
        return 0
    fi

    if ! detect_local_gateway; then
        warn "VPN detected but could not find local gateway — B2 traffic will use VPN"
        return 0
    fi

    info "Proton VPN detected — routing B2 traffic via ${LOCAL_GW} (${LOCAL_IF})"

    # Resolve all Backblaze B2 endpoints
    local endpoints=( api.backblazeb2.com )
    local i
    for i in $(seq 0 5); do
        endpoints+=( "f$(printf '%03d' "$i").backblazeb2.com" )
    done

    local -A seen_ips=()
    local host ip
    for host in "${endpoints[@]}"; do
        while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            [[ -z "${seen_ips[$ip]+x}" ]] || continue
            seen_ips[$ip]=1

            if pkexec "$IP_CMD" route add "$ip/32" via "$LOCAL_GW" dev "$LOCAL_IF" 2>/dev/null; then
                VPN_BYPASS_ROUTES+=( "$ip/32" )
            fi
        done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    done

    if [[ ${#VPN_BYPASS_ROUTES[@]} -gt 0 ]]; then
        ok "Added ${#VPN_BYPASS_ROUTES[@]} bypass route(s)"
    else
        warn "No bypass routes added — DNS resolution may have failed"
    fi

    # Ensure cleanup on exit
    trap teardown_vpn_bypass EXIT
}

teardown_vpn_bypass() {
    local route
    for route in "${VPN_BYPASS_ROUTES[@]}"; do
        pkexec "$IP_CMD" route del "$route" via "$LOCAL_GW" dev "$LOCAL_IF" 2>/dev/null || true
    done
    if [[ ${#VPN_BYPASS_ROUTES[@]} -gt 0 ]]; then
        info "Cleaned up ${#VPN_BYPASS_ROUTES[@]} bypass route(s)"
        VPN_BYPASS_ROUTES=()
    fi
}

# ── Environment check ────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in restic gpg; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required commands: ${missing[*]}"
        err "Install restic and gpg via your system package manager."
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
        err "See: backup help for setup instructions."
        notify_err "Environment variables not set — cannot run backup"
        exit 1
    fi
}

# ── Password management ──────────────────────────────────────────────
get_repo_password() {
    if [[ ! -f "$REPO_PASSWORD_GPG" ]]; then
        err "Encrypted password file not found: ${REPO_PASSWORD_GPG}"
        err "Run 'backup init' first to set up the repository."
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
    info "Run 'backup backup' to start your first backup."
    notify_ok "Repository initialized successfully"
}

cmd_backup() {
    trap backup_trap ERR

    header "Starting backup — $(date '+%Y-%m-%d %H:%M:%S')"
    check_deps
    check_env
    export_password
    setup_logging

    setup_vpn_bypass

    info "Backing up ${BACKUP_PATH} to ${RESTIC_REPOSITORY}"
    restic backup \
        --exclude-file="$EXCLUDE_FILE" \
        --exclude-caches \
        --one-file-system \
        --tag "scheduled" \
        --verbose \
        "$BACKUP_PATH"

    ok "Backup completed — $(date '+%Y-%m-%d %H:%M:%S')"
    notify_ok "Backup completed successfully"

    trap - ERR
}

cmd_prune() {
    trap backup_trap ERR

    header "Applying retention policy"
    check_deps
    check_env
    export_password

    setup_vpn_bypass

    info "Retention: ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m / ${KEEP_YEARLY}y"
    restic forget \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --keep-yearly "$KEEP_YEARLY" \
        --prune \
        --verbose

    ok "Prune completed."

    trap - ERR
}

cmd_snapshots() {
    header "Repository snapshots"
    check_deps
    check_env
    export_password
    setup_vpn_bypass

    restic snapshots --compact
}

cmd_stats() {
    header "Repository statistics"
    check_deps
    check_env
    export_password
    setup_vpn_bypass

    restic stats
    echo ""
    restic stats --mode raw-data
}

cmd_check() {
    header "Verifying repository integrity"
    check_deps
    check_env
    export_password
    setup_vpn_bypass

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

    setup_vpn_bypass

    mkdir -p "$target"
    restic restore "$snapshot" --target "$target" --verbose
    ok "Restored to ${target}"
    notify_ok "Restore completed to ${target}"
}

cmd_mount() {
    header "Mounting repository (FUSE)"
    check_deps
    check_env
    export_password

    local mountpoint="${1:-${HOME}/mnt/restic}"
    setup_vpn_bypass

    mkdir -p "$mountpoint"
    info "Mounting at ${mountpoint} — press Ctrl+C to unmount"
    restic mount "$mountpoint"
}

cmd_unlock() {
    header "Removing stale repository locks"
    check_deps
    check_env
    export_password
    setup_vpn_bypass

    restic unlock
    ok "Repository unlocked."
}

cmd_journal() {
    journalctl --user -u restic-backup.service --no-pager -n 50
}

cmd_install() {
    header "systemd timer installation"

    local service_src="${SCRIPT_DIR}/restic-backup.service"
    local timer_src="${SCRIPT_DIR}/restic-backup.timer"
    local polkit_src="${SCRIPT_DIR}/49-restic-backup-ip-route.rules"
    local polkit_dst="/etc/polkit-1/rules.d/49-restic-backup-ip-route.rules"
    local systemd_dir="${HOME}/.config/systemd/user"

    if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
        err "Service/timer files not found in ${SCRIPT_DIR}"
        exit 1
    fi

    echo -e "This will set up the systemd user timer for automated backups.\n"
    echo -e "${BOLD}Steps:${NC}\n"

    echo "  1. Install polkit rule for VPN bypass (requires sudo, one-time):"
    echo -e "     When Proton VPN is active, the backup script uses pkexec to add"
    echo -e "     host routes so Backblaze B2 traffic bypasses the VPN tunnel."
    echo -e "     This polkit rule allows that to happen without a password prompt."
    echo -e "     ${CYAN}sudo cp ${polkit_src} ${polkit_dst}${NC}"
    echo -e "     ${CYAN}sudo chmod 644 ${polkit_dst}${NC}\n"

    echo "  2. Create the systemd user directory (if needed):"
    echo -e "     ${CYAN}mkdir -p ${systemd_dir}${NC}\n"

    echo "  3. Symlink the service and timer files:"
    echo -e "     ${CYAN}ln -sf ${service_src} ${systemd_dir}/restic-backup.service${NC}"
    echo -e "     ${CYAN}ln -sf ${timer_src} ${systemd_dir}/restic-backup.timer${NC}\n"

    echo "  4. Create your environment file for B2 credentials:"
    echo -e "     ${CYAN}mkdir -p ${HOME}/.config/restic${NC}"
    echo -e "     ${CYAN}cat > ${HOME}/.config/restic/b2.env << 'EOF'"
    echo "B2_ACCOUNT_ID=your-key-id"
    echo "B2_ACCOUNT_KEY=your-application-key"
    echo "RESTIC_REPOSITORY=b2:your-bucket-name:"
    echo -e "EOF${NC}"
    echo -e "     ${CYAN}chmod 600 ${HOME}/.config/restic/b2.env${NC}\n"

    echo "  5. Reload systemd and enable the timer:"
    echo -e "     ${CYAN}systemctl --user daemon-reload${NC}"
    echo -e "     ${CYAN}systemctl --user enable --now restic-backup.timer${NC}\n"

    echo "  6. Verify it's active:"
    echo -e "     ${CYAN}systemctl --user status restic-backup.timer${NC}"
    echo -e "     ${CYAN}systemctl --user list-timers${NC}\n"

    echo -e "  7. (Optional) Test a manual run:"
    echo -e "     ${CYAN}systemctl --user start restic-backup.service${NC}"
    echo -e "     ${CYAN}journalctl --user -u restic-backup.service -f${NC}\n"

    echo -e "${YELLOW}NOTE:${NC} For timers to run when you're not logged into a GUI session:"
    echo -e "     ${CYAN}loginctl enable-linger \$(whoami)${NC}\n"

    # ── Step 1: Polkit rule ──────────────────────────────────────────
    if [[ -f "$polkit_dst" ]]; then
        ok "Polkit rule already installed at ${polkit_dst}"
    elif [[ -f "$polkit_src" ]]; then
        read -rp "Install polkit rule now (step 1, requires sudo)? (y/N): " confirm_polkit
        if [[ "$confirm_polkit" =~ ^[Yy]$ ]]; then
            sudo mkdir -p /etc/polkit-1/rules.d
            sudo cp "$polkit_src" "$polkit_dst"
            sudo chmod 644 "$polkit_dst"
            ok "Polkit rule installed at ${polkit_dst}"
        else
            warn "Skipped polkit rule. VPN bypass will prompt for a password."
        fi
    else
        warn "Polkit rule file not found at ${polkit_src} — skipping"
    fi

    echo ""

    # ── Steps 2-3: Symlinks ──────────────────────────────────────────
    read -rp "Run steps 2-3 now (symlink service/timer)? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mkdir -p "$systemd_dir"
        ln -sf "$service_src" "${systemd_dir}/restic-backup.service"
        ln -sf "$timer_src" "${systemd_dir}/restic-backup.timer"
        ok "Symlinks created. Complete steps 4-7 manually."
    else
        info "No changes made. Run the commands above when ready."
    fi
}

cmd_help() {
    echo -e "
${BOLD}restic-backup${NC} — Encrypted incremental backup to Backblaze B2

${BOLD}USAGE${NC}
    backup <command> [options]

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
    ${GREEN}journal${NC}       Show recent systemd journal entries for the backup service
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
    backup restore                          # Latest → ~/Restore
    backup restore latest /tmp/restore      # Latest → /tmp/restore
    backup restore abc123ef /tmp/restore    # Specific snapshot

${BOLD}BROWSE BACKUPS${NC}
    backup mount                # Mount at ~/mnt/restic
    ls ~/mnt/restic/snapshots/  # Browse snapshots like directories
    # Ctrl+C to unmount
"
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
        journal)    cmd_journal "$@" ;;
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
