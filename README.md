# brain_clone

A second brain system built on [QMD](https://github.com/tobi/qmd) + Obsidian, designed for developers using Claude Code.

Automatically indexes your vault, syncs Claude Code sessions, and gives you `/recall` to search everything from the CLI.

## Quick Start

```bash
# 1. Clone and configure
git clone <repo-url> && cd brain_clone
cp .env.example .env
# Edit .env — set VAULT_PATH to your Obsidian vault location

# 2. Run the installer
chmod +x install.sh
./install.sh
```

The installer will:
- Install Node.js 22+, Bun, and QMD (if missing)
- Create vault folder structure with templates
- Register QMD collections and build the index
- Optionally set up `/recall` skill, session sync, and MCP server

## Configuration

Copy `.env.example` to `.env` and set your values:

```bash
VAULT_PATH="/home/you/your-vault"    # Obsidian vault root
CLAUDE_SESSIONS_DIR="$HOME/.claude/projects"
MCP_SERVER_NAME="qmd"
MCP_HTTP_PORT=8181
```

## /recall Skill

Use `/recall` in Claude Code to search your vault.

```
/recall yesterday              # What happened on a date
/recall topic kubernetes       # Search all collections for a topic
/recall deep "API design"      # Semantic search (requires embeddings)
/recall read qmd://daily/2026-03-05.md   # Read a full document
/recall list sessions          # Browse files in a collection
/recall status                 # Check vault health
```

### Modes

| Mode | Usage | What it does |
|------|-------|-------------|
| Temporal | `/recall yesterday` | Search sessions + daily by date |
| Topic | `/recall <query>` | BM25 keyword search across all collections |
| Deep | `/recall deep <query>` | Hybrid semantic search with reranking |
| Read | `/recall read <path>` | Get full document content |
| List | `/recall list <collection>` | Browse files in a collection |
| Status | `/recall status` | Index health and collection counts |

## QMD Commands

### Indexing

```bash
# Re-index all collections (after adding/editing files)
qmd update

# Build embeddings for semantic search (slow on CPU)
qmd embed

# Force rebuild all embeddings
qmd embed -f

# Clean up orphaned data
qmd cleanup
```

### Searching

```bash
# Keyword search (BM25) — fast, no embeddings needed
qmd search "your query"
qmd search "your query" -c sessions -n 10

# Semantic search (requires qmd embed first)
qmd query "your query"

# Vector similarity search
qmd vsearch "your query"
```

### Browsing

```bash
# List all collections
qmd ls

# List files in a collection
qmd ls daily
qmd ls sessions

# Read a document
qmd get qmd://daily/2026-03-05.md
qmd get qmd://sessions/session-2026-03-05-05-32-f1fb7d13.md

# Read a section (from line 50, 30 lines)
qmd get qmd://notes/architecture.md:50 -l 30

# Get multiple docs by glob
qmd multi-get "sessions/session-2026-03*"
```

### Search Output Flags

```bash
qmd search "query" --full        # Full documents instead of snippets
qmd search "query" --json        # JSON output
qmd search "query" --md          # Markdown output
qmd search "query" -n 20         # More results
qmd search "query" --min-score 0.5  # Filter by relevance
qmd search "query" --files       # File paths only
```

## Session Sync

Claude Code sessions are automatically synced to your vault on exit (via Stop hook).

```bash
# Manual sync
~/.local/bin/sync-claude-sessions.sh

# Check what's been synced
ls ~/your-vault/sessions/
```

The sync script:
- Converts JSONL session files to readable markdown
- Uses hash-based change detection (re-syncs if session content grew)
- Adds frontmatter with project, branch, and session ID
- Skips subagent files

## MCP Server

QMD can run as an MCP server, accessible from VS Code, Cursor, Claude Desktop, or scripts.

```bash
# Start HTTP daemon (recommended for multi-client)
qmd mcp --http --daemon --port 8181

# Or stdio mode (per-client)
qmd mcp
```

Connect from any MCP client:
```json
{
  "mcpServers": {
    "qmd": {
      "url": "http://localhost:8181/mcp"
    }
  }
}
```

## Vault Structure

```
your-vault/
  daily/           # Daily journal, standup, blockers
  notes/           # Project notes, architecture decisions
  sessions/        # Auto-synced Claude Code sessions
  transcripts/     # Meeting transcripts, voice memos
  skills/          # Claude Code skill definitions
  thoughts/        # Quick captures, ideas
  people/          # People profiles, relationship notes
  references/      # Bookmarks, articles, resources
  weekly-reviews/  # Weekly reviews, reflections
```

## Re-running the Installer

Running `./install.sh` again is safe. It will:
- Detect the previous installation and warn you
- Ask before overwriting generated files (sync script, skill, hooks, systemd service)
- Never touch your vault content (notes, daily logs, etc.)
- Update configs to pick up new `.env` values  