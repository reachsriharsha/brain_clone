#!/bin/bash
set -e

# =============================================================================
# install.sh — QMD + Obsidian Second Brain Setup
#
# A single interactive script that:
#   1. Installs prerequisites (Bun, QMD)
#   2. Creates an Obsidian vault folder structure
#   3. Registers QMD collections with context descriptions
#   4. Optionally sets up /recall skill, session sync, and MCP server
#
# Safe to re-run. Detects previous installation and offers clean reinstall.
# =============================================================================

# --- Section 0: Load .env if present ----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
fi

# --- Section 1: Utility functions -------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}=== $* ===${NC}\n"; }

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n] "
    else
        prompt="$prompt [y/N] "
    fi
    read -rp "$prompt" yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1" default="$2" result
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -rp "$prompt: " result
        echo "$result"
    fi
}

# --- Section 2: Platform detection ------------------------------------------

header "Platform Detection"

PLATFORM="linux"
IS_WSL=false
CLAUDE_DESKTOP_CONFIG=""

if [[ "$(uname)" == "Darwin" ]]; then
    PLATFORM="macos"
    CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    info "Detected: macOS"
elif grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="linux"
    IS_WSL=true
    # WSL: Claude Desktop config lives on the Windows side
    WIN_USER=$(cmd.exe /C "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)
    if [[ -n "$WIN_USER" ]]; then
        CLAUDE_DESKTOP_CONFIG="/mnt/c/Users/$WIN_USER/AppData/Roaming/Claude/claude_desktop_config.json"
    fi
    info "Detected: WSL2 (Windows user: ${WIN_USER:-unknown})"
else
    PLATFORM="linux"
    CLAUDE_DESKTOP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
    info "Detected: Linux"
fi

# --- Section 2b: Re-run detection -------------------------------------------

IS_REINSTALL=false
EXISTING_ITEMS=()

# Check for signs of a previous installation
[[ -f "${SYNC_SCRIPT_PATH:-$HOME/.local/bin/sync-claude-sessions.sh}" ]] && EXISTING_ITEMS+=("sync script")
[[ -f "${SKILL_DIR:-$HOME/.claude/skills/recall}/SKILL.md" ]] && EXISTING_ITEMS+=("recall skill")
[[ -f "${HOOKS_FILE:-$HOME/.claude/hooks.json}" ]] && EXISTING_ITEMS+=("hooks config")
[[ -f "$HOME/.config/systemd/user/qmd-mcp.service" ]] && EXISTING_ITEMS+=("systemd service")
command -v qmd &>/dev/null && qmd collection list 2>/dev/null | grep -q "qmd://" && EXISTING_ITEMS+=("QMD collections")

if [[ ${#EXISTING_ITEMS[@]} -gt 0 ]]; then
    echo ""
    warn "Previous brain_clone installation detected:"
    for item in "${EXISTING_ITEMS[@]}"; do
        echo -e "  ${YELLOW}•${NC} $item"
    done
    echo ""
    warn "Re-running will OVERWRITE the following generated files:"
    echo -e "  ${YELLOW}•${NC} Sync script (${SYNC_SCRIPT_PATH:-~/.local/bin/sync-claude-sessions.sh})"
    echo -e "  ${YELLOW}•${NC} Recall skill (~/.claude/skills/recall/SKILL.md)"
    echo -e "  ${YELLOW}•${NC} Hooks config (~/.claude/hooks.json)"
    echo -e "  ${YELLOW}•${NC} Systemd service (~/.config/systemd/user/qmd-mcp.service)"
    echo -e "  ${YELLOW}•${NC} QMD collection registrations"
    echo ""
    info "Vault content (notes, daily logs, etc.) will NOT be touched."
    echo ""
    if ask_yn "Continue with reinstall?"; then
        IS_REINSTALL=true
    else
        echo "Aborted."
        exit 0
    fi
fi

# --- Section 3: Interactive input collection ---------------------------------

header "Configuration"

VAULT_PATH=$(ask_input "Vault path" "${VAULT_PATH:-$HOME/vault}")
# Expand tilde
VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

echo ""
echo "Collection groups:"
echo "  1) Dev harness    — notes, daily, sessions, transcripts, skills"
echo "  2) Second brain   — thoughts, people, references, weekly-reviews"
echo "  3) Both (recommended)"
echo ""
COLLECTION_GROUP=$(ask_input "Which groups? (1/2/3)" "3")

DEV_COLLECTIONS=()
BRAIN_COLLECTIONS=()

case "$COLLECTION_GROUP" in
    1)
        DEV_COLLECTIONS=(notes daily sessions transcripts skills)
        ;;
    2)
        BRAIN_COLLECTIONS=(thoughts people references weekly-reviews)
        ;;
    3|*)
        DEV_COLLECTIONS=(notes daily sessions transcripts skills)
        BRAIN_COLLECTIONS=(thoughts people references weekly-reviews)
        ;;
esac

ALL_COLLECTIONS=("${DEV_COLLECTIONS[@]}" "${BRAIN_COLLECTIONS[@]}")

echo ""
SETUP_RECALL=false
SETUP_SYNC=false
SETUP_MCP=false

if ask_yn "Set up /recall Claude Code skill?"; then
    SETUP_RECALL=true
fi

if ask_yn "Set up session sync script + Claude Code hook?"; then
    SETUP_SYNC=true
fi

if ask_yn "Configure QMD MCP server for Claude Desktop?"; then
    SETUP_MCP=true
    MCP_SERVER_NAME=$(ask_input "MCP server name" "${MCP_SERVER_NAME:-qmd}")
fi

SETUP_MCP_HTTP=false
if ask_yn "Start QMD MCP HTTP daemon (accessible from VS Code, Cursor, scripts)?"; then
    SETUP_MCP_HTTP=true
    MCP_HTTP_PORT=$(ask_input "HTTP port" "${MCP_HTTP_PORT:-8181}")
    if ! $SETUP_MCP; then
        MCP_SERVER_NAME=$(ask_input "MCP server name" "${MCP_SERVER_NAME:-qmd}")
    fi
fi

echo ""
header "Summary"
info "Vault path:    $VAULT_PATH"
info "Collections:   ${ALL_COLLECTIONS[*]}"
info "Recall skill:  $SETUP_RECALL"
info "Session sync:  $SETUP_SYNC"
info "MCP config:    $SETUP_MCP"
info "MCP HTTP:      $SETUP_MCP_HTTP"
$SETUP_MCP || $SETUP_MCP_HTTP && info "Server name:   ${MCP_SERVER_NAME:-qmd}"
echo ""

if ! ask_yn "Proceed with installation?"; then
    echo "Aborted."
    exit 0
fi

# --- Section 4: Prerequisite installation ------------------------------------

header "Prerequisites"

# Check/install Node.js >= 22 (required by QMD at runtime)
NODE_OK=false
if command -v node &>/dev/null; then
    NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ "$NODE_VER" -ge "${NODE_MIN_VERSION:-22}" ]]; then
        NODE_OK=true
        success "Node.js already installed: $(node --version)"
    else
        warn "Node.js $(node --version) found, but QMD requires >= ${NODE_MIN_VERSION:-22}"
    fi
