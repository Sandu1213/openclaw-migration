#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DEFAULT="${SCRIPT_DIR}/openclaw-backup-$(date +%F-%H%M%S).tar.gz"
OPENCLAW_DIR_DEFAULT="${HOME}/.openclaw"

usage() {
  cat <<'EOF'
OpenClaw Migration Helper v2

Philosophy:
- Export/verify rely on the official OpenClaw backup flow.
- This script focuses on restore orchestration + migration validation.
- No repacking, no custom archive layout assumptions.

Usage:
  migrate-openclaw.sh export [archive_path] [options]
  migrate-openclaw.sh export-lite [archive_path]
  migrate-openclaw.sh import <archive_path> [--overwrite]
  migrate-openclaw.sh verify [archive_path]
  migrate-openclaw.sh backup-verify <archive_path>
  migrate-openclaw.sh snapshot-manifest [output_path]

Commands:
  export            Create backup archive via official `openclaw backup create`.
  export-lite       Create a smaller tar.gz backup excluding caches, browser data,
                    virtualenvs, logs, temp files, and bulky extension dependencies.
  import            Restore archive payload into ~/.openclaw.
  verify            Run migration checks; optionally also verify an archive first.
  backup-verify     Run official `openclaw backup verify` on an archive.
  snapshot-manifest Write a lightweight manifest of current local state.

Export options:
  --no-include-workspace  Pass through to official backup create.
  --only-config           Pass through to official backup create.
  --skip-verify           Do not run official backup verification after export.

Import options:
  --overwrite             Move existing ~/.openclaw aside before import.

Examples:
  ./migrate-openclaw.sh export
  ./migrate-openclaw.sh export ./backup.tar.gz --skip-verify
  ./migrate-openclaw.sh export ./backup.tar.gz --no-include-workspace
  ./migrate-openclaw.sh export-lite
  ./migrate-openclaw.sh export-lite ./backup-lite.tar.gz
  ./migrate-openclaw.sh import ./backup.tar.gz --overwrite
  ./migrate-openclaw.sh verify
  ./migrate-openclaw.sh verify ./backup.tar.gz
  ./migrate-openclaw.sh backup-verify ./backup.tar.gz
  ./migrate-openclaw.sh snapshot-manifest
EOF
}

require_bin() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $cmd" >&2
    exit 1
  fi
}

cleanup_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
}

json_get_archive_path() {
  local output="$1"
  python3 - <<'PY' "$output"
import json, sys
text = sys.argv[1]
for line in reversed([ln for ln in text.splitlines() if ln.strip()]):
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if isinstance(obj, dict):
        value = obj.get('archivePath') or obj.get('archive') or obj.get('path')
        if isinstance(value, str) and value.endswith('.tar.gz'):
            print(value)
            raise SystemExit(0)
PY
}

find_generated_archive() {
  local output_dir="$1"
  local candidates=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && candidates+=("$line")
  done < <(find "$output_dir" -maxdepth 1 -type f -name '*openclaw-backup*.tar.gz' -print 2>/dev/null | sort)

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  if [[ "${#candidates[@]}" -gt 1 ]]; then
    echo "[ERROR] Multiple backup archives found in $output_dir; refusing to guess." >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
  fi

  echo "[ERROR] Could not find generated backup archive in $output_dir" >&2
  exit 1
}

