import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

abstract class DocumentStore {
  Future<List<Map<String, dynamic>>> all(String kind);
  Future<void> put(String kind, String id, Map<String, dynamic> value);
  Future<void> remove(String kind, String id);
  Future<void> clear(Set<String> kinds);
  Future<void> close();
}

/// Used only by tests/capture harnesses; production always opens SQLCipher.
class MemoryDocumentStore implements DocumentStore {
  final Map<String, Map<String, Map<String, dynamic>>> _data = {};
  @override
  Future<List<Map<String, dynamic>>> all(String kind) async =>
      (_data[kind]?.values ?? [])
          .map((v) => Map<String, dynamic>.from(jsonDecode(jsonEncode(v))))
          .toList();
  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    (_data[kind] ??= {})[id] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)),
    );
  }

  @override
  Future<void> remove(String kind, String id) async {
    _data[kind]?.remove(id);
  }

  @override
  Future<void> clear(Set<String> kinds) async {
    for (final k in kinds) {
      _data.remove(k);
    }
  }

  @override
  Future<void> close() async {}
}

class EncryptedDocumentStore implements DocumentStore {
  final Database db;
  EncryptedDocumentStore._(this.db);
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static Future<EncryptedDocumentStore>? _opening;
  static Future<EncryptedDocumentStore> open() =>
      _opening ??= _open().catchError((Object e) {
        _opening = null;
        final code = e is PlatformException ? e.code : e.runtimeType.toString();
        debugPrint('Private store initialization failed [$code]');
        throw e;
      });
  static Future<EncryptedDocumentStore> _open() async {
    final directory = await getApplicationSupportDirectory();
    final path = '${directory.path}/private-records.db';
    var key = await _secure.read(key: 'records.database.key.v1');
    if (key == null) {
      if (await File(path).exists()) {
        throw StateError(
          'The secure key is unavailable, so existing data was left untouched. Unlock the device and try again.',
        );
      }
      final random = Random.secure();
      key = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
      await _secure.write(key: 'records.database.key.v1', value: key);
    }
    final db = await openDatabase(
      path,
      password: key,
      version: 1,
      onCreate: (db, _) async => db.execute(
        'CREATE TABLE documents (kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(kind,id))',
      ),
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA secure_delete=ON');
      },
    );
    return EncryptedDocumentStore._(db);
  }

  @override
  Future<List<Map<String, dynamic>>> all(String kind) async {
    final rows = await db.query(
      'documents',
      columns: ['data'],
      where: 'kind = ?',
      whereArgs: [kind],
    );
    // Invalid stored data is an explicit error, never silently discarded.
    return rows
        .map((r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)))
        .toList();
  }

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    await db.insert('documents', {
      'kind': kind,
      'id': id,
      'data': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String kind, String id) async {
    await db.delete(
      'documents',
      where: 'kind = ? AND id = ?',
      whereArgs: [kind, id],
    );
  }

  @override
  Future<void> clear(Set<String> kinds) async {
    await db.transaction((tx) async {
      for (final k in kinds) {
        await tx.delete('documents', where: 'kind = ?', whereArgs: [k]);
      }
    });
    // The transaction above is authoritative; compaction cannot undo a committed deletion.
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await db.execute('VACUUM');
    } catch (_) {
      /* secure_delete remains enabled; compact on a later maintenance pass. */
    }
  }

  @override
  Future<void> close() async {
    await db.close();
    _opening = null;
  }
}

String newRecordId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
String calendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