fi

if ! $NODE_OK; then
    info "Installing Node.js 22 LTS..."
    if [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null; then
        brew install node@22
        export PATH="/opt/homebrew/opt/node@22/bin:/usr/local/opt/node@22/bin:$PATH"
    else
        # Use NodeSource setup for Linux/WSL
        if command -v curl &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
            info "Running NodeSource setup (requires sudo)..."
            sudo -E bash /tmp/nodesource_setup.sh
            sudo apt-get install -y nodejs
            rm -f /tmp/nodesource_setup.sh
        else
            error "curl not found. Install Node.js >= 22 manually: https://nodejs.org"
            exit 1
        fi
    fi

    if command -v node &>/dev/null; then
        NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
        if [[ "$NODE_VER" -ge "${NODE_MIN_VERSION:-22}" ]]; then
            success "Node.js installed: $(node --version)"
        else
            error "Node.js $(node --version) installed but QMD requires >= ${NODE_MIN_VERSION:-22}."
            error "Install manually: https://nodejs.org"
            exit 1
        fi
    else
        error "Node.js installation failed. Install manually: https://nodejs.org"
        exit 1
    fi
fi

# Check/install Bun
if command -v bun &>/dev/null; then
    success "Bun already installed: $(bun --version)"
else
    info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    # Source bun into current shell
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
    if command -v bun &>/dev/null; then
        success "Bun installed: $(bun --version)"
    else
        error "Bun installation failed. Install manually: https://bun.sh"
        exit 1
    fi
fi

# Ensure bun global bin is in PATH for this session
BUN_GLOBAL_BIN="$(bun pm bin -g 2>/dev/null || echo "$HOME/.bun/bin")"
export PATH="$BUN_GLOBAL_BIN:$PATH"

# Check/install QMD
if command -v qmd &>/dev/null; then
    success "QMD already installed: $(qmd --version 2>/dev/null || echo 'installed')"
else
    info "Installing QMD via Bun (package: @tobilu/qmd)..."
    # QMD runs under Node.js (not Bun) and needs better-sqlite3 native module.
    # Install with bun, then rebuild native modules with npm for Node.js compat.
    bun install -g @tobilu/qmd --ignore-scripts || {
        error "QMD installation failed."
        error "Try manually: bun install -g @tobilu/qmd"
        error "Or check: https://github.com/tobi/qmd"
        exit 1
    }
    info "Rebuilding native modules for Node.js..."
    npm rebuild better-sqlite3 --prefix "$(bun pm bin -g 2>/dev/null | sed 's|/bin$||')/../install/global" 2>/dev/null \
        || (cd "$(dirname "$(which bun)")/../install/global" && npm rebuild better-sqlite3) 2>/dev/null \
        || npm rebuild better-sqlite3 --prefix "$HOME/.bun/install/global" \
        || {
            error "Failed to rebuild better-sqlite3."
            error "Try manually: cd ~/.bun/install/global && npm rebuild better-sqlite3"
            exit 1
        }
    if command -v qmd &>/dev/null; then
        success "QMD installed"
    else
        error "QMD installed but 'qmd' not found in PATH."
        error "Bun global bin: $BUN_GLOBAL_BIN"
        error "Add it to your PATH and re-run this script:"
        error "  export PATH=\"$BUN_GLOBAL_BIN:\$PATH\""
        exit 1
    fi
fi

# --- Section 5: Vault structure creation -------------------------------------

header "Vault Structure"

# Create all collection directories
for col in "${ALL_COLLECTIONS[@]}"; do
    dir="$VAULT_PATH/$col"
    mkdir -p "$dir"
    success "Created $dir"
done

# Create template directories
mkdir -p "$VAULT_PATH/daily/templates"
mkdir -p "$VAULT_PATH/weekly-reviews/templates" 2>/dev/null || true

# Write daily template (non-destructive)
DAILY_TEMPLATE="$VAULT_PATH/daily/templates/daily-template.md"
if [[ ! -f "$DAILY_TEMPLATE" ]]; then
    cat > "$DAILY_TEMPLATE" << 'TMPL'
---
date: {{date}}
type: daily
energy: /5
mood:
---

# {{date}} — Daily Log

## Morning Check-in
- Energy: /5
- Focus goal:

## Standup
- **Yesterday:**
- **Today:**
- **Blockers:**

## Notes


## End of Day
- Wins:
- Learned:
- Tomorrow:

TMPL
    success "Created daily template"
else
    warn "Daily template already exists, skipping"
fi

# Write weekly review template (non-destructive)
WEEKLY_TEMPLATE="$VAULT_PATH/weekly-reviews/templates/weekly-template.md"
if [[ ! -f "$WEEKLY_TEMPLATE" ]]; then
    cat > "$WEEKLY_TEMPLATE" << 'TMPL'
---
week: {{week}}
type: weekly-review
date_start: {{monday}}
date_end: {{sunday}}
---

# Week {{week}} Review

## Key Wins
-

## What I Learned
-

## Patterns Noticed
-

## Challenges / Blockers
-

## Goals for Next Week
- [ ]
- [ ]
- [ ]

## Energy & Mood Trend
- Average energy:
- Best day:
- Worst day:

## People & Connections
-

## Open Threads
- Carrying forward:

TMPL
    success "Created weekly review template"
else
    warn "Weekly review template already exists, skipping"
fi

# --- Section 6: QMD setup ---------------------------------------------------

header "QMD Collections"

# Map collection directory names to QMD collection names
declare -A COL_NAMES=(
    ["notes"]="notes"
    ["daily"]="daily"
    ["sessions"]="sessions"
    ["transcripts"]="transcripts"
    ["skills"]="skills"
    ["thoughts"]="thoughts"
    ["people"]="people"
    ["references"]="references"
    ["weekly-reviews"]="weekly"
)

declare -A COL_CONTEXTS=(
    ["notes"]="Project notes, architecture decisions, research"
    ["daily"]="Daily journal, standup, mood, energy, blockers"
    ["sessions"]="Claude Code session exports, coding conversations"
    ["transcripts"]="Meeting transcripts, voice memos, call notes"
    ["skills"]="Claude Code skills and automation definitions"
    ["thoughts"]="Quick captures: ideas, observations, tasks"
    ["people"]="People profiles, relationship notes, contact context"
    ["references"]="Bookmarks, articles, external resources"
    ["weekly"]="Weekly reviews, goal tracking, reflections"
)

# Register collections
for col in "${ALL_COLLECTIONS[@]}"; do
    name="${COL_NAMES[$col]}"
    path="$VAULT_PATH/$col"
    info "Registering collection: $name -> $path"
    qmd collection add "$path" --name "$name" 2>/dev/null || true
done

echo ""

# Add context descriptions
for col in "${ALL_COLLECTIONS[@]}"; do
    name="${COL_NAMES[$col]}"
    ctx="${COL_CONTEXTS[$name]}"
    if [[ -n "$ctx" ]]; then
        info "Adding context for $name"
        qmd context add "qmd://$name" "$ctx" 2>/dev/null || true
    fi
done

echo ""
info "Building index (this may take a moment on first run)..."
qmd embed 2>/dev/null || warn "qmd embed had issues (vault may be empty, that's OK)"
success "QMD setup complete"

# --- Section 7: Optional — /recall skill ------------------------------------

if $SETUP_RECALL; then
    header "Recall Skill"

    SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/recall}"
    SKILL_FILE="$SKILL_DIR/SKILL.md"

    mkdir -p "$SKILL_DIR"

    if [[ -f "$SKILL_FILE" ]] && ! $IS_REINSTALL; then
        warn "Recall skill already exists, skipping"
    else
        $IS_REINSTALL && [[ -f "$SKILL_FILE" ]] && info "Updating recall skill..."
        cat > "$SKILL_FILE" << 'SKILL'
