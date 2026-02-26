#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# rbackup — Local rsync mirror to secondary drive
# Location: ~/Scripts/backup/rsync/rbackup.sh
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
EXCLUDE_FILE="${SCRIPT_DIR}/rbackup.exclude"
LOG_DIR="${HOME}/.local/share/rbackup"
LOG_FILE="${LOG_DIR}/rbackup.log"

SOURCE="${HOME}/"
DESTINATION="/run/media/nclack/UGREEN/home/$(whoami)/"

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
    err "rsync not found. Install with: sudo dnf install rsync"
    exit 1
  fi
}

check_mount() {
  if ! mountpoint -q /run/media/nclack/UGREEN 2>/dev/null; then
    err "/run/media/nclack/UGREEN is not mounted."
    err "Mount your backup drive first, then try again."
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
  check_mount
  check_exclude_file
  setup_logging

  # Ensure destination exists with correct ownership
  mkdir -p "$DESTINATION"

  info "Syncing ${SOURCE} → ${DESTINATION}"
  info "Using exclude file: ${EXCLUDE_FILE}"
  echo ""

  rsync \
    --archive \
    --delete \
    --delete-excluded \
    --human-readable \
    --itemize-changes \
    --stats \
    --partial \
    --exclude-from="$EXCLUDE_FILE" \
    "$SOURCE" "$DESTINATION"

  echo ""
  ok "Backup completed — $(date '+%Y-%m-%d %H:%M:%S')"
  notify_ok "Local backup completed"

  trap - ERR
}

cmd_restore() {
  header "Restoring from local backup"
  check_deps
  check_mount

  if [[ ! -d "$DESTINATION" ]]; then
    err "Backup directory not found: ${DESTINATION}"
    err "Nothing to restore from."
    exit 1
  fi

  warn "This will overwrite files in ${SOURCE} with the local backup."
  warn "Source:      ${DESTINATION}"
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

  info "Restoring ${DESTINATION} → ${SOURCE}"
  echo ""

  rsync \
    --archive \
    --human-readable \
    --itemize-changes \
    --stats \
    --partial \
    ${delete_flag} \
    "$DESTINATION" "$SOURCE"

  echo ""
  ok "Restore completed — $(date '+%Y-%m-%d %H:%M:%S')"
  notify_ok "Restore completed successfully"
}

cmd_dry_run() {
  header "Dry run — $(date '+%Y-%m-%d %H:%M:%S')"
  check_deps
  check_mount
  check_exclude_file

  info "Showing what would change (no files will be modified):"
  echo ""

  rsync \
    --archive \
    --delete \
    --delete-excluded \
    --human-readable \
    --itemize-changes \
    --stats \
    --dry-run \
    --exclude-from="$EXCLUDE_FILE" \
    "$SOURCE" "$DESTINATION"
}

cmd_status() {
  header "Backup status"
  check_mount

  if [[ ! -d "$DESTINATION" ]]; then
    warn "No backup found at ${DESTINATION}"
    exit 0
  fi

  local last_modified
  last_modified="$(stat -c '%y' "$DESTINATION" 2>/dev/null | cut -d. -f1)"

  info "Backup location:  ${DESTINATION}"
  info "Last modified:     ${last_modified}"
  info "Backup size:       $(du -sh "$DESTINATION" 2>/dev/null | cut -f1)"
  info "Drive usage:"
  df -h /run/media/nclack/UGREEN | tail -1 | awk '{printf "  Total: %s  Used: %s  Free: %s  Usage: %s\n", $2, $3, $4, $5}'
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
${BOLD}rbackup${NC} — Local rsync mirror to secondary drive

${BOLD}USAGE${NC}
    rbackup [option]

${BOLD}OPTIONS${NC}
    ${GREEN}(none)${NC}            Run backup — mirror \$HOME to UGREEN drive
    ${GREEN}--restore${NC}         Restore backup → \$HOME (safe, no deletes)
    ${GREEN}--restore --delete${NC} Restore backup → \$HOME (full mirror, deletes extras)
    ${GREEN}--dry-run${NC}         Show what would change without doing anything
    ${GREEN}--status${NC}          Show backup age, size, and drive usage
    ${GREEN}--journal${NC}         Show recent systemd journal entries
    ${GREEN}--install${NC}         Walk through systemd timer setup
    ${GREEN}--help${NC}            Show this help message

${BOLD}PATHS${NC}
    Source:       ${SOURCE}
    Destination:  ${DESTINATION}
    Excludes:     ${EXCLUDE_FILE}
    Log:          ${LOG_FILE}

${BOLD}SYSTEMD${NC}
    Timer runs every 10 minutes via rbackup.timer
    Skips silently if /run/media/nclack/UGREEN is not mounted

${BOLD}EXAMPLES${NC}
    rbackup                    # Mirror home → backup drive
    rbackup --dry-run          # Preview changes
    rbackup --restore          # Restore (keeps extra files in \$HOME)
    rbackup --restore --delete # Restore (exact mirror, deletes extras)
    rbackup --status           # Check last backup time and drive space
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
