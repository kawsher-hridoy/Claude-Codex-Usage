#!/usr/bin/env bash
#
# backup-db-to-r2.sh — back up the Claude usage database (~/.claude/usage.db)
# to Cloudflare R2, and restore it on another machine.
#
# Linux/macOS only (needs bash + rclone + sqlite3). rclone talks to R2 over its
# S3-compatible API. Credentials are read at runtime from a gitignored env file;
# nothing secret is ever hardcoded here or printed.
#
set -euo pipefail

usage() {
  cat <<'EOF'
backup-db-to-r2.sh — back up ~/.claude/usage.db to Cloudflare R2 (and restore it).

Usage:
  ./backup-db-to-r2.sh            Snapshot ~/.claude/usage.db and upload to R2.
  ./backup-db-to-r2.sh --scan     Run `python3 cli.py scan` first, then upload.
  ./backup-db-to-r2.sh --restore  Restore the newest snapshot into ~/.claude/.
  ./backup-db-to-r2.sh --help     Show this help.

Each upload writes a timestamped snapshot and keeps only the newest
R2_MAX_SNAPSHOTS (default 3) in the bucket, deleting older ones.

Credentials come from ${R2_ENV_FILE:-~/.config/r2-backup/r2.env}:
  Required: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
            R2_BUCKET_NAME R2_ENDPOINT_URL
  Optional: R2_PREFIX (default "claude-usage"), R2_MAX_SNAPSHOTS (default 3)
On first run the file is seeded from r2.env.template so you can fill it in.
EOF
}

# ---- paths / config --------------------------------------------------------
DB_PATH="${CLAUDE_USAGE_DB:-$HOME/.claude/usage.db}"
ENV_FILE="${R2_ENV_FILE:-$HOME/.config/r2-backup/r2.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/r2.env.template"
REMOTE="R2"   # on-the-fly rclone remote, built from env vars below

MODE="upload"
DO_SCAN=0
MAX_SNAPSHOTS="${R2_MAX_SNAPSHOTS:-3}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# ---- args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --restore) MODE="restore" ;;
    --scan)    DO_SCAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ---- deps ------------------------------------------------------------------
command -v rclone  >/dev/null 2>&1 || die "rclone not found — see https://rclone.org/downloads/"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found — install with: sudo apt install sqlite3"

# ---- credentials -----------------------------------------------------------
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$TEMPLATE_FILE" ]; then
      mkdir -p "$(dirname "$ENV_FILE")"
      cp "$TEMPLATE_FILE" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      info "Created $ENV_FILE from template."
    fi
    die "R2 credentials not set. Edit $ENV_FILE with your R2 keys, then re-run."
  fi
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  local missing=()
  local v
  for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME R2_ENDPOINT_URL; do
    [ -n "${!v:-}" ] || missing+=("$v")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing values in $ENV_FILE: ${missing[*]}"
  case "${R2_ACCESS_KEY_ID}" in
    *your_*here*) die "R2 keys still contain template placeholders — edit $ENV_FILE." ;;
  esac
  PREFIX="${R2_PREFIX:-claude-usage}"
}

# ---- build on-the-fly rclone remote (never reads ~/.config/rclone) ---------
setup_rclone_env() {
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT_URL"
  export RCLONE_CONFIG_R2_ACL="private"
  # Empty, user-owned config so the root-owned default config is never touched.
  RCLONE_EMPTY_CONF="$(mktemp)"
  export RCLONE_CONFIG="$RCLONE_EMPTY_CONF"
}

cleanup() {
  [ -n "${SNAPSHOT:-}" ] && rm -f "$SNAPSHOT"
  [ -n "${RCLONE_EMPTY_CONF:-}" ] && rm -f "$RCLONE_EMPTY_CONF"
}
trap cleanup EXIT

# ---- upload ----------------------------------------------------------------
do_upload() {
  [ -f "$DB_PATH" ] || die "usage database not found at $DB_PATH (run the dashboard/scan first)."

  if [ "$DO_SCAN" -eq 1 ]; then
    local proj="${CLAUDE_USAGE_DIR:-$SCRIPT_DIR}"
    if [ -f "$proj/cli.py" ]; then
      info "Refreshing usage data (python3 cli.py scan in $proj) ..."
      ( cd "$proj" && python3 cli.py scan )
    else
      info "warning: --scan set but cli.py not found in $proj; uploading current DB."
    fi
  fi

  # Consistent snapshot even if a scan/dashboard is writing right now.
  SNAPSHOT="$(mktemp)"
  sqlite3 "$DB_PATH" ".backup '$SNAPSHOT'"

  local key="$PREFIX/usage-$(date +%Y%m%d-%H%M%S).db"
  info "Uploading snapshot ($(du -h "$SNAPSHOT" | cut -f1)) -> R2:$R2_BUCKET_NAME/$key"
  rclone copyto "$SNAPSHOT" "$REMOTE:$R2_BUCKET_NAME/$key" --progress --s3-no-check-bucket

  prune_snapshots

  info ""
  info "Done. Snapshots in R2 (keeping newest $MAX_SNAPSHOTS):"
  rclone lsl "$REMOTE:$R2_BUCKET_NAME/$PREFIX/" --include 'usage-*.db'
}

# ---- retention: keep only the newest N snapshots ---------------------------
prune_snapshots() {
  local listing n to_delete old
  listing="$(rclone lsf "$REMOTE:$R2_BUCKET_NAME/$PREFIX/" --include 'usage-*.db' 2>/dev/null | sort)" || return 0
  [ -n "$listing" ] || return 0
  n="$(printf '%s\n' "$listing" | wc -l)"
  [ "$n" -gt "$MAX_SNAPSHOTS" ] || return 0
  to_delete="$(printf '%s\n' "$listing" | head -n "$((n - MAX_SNAPSHOTS))")"
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    info "Pruning old snapshot -> R2:$R2_BUCKET_NAME/$PREFIX/$old"
    rclone deletefile "$REMOTE:$R2_BUCKET_NAME/$PREFIX/$old" --s3-no-check-bucket
  done <<< "$to_delete"
}

# ---- restore ---------------------------------------------------------------
do_restore() {
  local newest
  newest="$(rclone lsf "$REMOTE:$R2_BUCKET_NAME/$PREFIX/" --include 'usage-*.db' 2>/dev/null | sort | tail -n1)"
  [ -n "$newest" ] || die "no snapshots found in R2:$R2_BUCKET_NAME/$PREFIX/"
  mkdir -p "$(dirname "$DB_PATH")"
  if [ -f "$DB_PATH" ]; then
    local bak="$DB_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$DB_PATH" "$bak"
    info "Existing local DB moved to $bak"
  fi
  info "Downloading R2:$R2_BUCKET_NAME/$PREFIX/$newest -> $DB_PATH"
  rclone copyto "$REMOTE:$R2_BUCKET_NAME/$PREFIX/$newest" "$DB_PATH" --progress --s3-no-check-bucket
  info "Restored $DB_PATH ($(sqlite3 "$DB_PATH" 'SELECT COUNT(*) FROM sessions;' 2>/dev/null || echo '?') sessions)."
}

# ---- main ------------------------------------------------------------------
load_env
setup_rclone_env
case "$MODE" in
  upload)  do_upload ;;
  restore) do_restore ;;
esac