# /recall — Search Your Second Brain

## Purpose
Search your QMD-indexed vault (notes, sessions, daily logs, thoughts, people, references, transcripts, weekly reviews) to load relevant context.

## Vault Collections
- **sessions** — Claude Code session exports
- **notes** — Project notes, architecture decisions
- **daily** — Daily journal, standup, blockers
- **thoughts** — Quick captures, ideas, observations
- **people** — People profiles, relationship notes
- **references** — Bookmarks, articles, resources
- **transcripts** — Meeting transcripts, voice memos
- **weekly** — Weekly reviews, reflections
- **skills** — Claude Code skill definitions

## Modes

### Temporal — What happened on a date?
Usage: `/recall yesterday`, `/recall last week`, `/recall 2026-03-04`

Implementation:
- Convert the date reference to YYYY-MM-DD format
- Run: `qmd search "YYYY-MM-DD" -c sessions -n 20`
- Also run: `qmd search "YYYY-MM-DD" -c daily -n 5`
- Summarize: timeline, session count, key decisions, open items

### Topic — Find everything about X
Usage: `/recall topic <query>` or `/recall <query>`

BM25 keyword search across all collections.

Implementation — run ALL in parallel:
- `qmd search "<query>" -c sessions -n 5`
- `qmd search "<query>" -c notes -n 5`
- `qmd search "<query>" -c daily -n 3`
- `qmd search "<query>" -c thoughts -n 3`
- `qmd search "<query>" -c people -n 3`
- `qmd search "<query>" -c references -n 3`
- `qmd search "<query>" -c transcripts -n 3`
- `qmd search "<query>" -c weekly -n 3`
- Synthesize results into a unified context summary
- Include qmd:// paths so the user can open them directly

