"""Offline structural checks. Does not replace flutter analyze/test or builds."""
from pathlib import Path
import json
import re
import sqlite3
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def verify_sql():
    source = (ROOT / 'lib/services/app_database.dart').read_text(encoding='utf8')
    db = sqlite3.connect(':memory:')
    db.execute('PRAGMA foreign_keys = ON')
    for statement in re.findall(r"db.execute\('(CREATE TABLE [^']+)'\)", source):
        if '$table' not in statement:
            db.execute(statement)
        else:
            tables = ['downloaded_tracks', 'recently_played'] if 'track_id' in statement else ['settings', 'session', 'playback_state']
            for table in tables:
                db.execute(statement.replace('$table', table))
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert tables == {'tracks', 'playlists', 'playlist_tracks', 'downloaded_tracks', 'recently_played', 'downloads', 'search_history', 'lyrics', 'settings', 'session', 'playback_state', 'playback_queue'}, tables
    # Parse every literal raw query used by the repository against this schema.
    for file in ['app_database.dart', 'database_service.dart']:
        text = (ROOT / 'lib/services' / file).read_text(encoding='utf8')
        for sql in re.findall(r"raw(?:Query|Delete)\('([^']+)'", text):
            sql = sql.replace('$table', 'recently_played')
            db.execute('EXPLAIN ' + sql, [None] * sql.count('?')).fetchall()
    with db:
        for key in ['BV_p1', 'BV_p2']:
            db.execute('INSERT INTO tracks VALUES (?, ?)', (key, json.dumps({'id': key})))
        db.execute('INSERT INTO playlists VALUES (?, ?, ?)', ('favorites', 0, '{}'))
        for index, key in enumerate(['BV_p2', 'BV_p1']):
            db.execute('INSERT INTO playlist_tracks VALUES (?, ?, ?)', ('favorites', key, index))
        for quality in [30280, 30232]:
            db.execute('INSERT INTO downloads VALUES (?, ?, ?, ?)', ('BV_p1', quality, f'audio_{quality}.m4a', 1024))
        db.execute('INSERT INTO playback_queue VALUES (?, ?, ?)', ('queue', 0, 'BV_p1'))
        db.execute('INSERT INTO playback_queue VALUES (?, ?, ?)', ('queue', 1, 'BV_p1'))
    assert [r[0] for r in db.execute('SELECT track_id FROM playlist_tracks ORDER BY position')] == ['BV_p2', 'BV_p1']
    assert db.execute('SELECT COUNT(*) FROM downloads').fetchone()[0] == 2
    assert db.execute('SELECT COUNT(*) FROM playback_queue').fetchone()[0] == 2
    # A late session failure must roll back the library edits in the transaction.
    db.execute("CREATE TRIGGER fail_session BEFORE INSERT ON session BEGIN SELECT RAISE(ABORT, 'failure'); END")
    try:
        with db:
            db.execute('DELETE FROM playlists')
            db.execute('INSERT INTO session VALUES (1, ?)', ('{}',))
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError('injected failure did not fire')
    assert db.execute('SELECT COUNT(*) FROM playlist_tracks').fetchone()[0] == 2
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    db.close()
    print('PASS: 12 SQLite tables, raw SQL syntax, ordered relations, multi-quality keys, duplicate queue entries, rollback and foreign keys')


def verify_platforms():
    assets = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    images = json.loads((assets / 'Contents.json').read_text())['images']
    assert len(images) == 2
    assert images[0]['filename'] == images[1]['filename']
    assert images[1]['appearances'] == [{'appearance': 'luminosity', 'value': 'dark'}]
    png = (assets / images[0]['filename']).read_bytes()
    assert struct.unpack('>II', png[16:24]) == (1024, 1024)
    assert len(list(assets.glob('*.png'))) == 1
    resources = ROOT / 'android/app/src/main/res'
    assert len(list(resources.glob('mipmap-*/ic_launcher.png'))) == 5
    assert not list(resources.glob('mipmap-*/ic_launcher_round.png'))
    manifest = ET.parse(ROOT / 'android/app/src/main/AndroidManifest.xml').getroot()
    android = '{http://schemas.android.com/apk/res/android}'
    app = manifest.find('application')
    assert app.get(android + 'label') == 'BiliMusic'
    assert app.find('activity').get(android + 'name') == 'com.bilimusic.player.MainActivity'
    gradle = (ROOT / 'android/app/build.gradle').read_text(encoding='utf8')
    assert 'namespace = "com.bilimusic.player"' in gradle
    assert 'applicationId = "com.bilimusic.player"' in gradle
    xcode = (ROOT / 'ios/Runner.xcodeproj/project.pbxproj').read_text()
    ids = re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', xcode)
    assert ids.count('com.bilimusic.player') == 3
    assert ids.count('com.bilimusic.player.RunnerTests') == 3
    activity = ROOT / 'android/app/src/main/kotlin/com/bilimusic/player/MainActivity.kt'
    assert activity.read_text().startswith('package com.bilimusic.player')
    for file in (ROOT / 'lib').rglob('*.dart'):
        text = file.read_text(encoding='utf8')
        assert 'package:bilibeat/' not in text, file
        assert not re.search(r'bili(?:beat|music)_\w+\.json', text), file
        assert '_readyPath' not in text and '_metaPath' not in text, file
    print('PASS: Android/iOS identifiers, icon entries and dimensions, no legacy persistence paths')


if __name__ == '__main__':
    verify_sql()
    verify_platforms()
