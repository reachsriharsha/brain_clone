#!/bin/bash
# sync-claude-sessions.sh
# Converts Claude Code JSONL sessions (and their subagents) to markdown in your vault.
#
# Uses hash-based change detection: a note is rewritten only when its source
# files change, or when FORMAT_VERSION below changes. Safe to run repeatedly.
#
# Notes include tool inputs and outputs, so they can contain secrets that
# appeared in a session. Treat the sessions folder as sensitive.

# Load .env from script directory or repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for env_path in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../brain_clone/.env" "$HOME/.brain_clone.env"; do
    if [[ -f "$env_path" ]]; then
        # shellcheck disable=SC1090
        source "$env_path"
        break
    fi
done

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/projects}"
VAULT_SESSIONS="${VAULT_PATH:-$HOME/vault}/sessions"

mkdir -p "$VAULT_SESSIONS"

python3 - "$SESSIONS_DIR" "$VAULT_SESSIONS" <<'PY'
import glob, hashlib, json, os, re, sys

# Bump to force every note to be regenerated on the next run.
FORMAT_VERSION = 'v2'

# Attachment types that carry session content. Others are harness scaffolding
# (system prompts, tool listings, reminders, account IDs) and are skipped.
ATTACHMENTS = {
    'file', 'directory', 'nested_memory', 'edited_text_file',
    'compact_file_reference', 'invoked_skills', 'skill_mention',
    'task_status', 'hook_success', 'hook_non_blocking_error',
    'hook_additional_context', 'inlined_image_paths',
}

sessions_dir, vault = sys.argv[1], sys.argv[2]
hash_log = os.path.join(vault, '.sync-hashes')


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def read_entries(path):
    entries, seen = [], set()
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            if e.get('uuid'):
                # Drop replayed copies, keep entries whose payload differs.
                key = (e['uuid'], json.dumps(
                    [e.get('type'), e.get('message'), e.get('attachment'), e.get('content')],
                    sort_keys=True))
                if key in seen:
                    continue
                seen.add(key)
            entries.append(e)
    return entries


def fence(text, lang=''):
    runs = re.findall(r'`{3,}', text)
    ticks = '`' * max([3] + [len(r) + 1 for r in runs])
    return f'{ticks}{lang}\n{text}\n{ticks}'


def pretty(value):
    return json.dumps(value, indent=2, ensure_ascii=False)


def section(title, ts, body):
    stamp = f' ({ts[:19]})' if ts else ''
    return f'## {title}{stamp}\n\n{body.strip()}\n'


def full_output(text, session_id):
    """Replace a truncated tool result with the saved full output, if present."""
    if not text.startswith('<persisted-output>'):
        return text
    m = re.search(r'saved to: (.+?\.(?:txt|json))\s*$', text, re.M)
    if not m:
        return text
    path = os.path.realpath(m.group(1))
    root = os.path.realpath(sessions_dir) + os.sep
    # Only follow paths into this session's own tool-results folder.
    inside = path.startswith(root) and f'{os.sep}{session_id}{os.sep}tool-results{os.sep}' in path
    if not inside or not os.path.isfile(path):
        return text
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read()


def block_text(block, session_id):
    if isinstance(block, str):
        return full_output(block, session_id)
    kind = block.get('type')
    if kind == 'text':
        return full_output(block.get('text', ''), session_id)
    if kind in ('image', 'document'):
        media = (block.get('source') or {}).get('media_type', 'unknown')
        return f'[{kind} omitted: {media}]'
    if kind == 'tool_reference':
        return f"[tool reference: {block.get('tool_name', '')}]"
    return pretty(block)


def user_label(e, is_agent):
    origin = e.get('origin')
    kind = origin.get('kind') if isinstance(origin, dict) else None
    if e.get('isCompactSummary'):
        return 'Compaction summary'
    if kind and kind != 'human':
        return f'Message from {kind}'
    if e.get('isMeta'):
        return 'Injected context'
    return 'Agent input' if is_agent else 'User'