resolve_archive_from_output() {
  local output="$1"
  local output_dir="$2"
  local parsed
  parsed="$(json_get_archive_path "$output" || true)"

  if [[ -n "$parsed" ]]; then
    if [[ "$parsed" == ~/* ]]; then
      parsed="${HOME}/${parsed#~/}"
    fi
    if [[ "$parsed" != /* ]]; then
      parsed="${output_dir}/${parsed#./}"
    fi
    if [[ -f "$parsed" ]]; then
      printf '%s\n' "$parsed"
      return 0
    fi
  fi

  find_generated_archive "$output_dir"
}

create_official_backup() {
  require_bin openclaw

  local archive_path="$1"
  local include_workspace="$2"
  local only_config="$3"
  local verify_after="$4"
  local output_dir
  output_dir="$(dirname "$archive_path")"
  mkdir -p "$output_dir"

  local cmd=(openclaw backup create --output "$output_dir" --json)
  if [[ "$include_workspace" != "true" ]]; then
    cmd+=(--no-include-workspace)
  fi
  if [[ "$only_config" == "true" ]]; then
    cmd+=(--only-config)
  fi
  if [[ "$verify_after" == "true" ]]; then
    cmd+=(--verify)
  fi

  echo "[INFO] Creating archive via official OpenClaw backup..."
  echo "[INFO] ${cmd[*]}"

  local cmd_output
  cmd_output="$(${cmd[@]} 2>&1)"
  printf '%s\n' "$cmd_output"

  local generated
  generated="$(resolve_archive_from_output "$cmd_output" "$output_dir")"

  if [[ "$generated" != "$archive_path" ]]; then
    if [[ -e "$archive_path" ]]; then
      echo "[ERROR] Target archive already exists: $archive_path" >&2
      exit 1
    fi
    mv "$generated" "$archive_path"
    echo "[INFO] Renamed archive to: $archive_path"
  fi

  echo "[OK] Export finished: $archive_path"
}

create_lite_backup() {
  require_bin tar

  local archive_path="$1"
  local source_dir="$OPENCLAW_DIR_DEFAULT"
  local output_dir
  output_dir="$(dirname "$archive_path")"
  mkdir -p "$output_dir"

  if [[ ! -d "$source_dir" ]]; then
    echo "[ERROR] Source directory not found: $source_dir" >&2
    exit 1
  fi

  if [[ -e "$archive_path" ]]; then
    echo "[ERROR] Target archive already exists: $archive_path" >&2
    exit 1
  fi

  local -a excludes=(
    --exclude='.openclaw/browser'
    --exclude='.openclaw/logs'
    --exclude='.openclaw/media'
    --exclude='.openclaw/workspace/.venv-scrapling'
    --exclude='.openclaw/workspace/tmp'
    --exclude='.openclaw/workspace/runs'
    --exclude='.openclaw/workspace/downloads'
    --exclude='.openclaw/workspace/.git'
    --exclude='.openclaw/extensions/*/node_modules'
    --exclude='.openclaw/extensions/*/.turbo'
    --exclude='.openclaw/extensions/*/dist'
    --exclude='.openclaw/extensions/*/coverage'
    --exclude='.openclaw/extensions/.openclaw-install-backups'
  )

  echo "[INFO] Creating lite archive from: $source_dir"
  echo "[INFO] Excluding browser cache, logs, media, virtualenvs, temp dirs, downloads, workspace git, and extension node_modules."

  tar -czf "$archive_path" -C "$(dirname "$source_dir")" "${excludes[@]}" "$(basename "$source_dir")"

  echo "[INFO] Verifying tar readability..."
  tar -tzf "$archive_path" >/dev/null

  echo "[OK] Lite export finished: $archive_path"
}

find_import_root() {
  local extract_dir="$1"

  local candidate
  candidate="$(find "$extract_dir" -type d -path '*/payload/posix/*/.openclaw' | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -d "$extract_dir/.openclaw" ]]; then
    printf '%s\n' "$extract_dir/.openclaw"
    return 0
  fi

  if [[ -d "$extract_dir/openclaw-state/.openclaw" ]]; then
    printf '%s\n' "$extract_dir/openclaw-state/.openclaw"
    return 0
  fi

  candidate="$(find "$extract_dir" -type d -name .openclaw | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  echo "[ERROR] Could not find .openclaw directory inside extracted archive" >&2
  exit 1
}

write_snapshot_manifest() {
  local output_path="${1:-${SCRIPT_DIR}/openclaw-state-manifest-$(date +%F-%H%M%S).txt}"
  local base="$OPENCLAW_DIR_DEFAULT"

  mkdir -p "$(dirname "$output_path")"

  {
    echo "# OpenClaw state snapshot manifest"
    echo "generated_at=$(date -Iseconds)"
    echo "openclaw_dir=$base"
    echo

    echo "[version]"
    openclaw --version 2>/dev/null || true
    echo

    echo "[top-level entries under ~/.openclaw]"
    if [[ -d "$base" ]]; then
      find "$base" -mindepth 1 -maxdepth 1 | sort
    else
      echo "(missing $base)"
    fi
    echo

    echo "[plugins.entries from openclaw.json]"
    if [[ -f "$base/openclaw.json" ]]; then
      python3 - <<'PY' "$base/openclaw.json"
import json,sys
p=sys.argv[1]
obj=json.load(open(p,'r',encoding='utf-8'))
entries=((obj.get('plugins') or {}).get('entries') or {})
if isinstance(entries, dict):
    for k,v in entries.items():
        enabled = v.get('enabled') if isinstance(v,dict) else v
        print(f"{k}\tenabled={enabled}")
else:
    print('(unexpected plugins.entries format)')
PY
    else
      echo "(missing openclaw.json)"
    fi
    echo

    echo "[extensions directory]"
    if [[ -d "$base/extensions" ]]; then
      find "$base/extensions" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
        local id
        id="$(basename "$d")"
        echo "$id"
      done
    else
      echo "(no extensions directory)"
    fi
  } > "$output_path"

  echo "[OK] Snapshot manifest written: $output_path"
}

import_openclaw() {
  require_bin tar
  require_bin openclaw

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

  echo "[INFO] Verifying archive before import..."
  openclaw backup verify "$archive_path"

  echo "[INFO] Stopping gateway before import..."
  openclaw gateway stop >/dev/null 2>&1 || true

  local tmp_extract
  tmp_extract="$(mktemp -d)"
  trap 'cleanup_dir "$tmp_extract"' RETURN

  echo "[INFO] Extracting archive into temporary directory..."
  tar -xzf "$archive_path" -C "$tmp_extract"

  local import_root
  import_root="$(find_import_root "$tmp_extract")"

  local backup_dir=""
  if [[ -d "$openclaw_dir" && "$overwrite" == "true" ]]; then
    backup_dir="${openclaw_dir}.pre-import-$(date +%F-%H%M%S)"
    echo "[WARN] Moving existing directory aside for rollback: $backup_dir"
    mv "$openclaw_dir" "$backup_dir"
  elif [[ -d "$openclaw_dir" ]]; then
    echo "[ERROR] $openclaw_dir already exists. Use --overwrite to replace it." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$openclaw_dir")"
  cp -a "$import_root" "$openclaw_dir"

  echo "[INFO] Validating config..."
  openclaw config validate || true

  echo "[INFO] Starting gateway..."
  openclaw gateway start >/dev/null 2>&1 || true

  echo "[OK] Import finished. Recommended next steps:"
  echo "      $0 verify $archive_path"
  if [[ -n "$backup_dir" ]]; then
    echo "[INFO] Previous state kept at: $backup_dir"
    echo "[INFO] Delete it manually after validation if you no longer need rollback."
  fi
}

run_check() {
  local title="$1"
  shift
  echo
  echo "== $title =="
  "$@" || true
}

verify_workspace() {
  local ws="$OPENCLAW_DIR_DEFAULT/workspace"
  echo
  echo "== workspace checks =="
  [[ -d "$OPENCLAW_DIR_DEFAULT" ]] && echo "[OK] ~/.openclaw exists" || echo "[WARN] ~/.openclaw missing"
  [[ -f "$OPENCLAW_DIR_DEFAULT/openclaw.json" ]] && echo "[OK] openclaw.json exists" || echo "[WARN] openclaw.json missing"
  [[ -f "$ws/MEMORY.md" ]] && echo "[OK] MEMORY.md exists" || echo "[WARN] MEMORY.md missing"
  [[ -d "$ws/memory" ]] && echo "[OK] memory/ exists" || echo "[WARN] memory/ missing"
  [[ -d "$ws/skills" ]] && echo "[OK] workspace skills/ exists" || echo "[WARN] workspace skills/ missing"
}

verify_plugin_layout() {
  local base="$OPENCLAW_DIR_DEFAULT"
  echo
  echo "== plugin layout checks =="

  if [[ -f "$base/openclaw.json" ]]; then
    python3 - <<'PY' "$base/openclaw.json" "$base/extensions"
import json,sys,os
cfg=sys.argv[1]
ext_dir=sys.argv[2]
obj=json.load(open(cfg,'r',encoding='utf-8'))
entries=((obj.get('plugins') or {}).get('entries') or {})
if not isinstance(entries, dict):
    print('[WARN] plugins.entries format unexpected')
    raise SystemExit(0)
missing=[]
for pid,val in entries.items():
    enabled=True
    if isinstance(val,dict):
        enabled=val.get('enabled',True)
    if enabled and not os.path.isdir(os.path.join(ext_dir,pid)):
        missing.append(pid)
if missing:
    print('[WARN] enabled plugins missing extension dirs:', ', '.join(missing))
    print('[HINT] reinstall with: openclaw plugins install <plugin>')
else:
    print('[OK] enabled plugin extension directories look complete')
PY
  else
    echo "[WARN] openclaw.json missing; skip plugin layout validation"
  fi
}

verify_openclaw() {
  local archive_path="${1:-}"

  echo "[INFO] Running migration verification..."
  echo "[INFO] Note: plugin/runtime incompatibilities may surface here; treat them separately from archive integrity."

  if [[ -n "$archive_path" ]]; then
    echo "[INFO] Archive provided; verifying archive first..."
    openclaw backup verify "$archive_path" || true
  fi

  if command -v openclaw >/dev/null 2>&1; then
    run_check "openclaw version" openclaw --version
    run_check "openclaw status" openclaw status
    run_check "config validate" openclaw config validate
    run_check "channels probe" openclaw channels status --probe
    run_check "cron jobs" openclaw cron list
    run_check "skills check" openclaw skills check
    run_check "plugins list" openclaw plugins list
  else
    echo "[WARN] openclaw command not found; skip runtime checks."
  fi

  verify_plugin_layout
  verify_workspace

  echo
  echo "[OK] Verify step completed. Review WARN/ERROR lines above for follow-up."
}

backup_verify() {
  local archive_path="${1:-}"
  if [[ -z "$archive_path" ]]; then
    echo "[ERROR] backup-verify requires an archive path" >&2
    usage
    exit 1
  fi
  require_bin openclaw
  openclaw backup verify "$archive_path"
}

export_openclaw() {
  local archive_path="${1:-$ARCHIVE_DEFAULT}"
  local include_workspace="${2:-true}"
  local only_config="${3:-false}"
  local verify_after="${4:-true}"

  create_official_backup "$archive_path" "$include_workspace" "$only_config" "$verify_after"
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
      local include_workspace="true"
      local only_config="false"
      local verify_after="true"

      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        archive="$1"
        shift
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-include-workspace) include_workspace="false" ;;
          --only-config) only_config="true" ;;
          --skip-verify) verify_after="false" ;;
          *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
      done

      export_openclaw "$archive" "$include_workspace" "$only_config" "$verify_after"
      ;;

    export-lite)
      local archive="${1:-${SCRIPT_DIR}/openclaw-backup-lite-$(date +%F-%H%M%S).tar.gz}"
      create_lite_backup "$archive"
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
      verify_openclaw "${1:-}"
      ;;

    backup-verify)
      backup_verify "${1:-}"
      ;;

    snapshot-manifest)
      write_snapshot_manifest "${1:-}"
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
