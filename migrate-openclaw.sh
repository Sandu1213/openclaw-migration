#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DEFAULT="${SCRIPT_DIR}/openclaw-migrate-$(date +%F-%H%M%S).tar.gz"
OPENCLAW_DIR_DEFAULT="${HOME}/.openclaw"

usage() {
  cat <<'EOF'
OpenClaw Migration Helper

Usage:
  migrate-openclaw.sh export [archive_path] [--include-agents]
  migrate-openclaw.sh import <archive_path> [--overwrite]
  migrate-openclaw.sh verify

Commands:
  export        Create migration archive from ~/.openclaw.
  import        Restore archive into ~/.openclaw.
  verify        Run quick checks after import.

Options:
  --include-agents   Include agents/ session history in export.
  --overwrite        Delete existing ~/.openclaw before import.

Examples:
  ./migrate-openclaw.sh export
  ./migrate-openclaw.sh export ./backup.tar.gz --include-agents
  ./migrate-openclaw.sh import ./backup.tar.gz --overwrite
  ./migrate-openclaw.sh verify
EOF
}

require_bin() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $cmd" >&2
    exit 1
  fi
}

export_openclaw() {
  require_bin tar
  local archive_path="${1:-$ARCHIVE_DEFAULT}"
  local include_agents="${2:-false}"
  local openclaw_dir="$OPENCLAW_DIR_DEFAULT"

  if [[ ! -d "$openclaw_dir" ]]; then
    echo "[ERROR] Directory not found: $openclaw_dir" >&2
    exit 1
  fi

  echo "[INFO] Stopping gateway before export..."
  openclaw gateway stop >/dev/null 2>&1 || true

  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' EXIT

  mkdir -p "$tmp_root/.openclaw"

  local include_paths=(
    "openclaw.json"
    "openclaw.json.bak"
    "workspace"
    "cron"
    "extensions"
    "memory"
    "credentials"
    "identity"
    "devices"
  )

  if [[ "$include_agents" == "true" ]]; then
    include_paths+=("agents")
  fi

  echo "[INFO] Collecting files..."
  for p in "${include_paths[@]}"; do
    if [[ -e "$openclaw_dir/$p" ]]; then
      cp -a "$openclaw_dir/$p" "$tmp_root/.openclaw/"
    fi
  done

  mkdir -p "$(dirname "$archive_path")"
  tar -czf "$archive_path" -C "$tmp_root" .openclaw

  echo "[OK] Export finished: $archive_path"
  if [[ "$include_agents" != "true" ]]; then
    echo "[INFO] agents/ was excluded. Use --include-agents if you need session history." 
  fi
  echo "[INFO] You can now copy this archive to the target machine."
}

import_openclaw() {
  require_bin tar
  local archive_path="${1:-}"
  local overwrite="${2:-false}"
  local openclaw_dir="$OPENCLAW_DIR_DEFAULT"

  if [[ -z "$archive_path" ]]; then
    echo "[ERROR] import requires an archive path" >&2
    usage
    exit 1
  fi

  if [[ ! -f "$archive_path" ]]; then
    echo "[ERROR] Archive not found: $archive_path" >&2
    exit 1
  fi

  echo "[INFO] Stopping gateway before import..."
  openclaw gateway stop >/dev/null 2>&1 || true

  if [[ -d "$openclaw_dir" && "$overwrite" == "true" ]]; then
    echo "[WARN] Removing existing directory: $openclaw_dir"
    rm -rf "$openclaw_dir"
  elif [[ -d "$openclaw_dir" ]]; then
    echo "[ERROR] $openclaw_dir already exists. Use --overwrite to replace it." >&2
    exit 1
  fi

  mkdir -p "$HOME"
  tar -xzf "$archive_path" -C "$HOME"

  echo "[INFO] Starting gateway..."
  openclaw gateway start >/dev/null 2>&1 || true

  echo "[OK] Import finished. Run verify next:"
  echo "      $0 verify"
}

verify_openclaw() {
  echo "[INFO] Running post-migration checks..."

  if command -v openclaw >/dev/null 2>&1; then
    echo "\n== openclaw status =="
    openclaw status || true

    echo "\n== plugins =="
    openclaw plugins list || true

    echo "\n== cron jobs =="
    openclaw cron list || true
  else
    echo "[WARN] openclaw command not found; skip runtime checks."
  fi

  local ws="$OPENCLAW_DIR_DEFAULT/workspace"
  echo "\n== workspace checks =="
  [[ -f "$ws/MEMORY.md" ]] && echo "[OK] MEMORY.md exists" || echo "[WARN] MEMORY.md missing"
  [[ -d "$ws/memory" ]] && echo "[OK] memory/ exists" || echo "[WARN] memory/ missing"

  echo "\n[OK] Verify step completed."
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift || true

  case "$cmd" in
    export)
      local archive=""
      local include_agents="false"

      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        archive="$1"
        shift
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --include-agents) include_agents="true" ;;
          *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
      done

      export_openclaw "$archive" "$include_agents"
      ;;

    import)
      local archive=""
      local overwrite="false"

      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        archive="$1"
        shift
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --overwrite) overwrite="true" ;;
          *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
      done

      import_openclaw "$archive" "$overwrite"
      ;;

    verify)
      verify_openclaw
      ;;

    -h|--help|help)
      usage
      ;;

    *)
      echo "[ERROR] Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
