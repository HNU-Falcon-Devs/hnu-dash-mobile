import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'secure_value_store.dart';

enum ScanStatus { pending, accepted, rejected, duplicate, blocked, legacy }

class ScanRecord {
  const ScanRecord({
    required this.scanId,
    required this.eventId,
    required this.checkpointId,
    required this.studentId,
    required this.staffUserId,
    required this.status,
    this.receivedAt,
    this.replayed,
    this.legacy = false,
    this.legacyStatus,
  });

  final String scanId;
  final String eventId;
  final String? checkpointId;
  final String studentId;
  final String? staffUserId;
  final ScanStatus status;
  final String? receivedAt;
  final bool? replayed;
  final bool legacy;
  final String? legacyStatus;

  factory ScanRecord.fromRow(Row row) => ScanRecord(
    scanId: row['scan_id'] as String,
    eventId: row['event_id'] as String,
    checkpointId: row['checkpoint_id'] as String?,
    studentId: row['student_id'] as String,
    staffUserId: row['staff_user_id'] as String?,
    status: ScanStatus.values.byName(row['submission_status'] as String),
    receivedAt: row['received_at'] as String?,
    replayed: row['replayed'] == null ? null : (row['replayed'] as int) == 1,
    legacy: (row['legacy'] as int) == 1,
    legacyStatus: row['legacy_status'] as String?,
  );
}

/// SQLCipher-backed local evidence store. Each open handle is bound to one
/// authenticated Staff UUID; every read and mutation is scoped to that owner.
class SecureAttendanceStore {
  SecureAttendanceStore._(this._database, this.staffUserId);

  static const databaseFileName = 'hnu_dash_scans_encrypted.db';
  static const legacyDatabaseFileName = 'hnu_dash_scans.db';
  static const encryptionKeyName = 'hnu_dash_scan_database_key_v1';
  static const tableName = 'attendance_scans';
  static final _studentIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  final Database _database;
  final String staffUserId;
  bool _closed = false;

  static Future<SecureAttendanceStore> openOnDevice({
    required String staffUserId,
    SecureValueStore? keyStore,
  }) async {
    final directory = await getDatabasesPath();
    return open(
      databasePath: path.join(directory, databaseFileName),
      legacyDatabasePath: path.join(directory, legacyDatabaseFileName),
      staffUserId: staffUserId,
      keyStore: keyStore ?? FlutterSecureValueStore(),
    );
  }

  @visibleForTesting
  static Future<SecureAttendanceStore> open({
    required String databasePath,
    required String legacyDatabasePath,
    required String staffUserId,
    required SecureValueStore keyStore,
  }) async {
    if (staffUserId.isEmpty) {
      throw ArgumentError('An authenticated Staff account is required.');
    }

    final databaseFile = File(databasePath);
    final legacyFile = File(legacyDatabasePath);
    final key = await _loadOrCreateKey(databaseFile, keyStore);
    final database = sqlite3.open(databasePath);

    try {
      database.execute("PRAGMA key = \"x'$key'\";");
      final cipherVersion = database.select('PRAGMA cipher_version;');
      if (cipherVersion.isEmpty || cipherVersion.first.values.first == null) {
        throw StateError('The encrypted SQLite build is unavailable.');
      }
      database.select('SELECT count(*) FROM sqlite_master;');
      database.execute('PRAGMA cipher_memory_security = ON;');
      _createSchema(database);

      final store = SecureAttendanceStore._(database, staffUserId);
      await store._migrateLegacy(legacyFile);
      return store;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static Future<String> _loadOrCreateKey(
    File databaseFile,
    SecureValueStore keyStore,
  ) async {
    final existing = await keyStore.read(encryptionKeyName);
    if (existing != null) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(existing)) {
        throw StateError('The stored database encryption key is invalid.');
      }
      return existing;
    }

    if (await databaseFile.exists()) {
      throw StateError(
        'The encrypted attendance database exists but its key is unavailable.',
      );
    }

    final random = Random.secure();
    final generated = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await keyStore.write(encryptionKeyName, generated);
    if (await keyStore.read(encryptionKeyName) != generated) {
      throw StateError('The database encryption key could not be verified.');
    }
    return generated;
  }

