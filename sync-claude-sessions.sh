#!/bin/bash
# sync-claude-sessions.sh
# Converts Claude Code JSONL sessions to clean markdown in your vault
#
# Uses hash-based change detection: re-syncs sessions when JSONL content changes.
# Safe to run repeatedly — only rewrites markdown when the source has changed.

# Load .env from script directory or repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for env_path in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../brain_clone/.env" "$HOME/.brain_clone.env"; do
    if [[ -f "$env_path" ]]; then
        # shellcheck disable=SC1090
        source "$env_path"
        break
    fi
done

# Portable helpers — macOS (BSD) and Linux (GNU) disagree on these commands.
if command -v md5sum &>/dev/null; then
    _hash_file() { md5sum "$1" | cut -d' ' -f1; }
else
    _hash_file() { md5 -q "$1"; }
fi
if stat -f '%m' / &>/dev/null 2>&1; then
    _mtime_epoch() { stat -f '%m' "$1"; }
    _epoch_fmt()   { date -r "$1" "+$2"; }
    _sed_inplace() { sed -i '' "$@"; }
else
    _mtime_epoch() { stat -c '%Y' "$1"; }
    _epoch_fmt()   { date -d "@$1" "+$2"; }
    _sed_inplace() { sed -i "$@"; }
fi

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/projects}"
VAULT_SESSIONS="${VAULT_PATH:-$HOME/vault}/sessions"
HASH_LOG="$VAULT_SESSIONS/.sync-hashes"

mkdir -p "$VAULT_SESSIONS"
touch "$HASH_LOG"

UPDATED=0
CREATED=0

# Find only top-level session JSONL files (skip subagents)
# Use process substitution to avoid subshell from pipe
while read -r session_file; do
    filename=$(basename "$session_file")
    session_id="${filename%.jsonl}"
    short_id="${session_id:0:8}"

    # Hash the JSONL to detect changes
    current_hash=$(_hash_file "$session_file")
    stored_hash=$(grep "^${filename}:" "$HASH_LOG" 2>/dev/null | cut -d: -f2)

    # Skip if unchanged
    if [[ "$current_hash" == "$stored_hash" ]]; then
        continue
    fi

    # Find existing output file for this session (match by short_id)
    existing_file=$(find "$VAULT_SESSIONS" -maxdepth 1 -name "session-*-${short_id}.md" -type f 2>/dev/null | head -1)

    # Extract the first timestamp from the JSONL for a stable filename
    first_ts=$(python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
            ts = entry.get('timestamp', '')
            if ts and entry.get('type') in ('user', 'assistant'):
                print(ts[:16].replace('T', '-').replace(':', '-'))
                break
        except: continue
" "$session_file" 2>/dev/null)

    # Fallback to mtime if no timestamp found
    if [[ -z "$first_ts" ]]; then
        mod_epoch=$(_mtime_epoch "$session_file" 2>/dev/null)
        first_ts=$(_epoch_fmt "$mod_epoch" "%Y-%m-%d-%H-%M" 2>/dev/null)
    fi

    output_file="$VAULT_SESSIONS/session-${first_ts}-${short_id}.md"

    # If existing file has a different name (mtime changed), remove old one
    if [[ -n "$existing_file" && "$existing_file" != "$output_file" ]]; then
        rm -f "$existing_file"
    fi

    # Parse JSONL: extract user/assistant messages from Claude Code format
    python3 -c "
import json, sys

messages = []
session_info = {}
with open(sys.argv[1], 'r') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
            entry_type = entry.get('type', '')

            if entry_type not in ('user', 'assistant'):
                continue

            msg = entry.get('message', {})
            role = msg.get('role', '')
            content = msg.get('content', '')

            if isinstance(content, list):
                text_parts = []
                for block in content:
                    if isinstance(block, dict) and block.get('type') == 'text':
                        text_parts.append(block.get('text', ''))
                    elif isinstance(block, str):
                        text_parts.append(block)
                content = '\n'.join(text_parts)

            if role in ('user', 'assistant') and isinstance(content, str) and content.strip():
                ts = entry.get('timestamp', '')
                header = f'## {role.title()}'
                if ts:
                    header += f' ({ts[:19]})'
                messages.append(f'{header}\n\n{content.strip()}\n')

            if not session_info and entry.get('cwd'):
                session_info['cwd'] = entry.get('cwd', '')
                session_info['branch'] = entry.get('gitBranch', '')
                session_info['version'] = entry.get('version', '')

        except (json.JSONDecodeError, AttributeError, TypeError):
            continue

if messages:
    print('---')
    print('type: session')
    if session_info.get('cwd'):
        print(f\"project: {session_info['cwd']}\")
    if session_info.get('branch'):
        print(f\"branch: {session_info['branch']}\")
    print(f'session_id: ${session_id}')
    print('---')
    print()
    print('\n---\n'.join(messages))
" "$session_file" > "$output_file" 2>/dev/null

    if [[ -s "$output_file" ]]; then
        # Update hash log (replace existing entry or append)
        if grep -q "^${filename}:" "$HASH_LOG" 2>/dev/null; then
            _sed_inplace "s|^${filename}:.*|${filename}:${current_hash}|" "$HASH_LOG"
            UPDATED=$((UPDATED + 1))
        else
            echo "${filename}:${current_hash}" >> "$HASH_LOG"
            CREATED=$((CREATED + 1))
        fi
    else
        rm -f "$output_file"
    fi
done < <(find "$SESSIONS_DIR" -maxdepth 2 -name "*.jsonl" -type f 2>/dev/null)

# Re-index QMD sessions collection
qmd update 2>/dev/null || true
