#!/usr/bin/env python3
"""Verify a GUI cleanup against extract-real-fixture.py's disposable sample."""
import argparse
import json
from pathlib import Path
import sqlite3


def verify(root):
    root = root.resolve()
    metadata = json.loads((root / 'fixture.json').read_text())
    removed = [metadata['parent_id'], *metadata['children']]
    marks = ','.join('?' * len(removed))
    survivor = metadata['survivor_id']
    backup_root = root / 'codex-cleaner-backups'
    assert not backup_root.exists(), 'Database backup directory must not exist'
    trash_root = root / 'Trash' / 'CodexCleaner'
    batches = [path for path in trash_root.iterdir() if path.is_dir()] if trash_root.is_dir() else []
    assert len(batches) == 1, 'Expected exactly one cleanup Trash batch'
    batch = batches[0]
    manifest_path = batch / 'manifest.json'
    assert manifest_path.is_file(), 'Cleanup manifest is missing'
    assert not any(path.is_file() and path.suffix == '.sqlite' for path in trash_root.rglob('*')), \
        'Trash must not contain SQLite database copies'
    manifest = json.loads(manifest_path.read_text())
    assert set(manifest['sessionIDs']) == set(removed)
    report = {}
    assert 'retained_database_rows' in metadata, 'Fixture lacks survivor row baselines'
    retained_metadata = metadata['retained_database_rows']
    associated_tables = 0
    for filename, original_counts in metadata['database_rows'].items():
        db = sqlite3.connect((root / filename).as_uri() + '?mode=ro', uri=True)
        try:
            assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
            verified = 0
            retained_verified = 0
            for table in retained_metadata.get(filename, {}):
                q = '"' + table.replace('"', '""') + '"'
                columns = [r[1] for r in db.execute('PRAGMA table_info(' + q + ')')]
                if table == 'threads':
                    assert db.execute('SELECT COUNT(*) FROM threads WHERE id IN (' + marks + ')', removed).fetchone()[0] == 0
                    assert db.execute('SELECT COUNT(*) FROM threads WHERE id=?', (survivor,)).fetchone()[0] == 1
                    retained = db.execute('SELECT rollout_path FROM threads WHERE id=?', (survivor,)).fetchone()[0]
                    assert Path(retained).is_file()
                elif table == 'thread_spawn_edges':
                    assert db.execute('SELECT COUNT(*) FROM ' + q + ' WHERE parent_thread_id IN (' + marks + ') OR child_thread_id IN (' + marks + ')', removed + removed).fetchone()[0] == 0
                elif 'thread_id' in columns:
                    assert db.execute('SELECT COUNT(*) FROM ' + q + ' WHERE thread_id IN (' + marks + ')', removed).fetchone()[0] == 0
                expected = retained_metadata[filename][table]
                if table == 'thread_spawn_edges':
                    actual = db.execute('SELECT COUNT(*) FROM ' + q + ' WHERE parent_thread_id=? OR child_thread_id=?', (survivor, survivor)).fetchone()[0]
                elif table == 'threads':
                    actual = db.execute('SELECT COUNT(*) FROM ' + q + ' WHERE id=?', (survivor,)).fetchone()[0]
                else:
                    actual = db.execute('SELECT COUNT(*) FROM ' + q + ' WHERE thread_id=?', (survivor,)).fetchone()[0]
                assert actual == expected, f'Survivor row count changed in {filename}:{table}'
                verified += 1
                retained_verified += 1
            associated_tables += verified
            report[filename] = {'integrity': 'ok', 'verified_thread_tables': verified, 'retained_rows_verified': retained_verified}
        finally:
            db.close()
    for file in manifest['files']:
        assert not Path(file['source']).exists()
        assert Path(file['destination']).is_file()
    assert associated_tables == 15, f'Expected 15 associated tables, got {associated_tables}'
    return {
        'database_backups_created': False,
        'counts': {'removed_sessions': len(removed), 'retained_sessions': 1,
                   'recovered_files': len(manifest['files']), 'databases': len(report),
                   'associated_tables': associated_tables},
        'removed_sessions': len(removed), 'retained_sessions': 1,
        'recovered_files': len(manifest['files']), 'databases': report,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.root), indent=2))