def render(entries, session_id, is_agent):
    out, tool_names = [], {}
    for e in entries:
        etype, ts = e.get('type'), e.get('timestamp', '')

        if etype in ('user', 'assistant'):
            content = (e.get('message') or {}).get('content') or []
            if isinstance(content, str):
                content = [{'type': 'text', 'text': content}]
            if etype == 'user':
                label = user_label(e, is_agent)
            else:
                label = 'API error' if e.get('isApiErrorMessage') else 'Assistant'
            texts = []

            def flush():
                body = '\n'.join(texts).strip()
                if body:
                    out.append(section(label, ts, body))
                texts.clear()

            for b in content:
                kind = b.get('type') if isinstance(b, dict) else None
                if kind == 'thinking':
                    flush()
                    if b.get('thinking', '').strip():
                        out.append(section('Thinking', ts, b['thinking']))
                elif kind == 'tool_use':
                    flush()
                    name = b.get('name', 'unknown')
                    tool_names[b.get('id')] = name
                    out.append(section(f'Tool call: {name}', ts, fence(pretty(b.get('input')), 'json')))
                elif kind == 'tool_result':
                    flush()
                    result = b.get('content') or ''
                    if not isinstance(result, list):
                        result = [result]
                    title = f"Tool result: {tool_names.get(b.get('tool_use_id'), 'unknown')}"
                    if e.get('toolDenialKind'):
                        title += f" [denied: {e['toolDenialKind']}]"
                    elif b.get('is_error'):
                        title += ' [error]'
                    body = '\n'.join(block_text(x, session_id) for x in result)
                    if e.get('userFeedback'):
                        body += f"\n\nUser feedback: {e['userFeedback']}"
                    out.append(section(title, ts, fence(body)))
                else:
                    texts.append(block_text(b, session_id))
            flush()

        elif etype == 'attachment':
            a = e.get('attachment') or {}
            kind = a.get('type')
            if kind == 'queued_command':
                # Messages sent while Claude was busy exist only here.
                origin = (a.get('origin') or {}).get('kind') or a.get('commandMode')
                label = 'User (queued)' if origin == 'human' else f"Queued message from {origin or 'unknown'}"
                prompt = a.get('prompt') or ''
                if not isinstance(prompt, str):
                    prompt = '\n'.join(block_text(x, session_id) for x in prompt)
                out.append(section(label, ts, prompt))
            elif kind in ATTACHMENTS:
                data = {k: v for k, v in a.items() if k != 'type'}
                out.append(section(f'Attachment: {kind}', ts, fence(pretty(data), 'json')))

        elif etype == 'system':
            parts = [str(e[k]) for k in ('content', 'error') if e.get(k)]
            if parts:
                out.append(section(f"System: {e.get('subtype', 'message')}", ts, fence('\n'.join(parts))))
    return out


def unique(values):
    return list(dict.fromkeys(v for v in values if v))


def metadata(entries, session_id, session_folder, agent_meta, agent_id):
    def last(etype, field):
        found = [e[field] for e in entries if e.get('type') == etype and e.get(field)]
        return found[-1] if found else None

    # cwd and branch in the order seen; the final value is the current one.
    cwds, branches = [], []
    for e in entries:
        cwd = e.get('relocatedCwd') if e.get('type') == 'relocated' else e.get('cwd')
        if cwd:
            cwds.append(cwd)
        if e.get('gitBranch'):
            branches.append(e['gitBranch'])

    # One API message spans several entries; count its usage once.
    usage, models = {}, []
    for e in entries:
        if e.get('type') != 'assistant':
            continue
        msg = e.get('message') or {}
        if msg.get('model') != '<synthetic>':
            models.append(msg.get('model'))
        if msg.get('usage'):
            usage[msg.get('id') or e.get('uuid')] = msg['usage']

    meta = {'type': 'subagent' if agent_id else 'session', 'session_id': session_id}
    if agent_id:
        meta.update({
            'agent_id': agent_id,
            'agent_type': agent_meta.get('agentType'),
            'agent_description': agent_meta.get('description'),
            'parent_agent_id': agent_meta.get('parentAgentId'),
            'parent_tool_use_id': agent_meta.get('toolUseId'),
            'spawn_depth': agent_meta.get('spawnDepth'),
        })
        meta['title'] = agent_meta.get('description')
    else:
        meta['title'] = (
            last('custom-title', 'customTitle')
            or read_json(os.path.join(session_folder, 'custom-title.json')).get('customTitle')
            or last('ai-title', 'aiTitle'))

    meta['project'] = cwds[-1] if cwds else None
    meta['projects'] = unique(cwds)
    meta['branch'] = branches[-1] if branches else None
    meta['branches'] = unique(branches)
    meta['version'] = ([e['version'] for e in entries if e.get('version')] or [None])[-1]
    meta['models'] = unique(models)

    stamps = [e['timestamp'] for e in entries
              if e.get('type') in ('user', 'assistant') and e.get('timestamp')]
    if stamps:
        meta['started'], meta['ended'] = min(stamps), max(stamps)

    for key in ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'):
        total = sum(u.get(key) or 0 for u in usage.values())
        if total:
            meta[key] = total

    cost = last('cost-state', 'totalCostUSD')
    if cost is not None:
        meta['cost_usd'] = round(cost, 4)

    prs = {e['prUrl']: e for e in entries if e.get('type') == 'pr-link' and e.get('prUrl')}
    meta['pull_requests'] = list(prs)
    meta['pr_repositories'] = unique(e.get('prRepository') for e in prs.values())
    meta['pr_numbers'] = [e['prNumber'] for e in prs.values() if e.get('prNumber')]
    return {k: v for k, v in meta.items() if v not in (None, '', [])}