### Deep — Semantic search for concepts
Usage: `/recall deep <query>`

Hybrid search with query expansion + reranking (requires embeddings).

Implementation:
- Run: `qmd query "<query>"`
- Present top results with context and relevance explanation

### Read — Get full document content
Usage: `/recall read <path>`

Retrieve the full content of a specific document found in search results.

Implementation:
- Run: `qmd get <qmd://path>` for a single document
- Run: `qmd get <qmd://path>:50 -l 30` for a specific section (line 50, 30 lines)
- Run: `qmd multi-get "sessions/session-2026-03*"` for multiple docs by glob

### List — Browse a collection
Usage: `/recall list <collection>`

Implementation:
- Run: `qmd ls <collection>` to list files in a collection
- Run: `qmd ls` to list all collections with file counts

### Status — Check vault health
Usage: `/recall status`

Implementation:
- Run: `qmd status`
- Report: collection counts, index size, embedding status

## Output Flags (can be used with any search mode)
- Add `--full` to get complete documents instead of snippets
- Add `--json` for structured output
- Add `-n <num>` to control number of results
- Add `--min-score <num>` to filter by relevance
SKILL
        success "Created /recall skill at $SKILL_FILE"
    fi
fi

# --- Section 8: Optional — Session sync + hooks -----------------------------

