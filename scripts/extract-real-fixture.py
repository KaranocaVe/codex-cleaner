#!/usr/bin/env python3
"""Read real Codex data; copy a small parent/children sample to a new test root.
Never mutates the source. Destination must not already exist.
The exported fixture contains private session data. Never publish or commit it.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def readonly(path):
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
    db.execute('PRAGMA query_only=ON')
    db.execute('BEGIN')
    return db


def extract(source, destination, parent_id=None):
    source = source.expanduser().resolve()
    destination = destination.expanduser().resolve()
    if destination.exists() or destination == source or source in destination.parents:
        raise ValueError('Destination must be new and outside the real Codex directory')
    state = readonly(source / 'state_5.sqlite')
    try:
        if parent_id is None:
            row = state.execute('''SELECT t.id FROM threads t
                JOIN thread_spawn_edges e ON e.parent_thread_id=t.id
                WHERE t.rollout_path <> '' GROUP BY t.id
                ORDER BY t.updated_at DESC LIMIT 1''').fetchone()
            if not row:
                raise ValueError('No parent session available')
            parent_id = row[0]
        children = [r[0] for r in state.execute('''SELECT child_thread_id FROM thread_spawn_edges
            WHERE parent_thread_id=? ORDER BY child_thread_id LIMIT 3''', (parent_id,))]
        survivor = state.execute('''SELECT id FROM threads WHERE id<>? AND id NOT IN
            (SELECT child_thread_id FROM thread_spawn_edges) ORDER BY updated_at DESC LIMIT 1''', (parent_id,)).fetchone()[0]
        ids = list(dict.fromkeys([parent_id, *children, survivor]))
        destination.mkdir(parents=True)
        databases = {}
        retained_database_rows = {}
        for filename in ['state_5.sqlite', 'thread_history_1.sqlite', 'logs_2.sqlite', 'goals_1.sqlite', 'queue_1.sqlite']:
            if not (source / filename).exists():
                continue
            src = state if filename == 'state_5.sqlite' else readonly(source / filename)
            dst = sqlite3.connect(destination / filename)
            counts = {}
            retained_counts = {}
            try:
                schema = src.execute("SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type='table' DESC").fetchall()
                for kind, name, sql in schema:
                    if kind == 'table':
                        dst.execute(sql)
                marks = ','.join('?' * len(ids))
                for kind, name, _ in schema:
                    if kind != 'table':
                        continue
                    columns = [r[1] for r in src.execute('PRAGMA table_info(' + quote(name) + ')')]
                    if filename == 'state_5.sqlite' and name == 'threads':
                        rows = src.execute('SELECT * FROM threads WHERE id IN (' + marks + ')', ids).fetchall()
                    elif filename == 'state_5.sqlite' and name in ['projects', 'project_roots', 'thread_sections']:
                        rows = src.execute('SELECT * FROM ' + quote(name)).fetchall()
                    elif name == 'thread_spawn_edges':
                        rows = src.execute('SELECT * FROM thread_spawn_edges WHERE parent_thread_id IN (' + marks + ') AND child_thread_id IN (' + marks + ')', ids + ids).fetchall()
                    elif 'thread_id' in columns:
                        rows = src.execute('SELECT * FROM ' + quote(name) + ' WHERE thread_id IN (' + marks + ')', ids).fetchall()
                    else:
                        rows = []
                    if rows:
                        dst.executemany('INSERT INTO ' + quote(name) + ' VALUES (' + ','.join('?' * len(columns)) + ')', rows)
                    counts[name] = len(rows)
                    # Keep the survivor's pre-cleanup cardinality for every
                    # table that is keyed by a thread ID (or the edge pair).
                    if name == 'threads':
                        retained_counts[name] = dst.execute(
                            'SELECT COUNT(*) FROM ' + quote(name) + ' WHERE id=?', (survivor,)
                        ).fetchone()[0]
                    elif name == 'thread_spawn_edges':
                        retained_counts[name] = dst.execute(
                            'SELECT COUNT(*) FROM ' + quote(name)
                            + ' WHERE parent_thread_id=? OR child_thread_id=?', (survivor, survivor)
                        ).fetchone()[0]
                    elif 'thread_id' in columns:
                        retained_counts[name] = dst.execute(
                            'SELECT COUNT(*) FROM ' + quote(name) + ' WHERE thread_id=?', (survivor,)
                        ).fetchone()[0]
                for kind, _, sql in schema:
                    if kind != 'table':
                        dst.execute(sql)
                dst.commit()
                databases[filename] = counts
                if retained_counts:
                    retained_database_rows[filename] = retained_counts
            finally:
                dst.close()
                if src is not state:
                    src.close()
        fixture_state = sqlite3.connect(destination / 'state_5.sqlite')
        try:
            for sid, raw, archived in fixture_state.execute('SELECT id,rollout_path,archived FROM threads').fetchall():
                path = Path(raw) if raw else None
                existing = path
                if path and not path.is_file() and path.suffix == '.jsonl' and Path(str(path) + '.zst').is_file():
                    existing = Path(str(path) + '.zst')
                extension = '.jsonl.zst' if existing and str(existing).endswith('.jsonl.zst') else '.jsonl'
                target = destination / ('archived_sessions' if archived else 'sessions') / (sid + extension)
                if existing and existing.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(existing, target)
                fixture_state.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(target), sid))
            fixture_state.commit()
        finally:
            fixture_state.close()
        manifest = {
            'parent_id': parent_id, 'children': children, 'survivor_id': survivor,
            'database_rows': databases, 'retained_database_rows': retained_database_rows,
        }
        (destination / 'fixture.json').write_text(json.dumps(manifest, indent=2))
        return {'sessions': len(ids), 'children': len(children), 'databases': len(databases), 'destination': str(destination)}
    except BaseException:
        if destination.exists():
            shutil.rmtree(destination)
        raise
    finally:
        state.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--source', type=Path, default=Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex'))
    parser.add_argument('--parent-id')
    args = parser.parse_args()
    print(json.dumps(extract(args.source, args.destination, args.parent_id)))