def source_hash(paths):
    h = hashlib.md5()
    for p in paths:
        if os.path.isfile(p):
            with open(p, 'rb') as f:
                h.update(f.read())
    return f'{FORMAT_VERSION}-{h.hexdigest()}'


def write_atomic(path, text):
    tmp = f'{path}.{os.getpid()}.tmp'
    with open(tmp, 'w', encoding='utf-8', errors='replace') as f:
        f.write(text)
    os.replace(tmp, path)


def sync(path, hashes):
    parts = os.path.relpath(path, sessions_dir).split(os.sep)
    stem = os.path.basename(path)[:-len('.jsonl')]
    is_agent = len(parts) > 2
    if is_agent:
        # <project>/<session>/subagents/.../agent-<id>.jsonl
        session_id, agent_id = parts[1], stem[len('agent-'):]
        session_folder = os.path.join(sessions_dir, parts[0], session_id)
        side_files = [path[:-len('.jsonl')] + '.meta.json']
    else:
        session_id, agent_id = stem, None
        session_folder = path[:-len('.jsonl')]
        side_files = [os.path.join(session_folder, 'custom-title.json')]

    key = '/'.join(parts)
    current = source_hash([path] + side_files)
    if hashes.get(key) == current:
        return

    entries = read_entries(path)
    sections = render(entries, session_id, is_agent)
    if not sections:
        hashes[key] = current
        return

    agent_meta = read_json(side_files[0]) if is_agent else {}
    meta = metadata(entries, session_id, session_folder, agent_meta, agent_id)

    short = session_id[:8]
    suffix = f'{short}-agent-{agent_id}' if is_agent else short
    if meta.get('started'):
        stamp = meta['started'][:16].replace('T', '-').replace(':', '-')
    else:
        from datetime import datetime
        stamp = datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d-%H-%M')
    name = f'session-{stamp}-{suffix}.md'

    # JSON values are valid YAML, which keeps titles and paths safely quoted.
    front = '\n'.join(f'{k}: {json.dumps(v, ensure_ascii=False)}' for k, v in meta.items())
    if is_agent:
        front += f'\nparent_session: "{short}"'
    write_atomic(os.path.join(vault, name), f'---\n{front}\n---\n\n' + '\n---\n\n'.join(sections))

    # Remove an older note for the same source under a different name.
    for old in glob.glob(os.path.join(glob.escape(vault), f'session-*-{suffix}.md')):
        if os.path.basename(old) != name:
            os.remove(old)
    hashes[key] = current


hashes = {}
if os.path.isfile(hash_log):
    with open(hash_log, encoding='utf-8') as f:
        hashes = dict(line.rstrip('\n').rsplit(':', 1) for line in f if ':' in line)

root = glob.escape(sessions_dir)
sources = glob.glob(os.path.join(root, '*', '*.jsonl'))
sources += glob.glob(os.path.join(root, '*', '*', 'subagents', '**', 'agent-*.jsonl'), recursive=True)

failed = 0
for source in sorted(sources):
    try:
        sync(source, hashes)
    except Exception as exc:  # one bad session must not stop the rest
        failed += 1
        print(f'sync failed: {source}: {type(exc).__name__}: {exc}', file=sys.stderr)

write_atomic(hash_log, ''.join(f'{k}:{v}\n' for k, v in hashes.items()))
if failed:
    print(f'{failed} session file(s) failed to sync', file=sys.stderr)
PY

# Re-index QMD sessions collection
qmd update 2>/dev/null || true
