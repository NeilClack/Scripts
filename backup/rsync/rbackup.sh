#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# rbackup — Local rsync mirror to backup drives
# Location: ~/Scripts/backup/rsync/rbackup.sh
#
# Destinations:
#   BACKUPS  — internal NVMe at /mnt/backups (always, if mounted)
#   UGREEN   — external USB at /run/media/nclack/UGREEN (when available)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
EXCLUDE_FILE="${SCRIPT_DIR}/rbackup.exclude"
LOG_DIR="${HOME}/.local/share/rbackup"
LOG_FILE="${LOG_DIR}/rbackup.log"

SOURCE="${HOME}/"
DEST_LOCAL="/mnt/backups/home/$(whoami)/"
DEST_USB="/run/media/nclack/UGREEN/home/$(whoami)/"

UGREEN_LABEL="UGREEN"
UGREEN_MOUNT="/run/media/nclack/UGREEN"

# ── Color output ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

# ── Desktop notifications ────────────────────────────────────────────
notify() {
  local urgency="$1" title="$2" body="$3"
  if command -v notify-send &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    notify-send --urgency="$urgency" --app-name="rbackup" "$title" "$body" 2>/dev/null || true
  fi
}

notify_ok() { notify "normal" "💾 Local Backup" "$1"; }
notify_err() { notify "critical" "⚠️ Local Backup" "$1"; }

# ── Error trap ───────────────────────────────────────────────────────
backup_trap() {
  notify_err "Local backup failed — check 'rbackup --journal' for details"
}

# ── Preflight checks ────────────────────────────────────────────────
check_deps() {
  if ! command -v rsync &>/dev/null; then
    err "rsync not found. Add it to your Nix packages."
    exit 1
  fi
}

check_exclude_file() {
  if [[ ! -f "$EXCLUDE_FILE" ]]; then
    err "Exclude file not found: ${EXCLUDE_FILE}"
    err "It should be alongside this script at: ${SCRIPT_DIR}/rbackup.exclude"
    exit 1
  fi
}

# ── Mount helpers ────────────────────────────────────────────────────
is_local_available() {
  mountpoint -q /mnt/backups 2>/dev/null
}

is_usb_available() {
  mountpoint -q "$UGREEN_MOUNT" 2>/dev/null
}

try_mount_usb() {
  # If UGREEN is plugged in but not mounted, try to mount it
  if [[ -e "/dev/disk/by-label/${UGREEN_LABEL}" ]] && ! is_usb_available; then
    info "UGREEN detected but not mounted — attempting mount..."
    mkdir -p "$UGREEN_MOUNT"
    if mount "/dev/disk/by-label/${UGREEN_LABEL}" "$UGREEN_MOUNT" 2>/dev/null; then
      ok "UGREEN mounted at ${UGREEN_MOUNT}"
    else
      warn "Could not mount UGREEN (may need sudo). Skipping USB backup."
    fi
  fi
}

# ── Rsync wrapper ────────────────────────────────────────────────────
run_rsync() {
  local dest="$1"
  shift
  mkdir -p "$dest"
  rsync \
    --archive \
    --delete \
    --delete-excluded \
    --human-readable \
    --itemize-changes \
    --stats \
    --partial \
    --exclude-from="$EXCLUDE_FILE" \
    "$@" \
    "$SOURCE" "$dest"
}

