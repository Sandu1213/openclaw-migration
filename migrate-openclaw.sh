#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DEFAULT="${SCRIPT_DIR}/openclaw-migrate-$(date +%F-%H%M%S).tar.gz"
OPENCLAW_DIR_DEFAULT="${HOME}/.openclaw"

usage() {
  cat <<'EOF'
OpenClaw Migration Helper (enhanced)

Default behavior now prefers the official OpenClaw backup flow for archive creation
and keeps this script focused on import + migration verification.

Usage:
  migrate-openclaw.sh export [archive_path] [options]
  migrate-openclaw.sh import <archive_path> [--overwrite]
  migrate-openclaw.sh verify
  migrate-openclaw.sh backup-verify <archive_path>

Commands:
  export         Create backup archive. Defaults to official `openclaw backup create`.
  import         Restore archive into ~/.openclaw.
  verify         Run quick post-import / post-migration checks.
  backup-verify  Run official `openclaw backup verify` on an archive.

Export options:
  --include-agents        Add agents/ into the exported archive (repack on top of official backup).
  --legacy-export         Use the old custom packer instead of `openclaw backup create`.
  --no-include-workspace  Pass through to official backup create.
  --only-config           Pass through to official backup create.
  --skip-verify           Do not run official backup verification after export.

Import options:
  --overwrite             Move existing ~/.openclaw aside before import (rollback-friendly).

Examples:
  ./migrate-openclaw.sh export
  ./migrate-openclaw.sh export ./backup.tar.gz --skip-verify
  ./migrate-openclaw.sh export ./backup.tar.gz --include-agents
  ./migrate-openclaw.sh export ./backup.tar.gz --legacy-export --include-agents
  ./migrate-openclaw.sh export ./backup.tar.gz --no-include-workspace
  ./migrate-openclaw.sh import ./backup.tar.gz --overwrite
  ./migrate-openclaw.sh verify
  ./migrate-openclaw.sh backup-verify ./backup.tar.gz
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

write_plugin_manifest() {
  local root="$1"
  local manifest="$root/.openclaw/plugin-manifest.txt"
  : >"$manifest"

  {
    echo "# OpenClaw plugin manifest"
    echo "generated_at=$(date -Iseconds)"
    echo
    echo "[plugins.entries from openclaw.json]"
    if [[ -f "$root/.openclaw/openclaw.json" ]]; then
      python3 - <<'PY' "$root/.openclaw/openclaw.json"
import json,sys
p=sys.argv[1]
obj=json.load(open(p,'r',encoding='utf-8'))
entries=((obj.get('plugins') or {}).get('entries') or {})
if isinstance(entries, dict):
    for k,v in entries.items():
        enabled = v.get('enabled') if isinstance(v,dict) else v
        print(f"{k}\tenabled={enabled}")
else:
    print("(unexpected plugins.entries format)")
PY
    else
      echo "(missing openclaw.json)"
    fi

    echo
    echo "[extensions directory]"
    if [[ -d "$root/.openclaw/extensions" ]]; then
      find "$root/.openclaw/extensions" -mindepth 1 -maxdepth 1 -type d | while read -r d; do
        local id
        id="$(basename "$d")"
        local name=""
        local version=""
        if [[ -f "$d/package.json" ]]; then
          name="$(python3 - <<'PY' "$d/package.json"
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print(obj.get('name',''))
PY
)"
          version="$(python3 - <<'PY' "$d/package.json"
import json,sys
obj=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print(obj.get('version',''))
PY
)"
        fi
        echo "$id\tpackage=$name\tversion=$version"
      done
    else
      echo "(no extensions directory)"
    fi
  } >>"$manifest"

  echo "[INFO] Wrote plugin manifest: $manifest"
}

legacy_export_openclaw() {
  require_bin tar
  local archive_path="${1:-$ARCHIVE_DEFAULT}"
  local include_agents="${2:-false}"
  local openclaw_dir="$OPENCLAW_DIR_DEFAULT"

  if [[ ! -d "$openclaw_dir" ]]; then
    echo "[ERROR] Directory not found: $openclaw_dir" >&2
    exit 1
  fi

  echo "[INFO] Stopping gateway before legacy export..."
  openclaw gateway stop >/dev/null 2>&1 || true

  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'cleanup_dir "$tmp_root"' RETURN

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

  echo "[INFO] Collecting files for legacy export..."
  for p in "${include_paths[@]}"; do
    if [[ -e "$openclaw_dir/$p" ]]; then
      cp -a "$openclaw_dir/$p" "$tmp_root/.openclaw/"
    fi
  done

  write_plugin_manifest "$tmp_root"

  mkdir -p "$(dirname "$archive_path")"
  tar -czf "$archive_path" -C "$tmp_root" .openclaw

  echo "[OK] Legacy export finished: $archive_path"
  if [[ "$include_agents" != "true" ]]; then
    echo "[INFO] agents/ was excluded. Use --include-agents if you need session history."
  fi
}