  static void _createSchema(Database database) {
    database.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        scan_id TEXT PRIMARY KEY,
        event_id TEXT NOT NULL,
        checkpoint_id TEXT,
        student_id TEXT NOT NULL,
        staff_user_id TEXT,
        submission_status TEXT NOT NULL
          CHECK (submission_status IN (
            'pending', 'accepted', 'rejected', 'duplicate', 'blocked', 'legacy'
          )),
        received_at TEXT,
        replayed INTEGER CHECK (replayed IN (0, 1)),
        legacy INTEGER NOT NULL DEFAULT 0 CHECK (legacy IN (0, 1)),
        legacy_status TEXT,
        CHECK (
          (legacy = 1 AND staff_user_id IS NULL AND checkpoint_id IS NULL
            AND submission_status = 'legacy')
          OR
          (legacy = 0 AND staff_user_id IS NOT NULL AND checkpoint_id IS NOT NULL
            AND submission_status != 'legacy')
        )
      );
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS attendance_scans_staff_status
      ON $tableName(staff_user_id, submission_status, legacy);
    ''');
    database.execute('PRAGMA user_version = 1;');
  }

  Future<void> _migrateLegacy(File legacyFile) async {
    _ensureOpen();
    final sidecars = [
      File('${legacyFile.path}-wal'),
      File('${legacyFile.path}-shm'),
      File('${legacyFile.path}-journal'),
    ];
    final hasLegacy = await legacyFile.exists();
    if (!hasLegacy) {
      for (final sidecar in sidecars) {
        if (await sidecar.exists()) {
          throw StateError(
            'An incomplete legacy attendance database requires recovery.',
          );
        }
      }
      return;
    }

    final legacyDatabase = sqlite3.open(legacyFile.path);
    late final List<Map<String, Object?>> rows;
    try {
      final table = legacyDatabase.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
        ['provisional_scans'],
      );
      if (table.isEmpty) {
        throw StateError(
          'The legacy attendance database has an unknown schema.',
        );
      }
      rows = legacyDatabase
          .select('''
        SELECT id, event_id, credential_value, status
        FROM provisional_scans
        ORDER BY rowid ASC;
      ''')
          .map(
            (row) => <String, Object?>{
              'id': row['id'],
              'event_id': row['event_id'],
              'credential_value': row['credential_value'],
              'status': row['status'],
            },
          )
          .toList();
    } finally {
      legacyDatabase.close();
    }

    _database.execute('BEGIN IMMEDIATE;');
    try {
      for (final row in rows) {
        final scanId = row['id'];
        final eventId = row['event_id'];
        final studentId = row['credential_value'];
        final oldStatus = row['status'];
        if (scanId is! String ||
            eventId is! String ||
            studentId is! String ||
            oldStatus is! String) {
          throw StateError('A legacy attendance record is malformed.');
        }

        final existing = _database.select(
          'SELECT event_id, student_id, legacy_status, legacy '
          'FROM $tableName WHERE scan_id = ?;',
          [scanId],
        );
        if (existing.isNotEmpty) {
          final saved = existing.single;
          if (saved['event_id'] != eventId ||
              saved['student_id'] != studentId ||
              saved['legacy_status'] != oldStatus ||
              saved['legacy'] != 1) {
            throw StateError(
              'A legacy attendance record conflicts with encrypted data.',
            );
          }
          continue;
        }

        _database.execute(
          '''
          INSERT INTO $tableName (
            scan_id, event_id, checkpoint_id, student_id, staff_user_id,
            submission_status, received_at, replayed, legacy, legacy_status
          ) VALUES (?, ?, NULL, ?, NULL, 'legacy', NULL, NULL, 1, ?);
        ''',
          [scanId, eventId, studentId, oldStatus],
        );
      }
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }

    for (final row in rows) {
      final scanId = row['id'] as String;
      final verified = _database.select(
        'SELECT event_id, student_id, legacy_status, legacy, staff_user_id, '
        'checkpoint_id, submission_status FROM $tableName WHERE scan_id = ?;',
        [scanId],
      );
      if (verified.length != 1 ||
          verified.single['event_id'] != row['event_id'] ||
          verified.single['student_id'] != row['credential_value'] ||
          verified.single['legacy_status'] != row['status'] ||
          verified.single['legacy'] != 1 ||
          verified.single['staff_user_id'] != null ||
          verified.single['checkpoint_id'] != null ||
          verified.single['submission_status'] != 'legacy') {
        throw StateError('Legacy attendance migration could not be verified.');
      }
    }

    for (final sidecar in sidecars) {
      if (await sidecar.exists()) await sidecar.delete();
    }
    await legacyFile.delete();
    if (await legacyFile.exists()) {
      throw StateError('The plaintext legacy database could not be removed.');
    }
    for (final sidecar in sidecars) {
      if (await sidecar.exists()) {
        throw StateError(
          'A plaintext legacy database sidecar could not be removed.',
        );
      }
    }
  }

  Future<ScanRecord> createPending({
    required String eventId,
    required String checkpointId,
    required String studentId,
  }) async {
    _ensureOpen();
    if (eventId.isEmpty ||
        checkpointId.isEmpty ||
        !_studentIdPattern.hasMatch(studentId)) {
      throw ArgumentError('The event, checkpoint, or Student ID is invalid.');
    }

    final record = ScanRecord(
      scanId: const Uuid().v4(),
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: studentId,
      staffUserId: staffUserId,
      status: ScanStatus.pending,
    );
    _database.execute(
      '''
      INSERT INTO $tableName (
        scan_id, event_id, checkpoint_id, student_id, staff_user_id,
        submission_status, received_at, replayed, legacy, legacy_status
      ) VALUES (?, ?, ?, ?, ?, 'pending', NULL, NULL, 0, NULL);
    ''',
      [
        record.scanId,
        record.eventId,
        record.checkpointId,
        record.studentId,
        staffUserId,
      ],
    );
    return record;
  }

  Future<List<ScanRecord>> readRecent({int limit = 10}) async {
    _ensureOpen();
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit');
    }
    return _database
        .select(
          '''
      SELECT * FROM $tableName
      WHERE staff_user_id = ? AND legacy = 0
      ORDER BY CASE WHEN submission_status IN ('pending', 'blocked') THEN 0 ELSE 1 END, rowid DESC LIMIT ?;
    ''',
          [staffUserId, limit],
        )
        .map(ScanRecord.fromRow)
        .toList();
  }

  Future<List<ScanRecord>> readPending() async {
    _ensureOpen();
    return _database
        .select(
          '''
      SELECT * FROM $tableName
      WHERE staff_user_id = ? AND submission_status = 'pending' AND legacy = 0
      ORDER BY rowid ASC;
    ''',
          [staffUserId],
        )
        .map(ScanRecord.fromRow)
        .toList();
  }

  Future<bool> hasUnresolvedRecords() async {
    _ensureOpen();
    final rows = _database.select(
      '''
      SELECT count(*) AS total FROM $tableName
      WHERE staff_user_id = ? AND submission_status IN ('pending', 'blocked')
        AND legacy = 0;
    ''',
      [staffUserId],
    );
    return (rows.single['total'] as int) > 0;
  }

  Future<ScanRecord?> findPending(String scanId) async {
    _ensureOpen();
    final rows = _database.select(
      '''
      SELECT * FROM $tableName
      WHERE scan_id = ? AND staff_user_id = ?
        AND submission_status = 'pending' AND legacy = 0;
    ''',
      [scanId, staffUserId],
    );
    return rows.isEmpty ? null : ScanRecord.fromRow(rows.single);
  }

  Future<void> recordReceipt({
    required String scanId,
    required ScanStatus outcome,
    required String receivedAt,
    required bool replayed,
  }) async {
    _ensureOpen();
    if (![
      ScanStatus.accepted,
      ScanStatus.rejected,
      ScanStatus.duplicate,
    ].contains(outcome)) {
      throw ArgumentError('A Backend receipt outcome is required.');
    }
    if (DateTime.tryParse(receivedAt) == null) {
      throw ArgumentError('The Backend receipt timestamp is invalid.');
    }
    final updated = _database.select(
      '''
      UPDATE $tableName
      SET submission_status = ?, received_at = ?, replayed = ?
      WHERE scan_id = ? AND staff_user_id = ?
        AND submission_status = 'pending' AND legacy = 0
      RETURNING scan_id;
    ''',
      [outcome.name, receivedAt, replayed ? 1 : 0, scanId, staffUserId],
    );
    if (updated.length != 1) {
      throw StateError(
        'The pending scan could not be updated with its receipt.',
      );
    }
  }

  Future<void> markBlocked(String scanId) async {
    _ensureOpen();
    final updated = _database.select(
      '''
      UPDATE $tableName
      SET submission_status = 'blocked'
      WHERE scan_id = ? AND staff_user_id = ?
        AND submission_status = 'pending' AND legacy = 0
      RETURNING scan_id;
    ''',
      [scanId, staffUserId],
    );
    if (updated.length != 1) {
      throw StateError('The pending scan could not be marked as blocked.');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The attendance store is closed.');
  }
}