if $SETUP_SYNC; then
    header "Session Sync"

    SYNC_SCRIPT="${SYNC_SCRIPT_PATH:-$HOME/.local/bin/sync-claude-sessions.sh}"
    mkdir -p "$HOME/.local/bin"

    if [[ -f "$SYNC_SCRIPT" ]] && ! $IS_REINSTALL; then
        warn "Sync script already exists, skipping"
    else
        $IS_REINSTALL && [[ -f "$SYNC_SCRIPT" ]] && info "Updating sync script..."
        cat > "$SYNC_SCRIPT" << 'SYNC'
#!/bin/bash
# sync-claude-sessions.sh
# Converts Claude Code JSONL sessions to clean markdown in your vault
# Uses hash-based change detection: re-syncs sessions when JSONL content changes.

# Load .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for env_path in "$SCRIPT_DIR/.env" "$HOME/.brain_clone.env"; do
    if [[ -f "$env_path" ]]; then
        # shellcheck disable=SC1090
        source "$env_path"
        break
    fi
done

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/projects}"
VAULT_SESSIONS="${VAULT_PATH:-$HOME/vault}/sessions"
HASH_LOG="$VAULT_SESSIONS/.sync-hashes"

mkdir -p "$VAULT_SESSIONS"
touch "$HASH_LOG"

# Find only top-level session JSONL files (skip subagents)
while read -r session_file; do
    filename=$(basename "$session_file")
    session_id="${filename%.jsonl}"
    short_id="${session_id:0:8}"

    # Hash the JSONL to detect changes
    current_hash=$(md5sum "$session_file" | cut -d' ' -f1)
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
        mod_epoch=$(stat -c '%Y' "$session_file" 2>/dev/null)
        first_ts=$(date -d @"$mod_epoch" "+%Y-%m-%d-%H-%M" 2>/dev/null)
    fi

    output_file="$VAULT_SESSIONS/session-${first_ts}-${short_id}.md"

    # If existing file has a different name, remove old one
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
    print(f'session_id: $session_id')
    print('---')
    print()
    print('\n---\n'.join(messages))
" "$session_file" > "$output_file" 2>/dev/null

    if [[ -s "$output_file" ]]; then
        # Update hash log (replace existing entry or append)
        if grep -q "^${filename}:" "$HASH_LOG" 2>/dev/null; then
            sed -i "s|^${filename}:.*|${filename}:${current_hash}|" "$HASH_LOG"
        else
            echo "${filename}:${current_hash}" >> "$HASH_LOG"
        fi
    else
        rm -f "$output_file"
    fi
done < <(find "$SESSIONS_DIR" -maxdepth 2 -name "*.jsonl" -type f 2>/dev/null)