parse_archive_path_from_output() {
  local output="$1"
  python3 - <<'PY' "$output"
import json, re, sys
text = sys.argv[1]

# Try JSON lines / plain JSON first.
for line in reversed([ln for ln in text.splitlines() if ln.strip()]):
    try:
        obj = json.loads(line)
        if isinstance(obj, dict):
            for key in ("archive", "archivePath", "path", "output"):
                value = obj.get(key)
                if isinstance(value, str) and value.endswith('.tar.gz'):
                    print(value)
                    raise SystemExit(0)
    except Exception:
        pass

# Fallback for human-readable output.
patterns = [
    r'([~/][^\s]*openclaw-backup[^\s]*\.tar\.gz)',
    r'((?:/|\./|\.\./)[^\s]*openclaw-backup[^\s]*\.tar\.gz)',
    r'(openclaw-backup[^\s]*\.tar\.gz)'
]
for pattern in patterns:
    matches = re.findall(pattern, text)
    if matches:
        print(matches[-1])
        raise SystemExit(0)
PY
}

resolve_generated_archive() {
  local output="$1"
  local output_dir="$2"
  local parsed
  parsed="$(parse_archive_path_from_output "$output" || true)"

  if [[ -n "$parsed" ]]; then
    if [[ "$parsed" == ~/* ]]; then
      parsed="${HOME}/${parsed#~/}"
    elif [[ "$parsed" != /* ]]; then
      parsed="${output_dir}/${parsed#./}"
    fi
  fi

  if [[ -n "$parsed" && -f "$parsed" ]]; then
    printf '%s\n' "$parsed"
    return 0
  fi

  local recent_files=()
  local recent_output
  recent_output="$(find "$output_dir" -maxdepth 1 -type f -name '*openclaw-backup*.tar.gz' -mmin -5 -print 2>/dev/null | sort || true)"
  if [[ -n "$recent_output" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && recent_files+=("$line")
    done <<EOF
$recent_output
EOF
  fi

  if [[ "${#recent_files[@]}" -eq 1 ]]; then
    printf '%s\n' "${recent_files[0]}"
    return 0
  fi

  if [[ "${#recent_files[@]}" -gt 1 ]]; then
    echo "[ERROR] Multiple candidate official backup archives found in $output_dir; refusing to guess." >&2
    printf '  %s\n' "${recent_files[@]}" >&2
    echo "[HINT] Use an empty output directory or rely on official output naming." >&2
    exit 1
  fi

  echo "[ERROR] Could not locate generated official backup archive in $output_dir" >&2
  exit 1
}

create_official_backup() {
  local archive_path="$1"
  local include_workspace="$2"
  local only_config="$3"
  local verify_after="$4"

  require_bin openclaw
  local output_dir
  output_dir="$(dirname "$archive_path")"
  mkdir -p "$output_dir"

  local cmd=(openclaw backup create --output "$output_dir")
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
  generated="$(resolve_generated_archive "$cmd_output" "$output_dir")"

  if [[ "$generated" != "$archive_path" ]]; then
    if [[ -e "$archive_path" ]]; then
      echo "[ERROR] Target archive already exists: $archive_path" >&2
      exit 1
    fi
    mv "$generated" "$archive_path"
    echo "[INFO] Renamed official archive to: $archive_path"
  fi

  echo "[OK] Official backup archive ready: $archive_path"
}

append_agents_and_metadata() {
  local archive_path="$1"
  local include_agents="$2"
  local openclaw_dir="$OPENCLAW_DIR_DEFAULT"

  if [[ "$include_agents" != "true" ]]; then
    return 0
  fi

  require_bin tar
  if [[ ! -d "$openclaw_dir/agents" ]]; then
    echo "[WARN] agents/ not found under $openclaw_dir, skipping agents append"
    return 0
  fi

  echo "[INFO] Repacking archive to include agents/ and migration metadata..."

  local tmp_extract repacked
  tmp_extract="$(mktemp -d)"
  repacked="${archive_path%.tar.gz}.repacked.tar.gz"
  trap 'cleanup_dir "$tmp_extract"; [[ -f "$repacked" ]] && rm -f "$repacked"' RETURN

  tar -xzf "$archive_path" -C "$tmp_extract"

  local extracted_root
  extracted_root="$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -z "$extracted_root" ]]; then
    echo "[ERROR] Could not determine extracted archive root while appending agents" >&2
    exit 1
  fi

  if [[ ! -d "$extracted_root/agents" ]]; then
    cp -a "$openclaw_dir/agents" "$extracted_root/agents"
  fi

  write_plugin_manifest "$tmp_extract"

  tar -czf "$repacked" -C "$tmp_extract" "$(basename "$extracted_root")"
  mv "$repacked" "$archive_path"

  echo "[OK] Added agents/ and plugin manifest to: $archive_path"
}

export_openclaw() {
  local archive_path="${1:-$ARCHIVE_DEFAULT}"
  local include_agents="${2:-false}"
  local legacy_export="${3:-false}"
  local include_workspace="${4:-true}"
  local only_config="${5:-false}"
  local verify_after="${6:-true}"

  if [[ "$legacy_export" == "true" ]]; then
    legacy_export_openclaw "$archive_path" "$include_agents"
    return 0
  fi

  create_official_backup "$archive_path" "$include_workspace" "$only_config" "$verify_after"
  append_agents_and_metadata "$archive_path" "$include_agents"

  if [[ "$verify_after" == "true" ]]; then
    echo "[INFO] Running final official backup verification after repack..."
    openclaw backup verify "$archive_path"
  fi

  echo "[OK] Export finished: $archive_path"
  echo "[INFO] Default path now uses official OpenClaw backup create; this script adds migration-oriented extras on top."
}

find_import_root() {
  local extract_dir="$1"

  if [[ -d "$extract_dir/.openclaw" ]]; then
    printf '%s\n' "$extract_dir/.openclaw"
    return 0
  fi

  if [[ -d "$extract_dir/openclaw-state/.openclaw" ]]; then
    printf '%s\n' "$extract_dir/openclaw-state/.openclaw"
    return 0
  fi

  local candidate
  candidate="$(find "$extract_dir" -type d -name .openclaw | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  echo "[ERROR] Could not find .openclaw directory inside extracted archive" >&2
  exit 1
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
  echo "      $0 backup-verify $archive_path"
  echo "      $0 verify"
  if [[ -n "$backup_dir" ]]; then
    echo "[INFO] Previous state kept at: $backup_dir"
    echo "[INFO] Delete it manually after validation if you no longer need rollback."
  fi
}

verify_plugins() {
  local base="$OPENCLAW_DIR_DEFAULT"
  echo "\n== plugin checks =="

  if [[ -f "$base/plugin-manifest.txt" ]]; then
    echo "[OK] plugin-manifest.txt exists"
  else
    echo "[WARN] plugin-manifest.txt missing"
  fi

  if command -v openclaw >/dev/null 2>&1; then
    openclaw plugins list || true
  fi

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
  fi
}

verify_openclaw() {
  echo "[INFO] Running post-migration checks..."

  if command -v openclaw >/dev/null 2>&1; then
    echo "\n== openclaw status =="
    openclaw status || true

    echo "\n== channels probe =="
    openclaw channels status --probe || true

    echo "\n== cron jobs =="
    openclaw cron list || true

    echo "\n== skills check =="
    openclaw skills check || true
  else
    echo "[WARN] openclaw command not found; skip runtime checks."
  fi

  verify_plugins

  local ws="$OPENCLAW_DIR_DEFAULT/workspace"
  echo "\n== workspace checks =="
  [[ -f "$ws/MEMORY.md" ]] && echo "[OK] MEMORY.md exists" || echo "[WARN] MEMORY.md missing"
  [[ -d "$ws/memory" ]] && echo "[OK] memory/ exists" || echo "[WARN] memory/ missing"
  [[ -d "$ws/skills" ]] && echo "[OK] workspace skills/ exists" || echo "[WARN] workspace skills/ missing"

  echo "\n[OK] Verify step completed."
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
      local legacy_export="false"
      local include_workspace="true"
      local only_config="false"
      local verify_after="true"

      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        archive="$1"
        shift
      fi

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --include-agents) include_agents="true" ;;
          --legacy-export) legacy_export="true" ;;
          --no-include-workspace) include_workspace="false" ;;
          --only-config) only_config="true" ;;
          --skip-verify) verify_after="false" ;;
          *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
      done

      export_openclaw "$archive" "$include_agents" "$legacy_export" "$include_workspace" "$only_config" "$verify_after"
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

    backup-verify)
      backup_verify "${1:-}"
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