# ── Logging ──────────────────────────────────────────────────────────
setup_logging() {
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ── Commands ─────────────────────────────────────────────────────────
cmd_backup() {
  trap backup_trap ERR

  header "Local backup — $(date '+%Y-%m-%d %H:%M:%S')"
  check_deps
  check_exclude_file
  setup_logging

  try_mount_usb

  local backed_up=0

  # Backup to internal NVMe (BACKUPS)
  if is_local_available; then
    info "Syncing ${SOURCE} → ${DEST_LOCAL}"
    echo ""
    run_rsync "$DEST_LOCAL"
    echo ""
    ok "BACKUPS backup completed"
    backed_up=1
  else
    warn "/mnt/backups is not mounted — skipping internal backup"
  fi

  # Backup to external USB (UGREEN)
  if is_usb_available; then
    info "Syncing ${SOURCE} → ${DEST_USB}"
    echo ""
    run_rsync "$DEST_USB"
    echo ""
    ok "UGREEN backup completed"
    backed_up=1
  else
    warn "UGREEN is not available — skipping USB backup"
  fi

  if [[ $backed_up -eq 0 ]]; then
    err "No backup destinations available"
    notify_err "No backup destinations available"
    exit 1
  fi

  ok "Backup completed — $(date '+%Y-%m-%d %H:%M:%S')"
  notify_ok "Local backup completed"

  trap - ERR
}

cmd_restore() {
  header "Restore from backup"
  check_deps

  try_mount_usb

  # Build list of available sources
  local sources=()
  local labels=()
  if is_local_available && [[ -d "$DEST_LOCAL" ]]; then
    sources+=("$DEST_LOCAL")
    labels+=("BACKUPS (${DEST_LOCAL})")
  fi
  if is_usb_available && [[ -d "$DEST_USB" ]]; then
    sources+=("$DEST_USB")
    labels+=("UGREEN (${DEST_USB})")
  fi

  if [[ ${#sources[@]} -eq 0 ]]; then
    err "No backup sources available to restore from."
    exit 1
  fi

  # Let user pick source
  local restore_src
  if [[ ${#sources[@]} -eq 1 ]]; then
    restore_src="${sources[0]}"
    info "Restoring from: ${labels[0]}"
  else
    echo "Available backup sources:"
    for i in "${!labels[@]}"; do
      echo "  $((i + 1))) ${labels[$i]}"
    done
    echo ""
    read -rp "Select source (1-${#sources[@]}): " choice
    if [[ "$choice" -ge 1 && "$choice" -le ${#sources[@]} ]] 2>/dev/null; then
      restore_src="${sources[$((choice - 1))]}"
    else
      err "Invalid selection."
      exit 1
    fi
  fi

  warn "This will overwrite files in ${SOURCE} with the backup."
  warn "Source:      ${restore_src}"
  warn "Destination: ${SOURCE}"
  echo ""
  warn "Files in your home directory that don't exist in the backup will NOT be deleted."
  warn "To do a full mirror restore (delete extra files), use: rbackup --restore --delete"
  echo ""
  read -rp "Continue? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    info "Aborted."
    exit 0
  }

  local delete_flag=""
  if [[ "${1:-}" == "--delete" ]]; then
    warn "Full mirror restore — files not in backup WILL be deleted."
    read -rp "Are you sure? This is destructive. (y/N): " confirm2
    [[ "$confirm2" =~ ^[Yy]$ ]] || {
      info "Aborted."
      exit 0
    }
    delete_flag="--delete"
  fi

  info "Restoring ${restore_src} → ${SOURCE}"
  echo ""

  rsync \
    --archive \
    --human-readable \
    --itemize-changes \
    --stats \
    --partial \
    ${delete_flag} \
    "$restore_src" "$SOURCE"

  echo ""
  ok "Restore completed — $(date '+%Y-%m-%d %H:%M:%S')"
  notify_ok "Restore completed successfully"
}

cmd_dry_run() {
  header "Dry run — $(date '+%Y-%m-%d %H:%M:%S')"
  check_deps
  check_exclude_file

  try_mount_usb

  local has_dest=0

  if is_local_available; then
    info "BACKUPS — what would change:"
    echo ""
    run_rsync "$DEST_LOCAL" --dry-run
    echo ""
    has_dest=1
  else
    warn "/mnt/backups is not mounted — skipping"
  fi

  if is_usb_available; then
    info "UGREEN — what would change:"
    echo ""
    run_rsync "$DEST_USB" --dry-run
    echo ""
    has_dest=1
  else
    warn "UGREEN is not available — skipping"
  fi

  if [[ $has_dest -eq 0 ]]; then
    err "No backup destinations available for dry run"
    exit 1
  fi
}

show_dest_status() {
  local label="$1" dest="$2" mountpoint="$3"

  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    info "${label}: not mounted"
    return
  fi

  if [[ ! -d "$dest" ]]; then
    info "${label}: mounted but no backup found at ${dest}"
    return
  fi

  local last_modified
  last_modified="$(stat -c '%y' "$dest" 2>/dev/null | cut -d. -f1)"

  info "${label}:"
  info "  Backup location:  ${dest}"
  info "  Last modified:    ${last_modified}"
  info "  Backup size:      $(du -sh "$dest" 2>/dev/null | cut -f1)"
  info "  Drive usage:"
  df -h "$mountpoint" | tail -1 | awk '{printf "    Total: %s  Used: %s  Free: %s  Usage: %s\n", $2, $3, $4, $5}'
}

cmd_status() {
  header "Backup status"

  try_mount_usb

  show_dest_status "BACKUPS" "$DEST_LOCAL" "/mnt/backups"
  echo ""
  show_dest_status "UGREEN" "$DEST_USB" "$UGREEN_MOUNT"
}

cmd_journal() {
  journalctl --user -u rbackup.service --no-pager -n 50
}

cmd_install() {
  header "systemd timer installation"

  local service_src="${SCRIPT_DIR}/rbackup.service"
  local timer_src="${SCRIPT_DIR}/rbackup.timer"
  local systemd_dir="${HOME}/.config/systemd/user"

  if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
    err "Service/timer files not found in ${SCRIPT_DIR}"
    exit 1
  fi

  echo -e "This will set up the systemd user timer for local backups every 10 minutes.\n"
  echo -e "${BOLD}Steps:${NC}\n"

  echo "  1. Create the systemd user directory (if needed):"
  echo -e "     ${CYAN}mkdir -p ${systemd_dir}${NC}\n"

  echo "  2. Symlink the service and timer files:"
  echo -e "     ${CYAN}ln -sf ${service_src} ${systemd_dir}/rbackup.service${NC}"
  echo -e "     ${CYAN}ln -sf ${timer_src} ${systemd_dir}/rbackup.timer${NC}\n"

  echo "  3. Reload systemd and enable the timer:"
  echo -e "     ${CYAN}systemctl --user daemon-reload${NC}"
  echo -e "     ${CYAN}systemctl --user enable --now rbackup.timer${NC}\n"

  echo "  4. Verify it's active:"
  echo -e "     ${CYAN}systemctl --user status rbackup.timer${NC}"
  echo -e "     ${CYAN}systemctl --user list-timers${NC}\n"

  echo -e "  5. (Optional) Test a manual run:"
  echo -e "     ${CYAN}systemctl --user start rbackup.service${NC}"
  echo -e "     ${CYAN}journalctl --user -u rbackup.service -f${NC}\n"

  echo -e "${YELLOW}NOTE:${NC} For timers to run when you're not logged into a GUI session:"
  echo -e "     ${CYAN}loginctl enable-linger \$(whoami)${NC}\n"

  read -rp "Run steps 1-2 now (symlink only)? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    mkdir -p "$systemd_dir"
    ln -sf "$service_src" "${systemd_dir}/rbackup.service"
    ln -sf "$timer_src" "${systemd_dir}/rbackup.timer"
    ok "Symlinks created. Complete steps 3-5 manually."
  else
    info "No changes made. Run the commands above when ready."
  fi
}

cmd_help() {
  echo -e "
${BOLD}rbackup${NC} — Local rsync mirror to backup drives

${BOLD}USAGE${NC}
    rbackup [option]

${BOLD}OPTIONS${NC}
    ${GREEN}(none)${NC}            Run backup — mirror \$HOME to available drives
    ${GREEN}--restore${NC}         Restore backup → \$HOME (safe, no deletes)
    ${GREEN}--restore --delete${NC} Restore backup → \$HOME (full mirror, deletes extras)
    ${GREEN}--dry-run${NC}         Show what would change without doing anything
    ${GREEN}--status${NC}          Show backup age, size, and drive usage
    ${GREEN}--journal${NC}         Show recent systemd journal entries
    ${GREEN}--install${NC}         Walk through systemd timer setup
    ${GREEN}--help${NC}            Show this help message

${BOLD}DESTINATIONS${NC}
    BACKUPS:  ${DEST_LOCAL}  (internal NVMe, always if mounted)
    UGREEN:   ${DEST_USB}  (external USB, when plugged in)

${BOLD}PATHS${NC}
    Source:       ${SOURCE}
    Excludes:     ${EXCLUDE_FILE}
    Log:          ${LOG_FILE}

${BOLD}SYSTEMD${NC}
    Timer runs every 10 minutes via rbackup.timer
    Script handles mount checks internally — no ConditionPath needed

${BOLD}EXAMPLES${NC}
    rbackup                    # Mirror home → all available drives
    rbackup --dry-run          # Preview changes
    rbackup --restore          # Restore (pick source, keeps extras)
    rbackup --restore --delete # Restore (exact mirror, deletes extras)
    rbackup --status           # Check backup times and drive space
    rbackup --journal          # View recent backup logs
"
}

# ── Main dispatch ────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"

  case "$cmd" in
  "") cmd_backup ;;
  --restore)
    shift
    cmd_restore "$@"
    ;;
  --dry-run) cmd_dry_run ;;
  --status) cmd_status ;;
  --journal) cmd_journal ;;
  --install) cmd_install ;;
  --help | -h | help) cmd_help ;;
  -*)
    err "Unknown option: $cmd"
    cmd_help
    exit 1
    ;;
  *)
    # No flags = run backup
    cmd_backup
    ;;
  esac
}

main "$@"