# Re-index QMD sessions collection
qmd update 2>/dev/null || true
SYNC
        chmod +x "$SYNC_SCRIPT"
        success "Created sync script at $SYNC_SCRIPT"
    fi

    # Create .brain_clone.env symlink so sync script can find vault path
    ENV_FILE="$SCRIPT_DIR/.env"
    ENV_LINK="$HOME/.brain_clone.env"
    if [[ -f "$ENV_FILE" ]]; then
        ln -sf "$ENV_FILE" "$ENV_LINK" 2>/dev/null && \
            success "Linked $ENV_LINK -> $ENV_FILE"
    else
        # Write a minimal .env for the sync script
        cat > "$ENV_LINK" << ENVFILE
VAULT_PATH="$VAULT_PATH"
CLAUDE_SESSIONS_DIR="\$HOME/.claude/projects"
ENVFILE
        success "Created $ENV_LINK"
    fi

    # Set up Claude Code hooks
    HOOKS_FILE="${HOOKS_FILE:-$HOME/.claude/hooks.json}"
    mkdir -p "$HOME/.claude"

    if [[ -f "$HOOKS_FILE" ]]; then
        # Check if our hook is already present
        if grep -q "sync-claude-sessions" "$HOOKS_FILE" 2>/dev/null && ! $IS_REINSTALL; then
            warn "Session sync hook already configured, skipping"
        else
            # Back up before modifying
            cp "$HOOKS_FILE" "$HOOKS_FILE.bak.$(date +%s)"
            warn "Backed up existing hooks.json"
            # Merge our hook into existing config using python
            python3 -c "
import json, sys

with open('$HOOKS_FILE', 'r') as f:
    hooks = json.load(f)

if 'hooks' not in hooks:
    hooks['hooks'] = {}

event = 'Stop'
if event not in hooks['hooks']:
    hooks['hooks'][event] = []

hooks['hooks'][event].append({
    'type': 'command',
    'command': '$SYNC_SCRIPT'
})

with open('$HOOKS_FILE', 'w') as f:
    json.dump(hooks, f, indent=2)
    f.write('\n')
" 2>/dev/null && success "Added session sync hook to existing hooks.json" \
              || warn "Could not merge hooks — add manually"
        fi
    else
        cat > "$HOOKS_FILE" << HOOKS
{
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "command": "$SYNC_SCRIPT"
      }
    ]
  }
}
HOOKS
        success "Created hooks.json with session sync hook"
    fi
fi

# --- Section 9: Optional — MCP server config --------------------------------

if $SETUP_MCP; then
    header "MCP Server Configuration (Claude Desktop — stdio)"

    if [[ -z "$CLAUDE_DESKTOP_CONFIG" ]]; then
        warn "Could not determine Claude Desktop config path for this platform."
        warn "Add this to your Claude Desktop config manually:"
        echo ""
        echo "  \"mcpServers\": {"
        echo "    \"$MCP_SERVER_NAME\": {"
        echo '      "command": "qmd",'
        echo '      "args": ["mcp"]'
        echo '    }'
        echo '  }'
        echo ""
    else
        CONFIG_DIR=$(dirname "$CLAUDE_DESKTOP_CONFIG")
        mkdir -p "$CONFIG_DIR" 2>/dev/null || true

        if [[ -f "$CLAUDE_DESKTOP_CONFIG" ]]; then
            if grep -q "\"$MCP_SERVER_NAME\"" "$CLAUDE_DESKTOP_CONFIG" 2>/dev/null && ! $IS_REINSTALL; then
                warn "MCP server '$MCP_SERVER_NAME' already configured, skipping"
            else
                cp "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_CONFIG.bak.$(date +%s)"
                warn "Backed up existing Claude Desktop config"
                python3 -c "
import json, sys

name = sys.argv[1]
config_path = sys.argv[2]

with open(config_path, 'r') as f:
    config = json.load(f)

if 'mcpServers' not in config:
    config['mcpServers'] = {}

