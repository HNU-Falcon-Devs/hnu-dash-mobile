import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

enum ScanStatus { pending, accepted, rejected }

enum ConfirmedScanResult { accepted, rejected }

class ProvisionalScan {
  const ProvisionalScan({
    required this.id,
    required this.eventId,
    required this.credentialValue,
    required this.status,
  });

  /// Stable client-generated ID to reuse when a future sync operation retries.
  final String id;
  final String eventId;
  final String credentialValue;
  final ScanStatus status;
}

/// Local scans remain provisional until a future backend confirms a result.
class OfflineAttendanceStore {
  OfflineAttendanceStore._(this._database);

  static const _table = 'provisional_scans';
  static const _fileName = 'hnu_dash_scans.db';

  final Database _database;

  /// Opens the app's private database on Android.
  static Future<OfflineAttendanceStore> openOnDevice() async {
    final directory = await getDatabasesPath();
    return open(path.join(directory, _fileName));
  }

  /// A custom factory and path let tests use real SQLite without a device.
  static Future<OfflineAttendanceStore> open(
    String databasePath, {
    DatabaseFactory? factory,
  }) async {
    final database = await (factory ?? databaseFactory).openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE $_table (
              id TEXT PRIMARY KEY,
              event_id TEXT NOT NULL,
              credential_value TEXT NOT NULL,
              status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'rejected'))
            )
          ''');
        },
      ),
    );
    return OfflineAttendanceStore._(database);
  }

  Future<ProvisionalScan> saveScan({
    required String eventId,
    required String credentialValue,
  }) async {
    if (eventId.isEmpty || credentialValue.isEmpty) {
      // Do not include credential values in exceptions or logs.
      throw ArgumentError('Event and credential identifiers are required.');
    }

    final scan = ProvisionalScan(
      id: const Uuid().v4(),
      eventId: eventId,
      credentialValue: credentialValue,
      status: ScanStatus.pending,
    );
    await _database.insert(_table, _toRow(scan));
    return scan;
  }

  Future<List<ProvisionalScan>> readScans() async {
    final rows = await _database.query(_table, orderBy: 'rowid ASC');
    return rows.map(_fromRow).toList();
  }

  Future<List<ProvisionalScan>> readPendingScans() async {
    final rows = await _database.query(
      _table,
      where: 'status = ?',
      whereArgs: [ScanStatus.pending.name],
      orderBy: 'rowid ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Call only after the authoritative backend has confirmed its result.
  Future<void> recordConfirmedResult(
    String scanId,
    ConfirmedScanResult result,
  ) async {
    final updated = await _database.update(
      _table,
      {'status': result.name},
      where: 'id = ? AND status = ?',
      whereArgs: [scanId, ScanStatus.pending.name],
    );
    if (updated != 1) {
      throw StateError('No pending scan found for the supplied ID.');
    }
  }

  Future<void> close() => _database.close();

  static Map<String, Object?> _toRow(ProvisionalScan scan) => {
    'id': scan.id,
    'event_id': scan.eventId,
    'credential_value': scan.credentialValue,
    'status': scan.status.name,
  };

  static ProvisionalScan _fromRow(Map<String, Object?> row) => ProvisionalScan(
    id: row['id'] as String,
    eventId: row['event_id'] as String,
    credentialValue: row['credential_value'] as String,
    status: ScanStatus.values.byName(row['status'] as String),
  );
}
