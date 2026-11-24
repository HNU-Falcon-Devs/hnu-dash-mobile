import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'development_scan_policy.dart';
import 'offline_capture.dart';
import 'offline_completion.dart';
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
    final version = database
        .select('PRAGMA user_version;')
        .single
        .values
        .single;
    if (version is! int || version < 0 || version > 3) {
      throw StateError('Unsupported encrypted attendance schema.');
    }
    database.execute('PRAGMA foreign_keys = ON;');
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table';")
        .map((row) => row['name'])
        .toSet();
    if (version >= 2) {
      if (!tables.containsAll({
        tableName,
        'offline_requests',
        'offline_preparations',
        'offline_claims',
      })) {
        throw StateError('Encrypted attendance schema is incomplete.');
      }
      if (version == 3) {
        if (!tables.contains('offline_accounting')) {
          throw StateError('Encrypted accounting schema is incomplete.');
        }
        return;
      }
    }
    if (version == 1 && !tables.contains(tableName)) {
      throw StateError('Original encrypted attendance schema is incomplete.');
    }
    database.execute('BEGIN IMMEDIATE;');
    try {
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
      database.execute('''
        CREATE TABLE IF NOT EXISTS offline_requests (
          request_id TEXT PRIMARY KEY,
          staff_user_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          assignment_id TEXT NOT NULL,
          resolved INTEGER NOT NULL DEFAULT 0 CHECK (resolved IN (0,1))
        );
      ''');
      database.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS offline_pending_request
        ON offline_requests(staff_user_id,event_id,assignment_id)
        WHERE resolved = 0;
      ''');
      database.execute('''
        CREATE TABLE IF NOT EXISTS offline_preparations (
          preparation_id TEXT PRIMARY KEY,
          request_id TEXT NOT NULL UNIQUE REFERENCES offline_requests(request_id),
          staff_user_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          context TEXT NOT NULL,
          UNIQUE (preparation_id,staff_user_id,event_id)
        );
      ''');
      database.execute('''
        CREATE TABLE IF NOT EXISTS offline_claims (
          capture_id TEXT PRIMARY KEY,
          preparation_id TEXT NOT NULL,
          staff_user_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          checkpoint_id TEXT NOT NULL,
          student_id TEXT NOT NULL,
          claimed_at TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('queued','submitted','blocked')),
          received_at TEXT,
          replayed INTEGER CHECK (replayed IN (0,1)),
          FOREIGN KEY (preparation_id,staff_user_id,event_id)
            REFERENCES offline_preparations(preparation_id,staff_user_id,event_id),
          CHECK (
            (status = 'submitted' AND received_at IS NOT NULL AND replayed IS NOT NULL)
            OR (status != 'submitted' AND received_at IS NULL AND replayed IS NULL)
          )
        );
      ''');
      database.execute('''
        CREATE INDEX IF NOT EXISTS offline_claims_owner_status
        ON offline_claims(staff_user_id,status);
      ''');
      database.execute('''
        CREATE TABLE IF NOT EXISTS offline_accounting (
          preparation_id TEXT PRIMARY KEY,
          staff_user_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          intent_count INTEGER CHECK (intent_count >= 0),
          terminal TEXT,
          FOREIGN KEY (preparation_id,staff_user_id,event_id)
            REFERENCES offline_preparations(preparation_id,staff_user_id,event_id),
          CHECK (intent_count IS NOT NULL OR terminal IS NOT NULL)
        );
      ''');
      database.execute('PRAGMA user_version = 3;');
      database.execute('COMMIT;');
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    }
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
        !isApprovedDevelopmentStudentId(studentId)) {
      throw ArgumentError('The event, checkpoint, or Student ID is invalid.');
    }

    // A terminal conflict must not be bypassed by creating a new UUID for
    // the same event/checkpoint/Student ID. It remains support-only evidence.
    final conflict = _database.select(
      '''
      SELECT scan_id FROM $tableName
      WHERE staff_user_id = ? AND event_id = ? AND checkpoint_id = ?
        AND student_id = ? AND submission_status = 'blocked' AND legacy = 0
      LIMIT 1;
    ''',
      [staffUserId, eventId, checkpointId, studentId],
    );
    final offlineConflict = _database.select(
      '''
      SELECT capture_id FROM offline_claims
      WHERE staff_user_id = ? AND event_id = ? AND checkpoint_id = ?
        AND student_id = ? AND status != 'submitted' LIMIT 1;
      ''',
      [staffUserId, eventId, checkpointId, studentId],
    );
    if (conflict.isNotEmpty || offlineConflict.isNotEmpty) {
      throw StateError(
        'This scan payload has unresolved evidence. Contact support.',
      );
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
      WHERE staff_user_id = ? AND submission_status = 'pending'
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

  static const offlineQueueCapacity = 2400;

  /// Retain the original request UUID until a validated response is stored.
  ({String id, bool created}) offlineRequest(
    String eventId,
    String assignmentId,
  ) {
    _ensureOpen();
    offlineUuid(staffUserId);
    offlineUuid(eventId);
    offlineUuid(assignmentId);
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = _database.select(
        '''
        SELECT request_id FROM offline_requests
        WHERE staff_user_id = ? AND event_id = ? AND assignment_id = ?
          AND resolved = 0;
        ''',
        [staffUserId, eventId, assignmentId],
      );
      final id = rows.isEmpty
          ? const Uuid().v4()
          : rows.single['request_id'] as String;
      if (rows.isEmpty) {
        _database.execute(
          '''
          INSERT INTO offline_requests
            (request_id,staff_user_id,event_id,assignment_id)
          VALUES (?,?,?,?);
          ''',
          [id, staffUserId, eventId, assignmentId],
        );
      }
      _database.execute('COMMIT;');
      return (id: id, created: rows.isEmpty);
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void saveOfflinePreparation(OfflinePreparation preparation) {
    _ensureOpen();
    if (preparation.staffId != staffUserId) {
      throw StateError('Preparation owner mismatch.');
    }
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final request = _database.select(
        '''
        SELECT request_id FROM offline_requests
        WHERE request_id = ? AND staff_user_id = ? AND event_id = ?
          AND assignment_id = ? AND resolved = 0;
        ''',
        [
          preparation.requestId,
          staffUserId,
          preparation.eventId,
          preparation.assignmentId,
        ],
      );
      if (request.length != 1) {
        throw StateError('Preparation request is unavailable.');
      }
      _database.execute(
        '''
        INSERT INTO offline_preparations
          (preparation_id,request_id,staff_user_id,event_id,context)
        VALUES (?,?,?,?,?);
        ''',
        [
          preparation.id,
          preparation.requestId,
          staffUserId,
          preparation.eventId,
          jsonEncode(preparation.toJson()),
        ],
      );
      _database.execute(
        'UPDATE offline_requests SET resolved = 1 '
        'WHERE request_id = ? AND staff_user_id = ?;',
        [preparation.requestId, staffUserId],
      );
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  OfflineClaim createOfflineClaim({
    required OfflineTimeGuard guard,
    required String checkpointId,
    required String studentId,
  }) {
    _ensureOpen();
    final preparation = guard.preparation;
    if (preparation.staffId != staffUserId ||
        !isApprovedDevelopmentStudentId(studentId)) {
      throw StateError('Offline capture scope is invalid.');
    }
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final saved = _database.select(
        '''
        SELECT context FROM offline_preparations
        WHERE preparation_id = ? AND staff_user_id = ? AND event_id = ?;
        ''',
        [preparation.id, staffUserId, preparation.eventId],
      );
      if (saved.length != 1 ||
          saved.single['context'] != jsonEncode(preparation.toJson())) {
        throw StateError('Preparation context is unavailable.');
      }
      if (preparationSummary(preparation.id).captureStopped) {
        throw const OfflineCaptureException(
          'Capture has stopped for this preparation. Saved evidence is retained.',
        );
      }
      final pending = _database.select(
        '''
        SELECT 1 FROM $tableName
        WHERE staff_user_id = ? AND legacy = 0
          AND (submission_status = 'pending' OR
            (submission_status = 'blocked' AND event_id = ?
              AND checkpoint_id = ? AND student_id = ?))
        LIMIT 1;
        ''',
        [staffUserId, preparation.eventId, checkpointId, studentId],
      );
      final conflict = _database.select(
        '''
        SELECT 1 FROM offline_claims
        WHERE staff_user_id = ? AND event_id = ? AND checkpoint_id = ?
          AND student_id = ? AND status = 'blocked' LIMIT 1;
        ''',
        [staffUserId, preparation.eventId, checkpointId, studentId],
      );
      if (pending.isNotEmpty || conflict.isNotEmpty) {
        throw const OfflineCaptureException(
          'Resolve or escalate the original evidence first.',
        );
      }
      final count =
          _database
                  .select(
                    "SELECT count(*) AS total FROM offline_claims "
                    "WHERE status != 'submitted';",
                  )
                  .single['total']
              as int;
      if (count >= offlineQueueCapacity) {
        throw const OfflineCaptureException(
          'The unresolved offline queue is full. Sync or contact support before capturing again.',
        );
      }
      final claimedAt = guard.claimTime(checkpointId);
      if (claimedAt == null) {
        throw const OfflineCaptureException(
          'The capture window is not safely established. Reconnect and prepare again.',
        );
      }
      final claim = OfflineClaim(
        id: const Uuid().v4(),
        preparationId: preparation.id,
        eventId: preparation.eventId,
        checkpointId: checkpointId,
        staffId: staffUserId,
        studentId: studentId,
        claimedAt: claimedAt,
        status: OfflineClaimStatus.queued,
      );
      _database.execute(
        '''
        INSERT INTO offline_claims
          (capture_id,preparation_id,staff_user_id,event_id,checkpoint_id,
           student_id,claimed_at,status)
        VALUES (?,?,?,?,?,?,?,'queued');
        ''',
        [
          claim.id,
          claim.preparationId,
          staffUserId,
          claim.eventId,
          claim.checkpointId,
          claim.studentId,
          claimedAt.toIso8601String(),
        ],
      );
      _database.execute('COMMIT;');
      return claim;
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  OfflineClaim _offlineClaim(Row row) => OfflineClaim(
    id: row['capture_id'] as String,
    preparationId: row['preparation_id'] as String,
    eventId: row['event_id'] as String,
    checkpointId: row['checkpoint_id'] as String,
    staffId: row['staff_user_id'] as String,
    studentId: row['student_id'] as String,
    claimedAt: offlineInstant(row['claimed_at']),
    status: OfflineClaimStatus.values.byName(row['status'] as String),
    receivedAt: row['received_at'] == null
        ? null
        : offlineInstant(row['received_at']),
    replayed: row['replayed'] == null ? null : row['replayed'] == 1,
  );

  OfflinePreparationSummary preparationSummary(String preparationId) {
    _ensureOpen();
    offlineUuid(preparationId);
    final row = _database.select(
      '''
      SELECT p.*, a.intent_count, a.terminal
      FROM offline_preparations p LEFT JOIN offline_accounting a
        ON a.preparation_id = p.preparation_id
        AND a.staff_user_id = p.staff_user_id AND a.event_id = p.event_id
      WHERE p.staff_user_id = ? AND p.preparation_id = ?;
      ''',
      [staffUserId, preparationId],
    ).single;
    final raw = jsonDecode(row['context'] as String) as Map;
    final preparation = OfflinePreparation.parse(
      raw,
      eventId: row['event_id'] as String,
      assignmentId: offlineUuid(raw['assignment_id']),
      staffId: staffUserId,
      requestId: row['request_id'] as String,
    );
    if (preparation.id != preparationId) {
      throw StateError('Stored preparation scope mismatch.');
    }
    final rows = _database.select(
      'SELECT status, count(*) AS total FROM offline_claims '
      'WHERE staff_user_id = ? AND preparation_id = ? GROUP BY status;',
      [staffUserId, preparationId],
    );
    final counts = {for (final row in rows) row['status']: row['total'] as int};
    return OfflinePreparationSummary(
      preparation,
      OfflineQueueCounts(
        counts['queued'] ?? 0, counts['submitted'] ?? 0, counts['blocked'] ?? 0,
      ),
      row['intent_count'] == null ? null : completionCount(row['intent_count']),
      row['terminal'] == null
          ? null : OfflineAccounting.parse(jsonDecode(row['terminal'] as String) as Map),
    );
  }

  List<OfflinePreparationSummary> preparations({int offset = 0}) {
    _ensureOpen();
    if (offset < 0) throw ArgumentError.value(offset);
    return _database.select(
      'SELECT preparation_id FROM offline_preparations '
      'WHERE staff_user_id = ? ORDER BY rowid DESC LIMIT 10 OFFSET ?;',
      [staffUserId, offset],
    ).map((row) => preparationSummary(row['preparation_id'] as String)).toList();
  }

  void persistCompletionIntent(String preparationId, int count) {
    _ensureOpen();
    completionCount(count);
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final summary = preparationSummary(preparationId);
      if (summary.accounting != null || !summary.drained ||
          summary.counts.submitted != count ||
          (summary.intent != null && summary.intent != count)) {
        throw StateError('Completion intent does not match local evidence.');
      }
      if (summary.intent == null) {
        _database.execute(
          'INSERT INTO offline_accounting '
          '(preparation_id,staff_user_id,event_id,intent_count) VALUES (?,?,?,?);',
          [preparationId, staffUserId, summary.preparation.eventId, count],
        );
      }
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  void recordAccounting(String preparationId, OfflineAccounting accounting) {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final summary = preparationSummary(preparationId);
      final terminal = jsonEncode(accounting.toJson());
      if (summary.accounting != null) {
        if (jsonEncode(summary.accounting!.toJson()) != terminal) {
          throw StateError('Immutable accounting mismatch.');
        }
      } else {
        _database.execute(
          '''
          INSERT INTO offline_accounting (preparation_id,staff_user_id,event_id,terminal)
          VALUES (?,?,?,?) ON CONFLICT(preparation_id) DO UPDATE SET terminal=excluded.terminal
          WHERE staff_user_id=excluded.staff_user_id AND event_id=excluded.event_id;
          ''',
          [preparationId, staffUserId, summary.preparation.eventId, terminal],
        );
      }
      _database.execute('COMMIT;');
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  List<OfflineSyncGroup> offlineSyncGroups() {
    _ensureOpen();
    return _database
        .select(
          '''
          SELECT p.preparation_id, p.context, count(*) AS queued
          FROM offline_claims c
          JOIN offline_preparations p
            ON p.preparation_id = c.preparation_id
            AND p.staff_user_id = c.staff_user_id
            AND p.event_id = c.event_id
          WHERE c.staff_user_id = ? AND c.status = 'queued'
          GROUP BY p.preparation_id, p.context
          ORDER BY min(c.rowid);
          ''',
          [staffUserId],
        )
        .map((row) {
          final context = jsonDecode(row['context'] as String) as Map;
          return OfflineSyncGroup(
            row['preparation_id'] as String,
            context['event_title'] as String,
            row['queued'] as int,
          );
        })
        .toList();
  }

  List<OfflineClaim> readQueuedOffline(String preparationId) {
    _ensureOpen();
    offlineUuid(preparationId);
    return _database
        .select(
          "SELECT * FROM offline_claims WHERE staff_user_id = ? "
          "AND preparation_id = ? AND status = 'queued' ORDER BY rowid;",
          [staffUserId, preparationId],
        )
        .map(_offlineClaim)
        .toList();
  }

  List<OfflineClaim> readRecentOffline({int offset = 0}) {
    _ensureOpen();
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    return _database
        .select(
          "SELECT * FROM offline_claims WHERE staff_user_id = ? "
          "ORDER BY CASE WHEN status = 'blocked' THEN 0 ELSE 1 END, "
          "rowid DESC LIMIT 10 OFFSET ?;",
          [staffUserId, offset],
        )
        .map(_offlineClaim)
        .toList();
  }

  OfflineQueueCounts offlineCounts() {
    _ensureOpen();
    final rows = _database.select(
      'SELECT status, count(*) AS total FROM offline_claims '
      'WHERE staff_user_id = ? GROUP BY status;',
      [staffUserId],
    );
    final counts = {for (final row in rows) row['status']: row['total'] as int};
    return OfflineQueueCounts(
      counts['queued'] ?? 0,
      counts['submitted'] ?? 0,
      counts['blocked'] ?? 0,
    );
  }

  void acknowledgeOffline(
    OfflineClaim claim,
    OfflineAcknowledgement acknowledgement,
  ) {
    _ensureOpen();
    if (claim.staffId != staffUserId) {
      throw StateError('Offline claim owner mismatch.');
    }
    final rows = _database.select(
      '''
      UPDATE offline_claims SET status = 'submitted', received_at = ?, replayed = ?
      WHERE capture_id = ? AND staff_user_id = ? AND preparation_id = ?
        AND status = 'queued' RETURNING capture_id;
      ''',
      [
        acknowledgement.receivedAt.toIso8601String(),
        acknowledgement.replayed ? 1 : 0,
        claim.id,
        staffUserId,
        claim.preparationId,
      ],
    );
    if (rows.length != 1) throw StateError('Acknowledgement was not saved.');
  }

  void blockOffline(OfflineClaim claim) {
    _ensureOpen();
    if (claim.staffId != staffUserId) {
      throw StateError('Offline claim owner mismatch.');
    }
    final rows = _database.select(
      '''
      UPDATE offline_claims SET status = 'blocked'
      WHERE capture_id = ? AND staff_user_id = ? AND preparation_id = ?
        AND status = 'queued' RETURNING capture_id;
      ''',
      [claim.id, staffUserId, claim.preparationId],
    );
    if (rows.length != 1) throw StateError('Blocked claim was not saved.');
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