config['mcpServers'][name] = {
    'command': 'qmd',
    'args': ['mcp']
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" "$MCP_SERVER_NAME" "$CLAUDE_DESKTOP_CONFIG" 2>/dev/null \
    && success "Added MCP server '$MCP_SERVER_NAME' to Claude Desktop config" \
    || warn "Could not merge config — add manually"
            fi
        else
            python3 -c "
import json, sys
name = sys.argv[1]
config = {'mcpServers': {name: {'command': 'qmd', 'args': ['mcp']}}}
with open(sys.argv[2], 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" "$MCP_SERVER_NAME" "$CLAUDE_DESKTOP_CONFIG" 2>/dev/null
            success "Created Claude Desktop config with MCP server '$MCP_SERVER_NAME'"
        fi
    fi
fi

# --- Section 9b: Optional — MCP HTTP daemon ----------------------------------

if $SETUP_MCP_HTTP; then
    header "MCP HTTP Daemon"

    # Create systemd user service for auto-start
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_FILE="$SYSTEMD_DIR/qmd-mcp.service"
    mkdir -p "$SYSTEMD_DIR"

    if [[ -f "$SERVICE_FILE" ]] && ! $IS_REINSTALL; then
        warn "Systemd service already exists, skipping"
    else
        $IS_REINSTALL && [[ -f "$SERVICE_FILE" ]] && info "Updating systemd service..."
        cat > "$SERVICE_FILE" << UNIT
[Unit]
Description=QMD MCP HTTP Server
After=network.target

[Service]
ExecStart=$(which qmd) mcp --http --port ${MCP_HTTP_PORT}
Restart=on-failure
RestartSec=5
Environment=PATH=$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNIT
        success "Created systemd service at $SERVICE_FILE"
    fi

    # Enable and start the service
    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable qmd-mcp.service 2>/dev/null
        systemctl --user restart qmd-mcp.service 2>/dev/null
        sleep 1
        if systemctl --user is-active --quiet qmd-mcp.service 2>/dev/null; then
            success "MCP HTTP daemon running on port $MCP_HTTP_PORT"
        else
            warn "systemd service failed to start, starting manually..."
            qmd mcp --http --port "$MCP_HTTP_PORT" --daemon 2>/dev/null
            success "MCP HTTP daemon started on port $MCP_HTTP_PORT (manual mode)"
        fi
    else
        # Fallback: no systemd (e.g. WSL without systemd)
        info "systemd not available, starting daemon directly..."
        qmd mcp --http --port "$MCP_HTTP_PORT" --daemon 2>/dev/null
        success "MCP HTTP daemon started on port $MCP_HTTP_PORT"
    fi

    echo ""
    info "Connect from any MCP client using:"
    info "  URL: http://localhost:$MCP_HTTP_PORT"
    echo ""
    info "Claude Code config (~/.claude/settings.json or project .mcp.json):"
    echo ""
    echo "  {"
    echo "    \"mcpServers\": {"
    echo "      \"$MCP_SERVER_NAME\": {"
    echo "        \"url\": \"http://localhost:$MCP_HTTP_PORT/mcp\""
    echo "      }"
    echo "    }"
    echo "  }"
    echo ""
fi

# --- Section 10: Summary + next steps ---------------------------------------

header "Installation Complete"

echo ""
success "Vault created at: $VAULT_PATH"
success "Collections registered: ${ALL_COLLECTIONS[*]}"
$SETUP_RECALL && success "Recall skill: $SKILL_DIR/SKILL.md"
$SETUP_SYNC   && success "Session sync: $SYNC_SCRIPT"
$SETUP_SYNC   && success "Hooks config: $HOOKS_FILE"
$SETUP_MCP    && success "MCP stdio:  $CLAUDE_DESKTOP_CONFIG (server: $MCP_SERVER_NAME)"
$SETUP_MCP_HTTP && success "MCP HTTP:   http://localhost:$MCP_HTTP_PORT (server: $MCP_SERVER_NAME)"

echo ""
echo -e "${BOLD}Verify your setup:${NC}"
echo "  qmd collection list    # See registered collections"
echo "  qmd status             # Check index health"
echo "  qmd search \"test\"      # Test a search (once you have content)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Open $VAULT_PATH in Obsidian"
echo "  2. Start writing notes! Create a daily log from the template:"
echo "     cp $VAULT_PATH/daily/templates/daily-template.md $VAULT_PATH/daily/$(date +%Y-%m-%d).md"
echo "  3. After adding content, re-index: qmd embed"
$SETUP_RECALL && echo "  4. Try: /recall topic \"your search term\" in Claude Code"
echo ""
echo -e "${BOLD}Ensure ~/.bun/bin is in your PATH:${NC}"
echo "  echo 'export PATH=\"\$HOME/.bun/bin:\$PATH\"' >> ~/.bashrc"
echo ""
