part of 'secure_attendance_store.dart';

void _createV2Schema(Database database) {
  database.execute('''
    CREATE TABLE IF NOT EXISTS offline_v2_requests (
      request_id TEXT PRIMARY KEY,
      staff_user_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      assignment_id TEXT NOT NULL,
      scope TEXT NOT NULL,
      observation TEXT NOT NULL,
      UNIQUE (staff_user_id,event_id,assignment_id),
      UNIQUE (request_id,staff_user_id,event_id)
    );
  ''');
  database.execute('''
    CREATE TABLE IF NOT EXISTS offline_v2_preparations (
      preparation_id TEXT PRIMARY KEY,
      request_id TEXT NOT NULL UNIQUE,
      staff_user_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      receipt TEXT NOT NULL,
      anchor TEXT NOT NULL,
      capture_closed INTEGER NOT NULL DEFAULT 0 CHECK (capture_closed IN (0,1)),
      disposition TEXT CHECK (disposition IN ('completed','missing','lost','revoked','undrained')),
      server_count INTEGER CHECK (server_count >= 0),
      server_state TEXT CHECK (server_state IN ('DRAFT','OPEN','SYNCING','FINALIZED')),
      server_sealed INTEGER CHECK (server_sealed IN (0,1)),
      server_deadline TEXT,
      intent_count INTEGER CHECK (intent_count >= 0),
      completion_receipt TEXT,
      UNIQUE (preparation_id,staff_user_id,event_id),
      FOREIGN KEY (request_id,staff_user_id,event_id)
        REFERENCES offline_v2_requests(request_id,staff_user_id,event_id),
      CHECK (completion_receipt IS NULL OR (intent_count IS NOT NULL AND disposition = 'completed'))
    );
  ''');
  database.execute('''
    CREATE TABLE IF NOT EXISTS offline_v2_claims (
      capture_id TEXT PRIMARY KEY,
      preparation_id TEXT NOT NULL,
      staff_user_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      checkpoint_id TEXT NOT NULL,
      student_id TEXT NOT NULL,
      payload TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('queued','attempted','submitted','blocked')),
      acknowledgement TEXT,
      FOREIGN KEY (preparation_id,staff_user_id,event_id)
        REFERENCES offline_v2_preparations(preparation_id,staff_user_id,event_id),
      CHECK ((status = 'submitted') = (acknowledgement IS NOT NULL))
    );
  ''');
  database.execute('''
    CREATE INDEX IF NOT EXISTS offline_v2_owner_status
    ON offline_v2_claims(staff_user_id,status,preparation_id);
  ''');
}

class V2Request {
  const V2Request(this.id, this.scope, this.observation, this.created);

  final String id;
  final V2Scope scope;
  final V2Observation observation;
  final bool created;
}

class V2SavedPreparation {
  const V2SavedPreparation({
    required this.preparation,
    required this.scope,
    required this.anchor,
    required this.captureClosed,
    required this.disposition,
    required this.intent,
    required this.completionReceipt,
  });

  final V2Preparation preparation;
  final V2Scope scope;
  final V2Anchor anchor;
  final bool captureClosed;
  final String? disposition;
  final int? intent;
  final Map<String, dynamic>? completionReceipt;

  bool get canCapture =>
      !captureClosed && disposition == null && intent == null;
}

enum V2ClaimState { queued, attempted, submitted, blocked }

class V2Claim {
  const V2Claim(this.id, this.preparationId, this.payload, this.state);

  final String id, preparationId;
  final String payload;
  final V2ClaimState state;

  Map<String, dynamic> get parameters =>
      Map<String, dynamic>.from(jsonDecode(payload) as Map);
}

class V2Counts {
  const V2Counts(this.queued, this.attempted, this.submitted, this.blocked);

  final int queued, attempted, submitted, blocked;
  int get unresolved => queued + attempted + blocked;
}

/// Separate policy namespace inside the existing keyed, owner-bound SQLCipher
/// handle. No legacy row is converted, reattributed or removed.
extension OfflineV2Store on SecureAttendanceStore {
  T _v2Transaction<T>(T Function() action) {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      _database.execute('COMMIT;');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK;');
      rethrow;
    }
  }

  bool hasUnsettledV2() {
    _ensureOpen();
    return _database.select(
      '''
      SELECT 1 FROM offline_v2_preparations
      WHERE staff_user_id = ? AND disposition IS NULL
      UNION ALL
      SELECT 1 FROM offline_v2_claims
      WHERE staff_user_id = ? AND status != 'submitted'
      UNION ALL
      SELECT 1 FROM offline_v2_requests r
      WHERE r.staff_user_id = ? AND NOT EXISTS (
        SELECT 1 FROM offline_v2_preparations p WHERE p.request_id = r.request_id
      )
      LIMIT 1;
      ''',
      [staffUserId, staffUserId, staffUserId],
    ).isNotEmpty;
  }

  bool _hasUnsettledLegacy() {
    _ensureOpen();
    return _database.select(
      '''
      SELECT 1 FROM attendance_scans
      WHERE staff_user_id = ? AND legacy = 0 AND submission_status = 'pending'
      UNION ALL
      SELECT 1 FROM offline_claims
      WHERE staff_user_id = ? AND status != 'submitted'
      UNION ALL
      SELECT 1 FROM offline_preparations p
      LEFT JOIN offline_accounting a ON a.preparation_id = p.preparation_id
      WHERE p.staff_user_id = ? AND a.terminal IS NULL
      UNION ALL
      SELECT 1 FROM offline_requests
      WHERE staff_user_id = ? AND resolved = 0
      LIMIT 1;
      ''',
      [staffUserId, staffUserId, staffUserId, staffUserId],
    ).isNotEmpty;
  }

  int installationUnresolvedCount() {
    _ensureOpen();
    return _database.select('''
      SELECT
        (SELECT count(*) FROM offline_claims WHERE status != 'submitted') +
        (SELECT count(*) FROM offline_v2_claims WHERE status != 'submitted') AS total;
      ''').single['total'] as int;
  }

  V2Request reserveV2Request(V2Scope scope, V2Observation observation) {
    offlineUuid(staffUserId);
    return _v2Transaction(() {
      if (_hasUnsettledLegacy()) {
        throw StateError('Drain or escalate legacy evidence first.');
      }
      final encodedScope = jsonEncode(scope.toJson());
      final rows = _database.select(
        '''
        SELECT request_id, scope, observation FROM offline_v2_requests
        WHERE staff_user_id = ? AND event_id = ? AND assignment_id = ?;
        ''',
        [staffUserId, scope.eventId, scope.assignmentId],
      );
      if (rows.isNotEmpty) {
        final row = rows.single;
        if (row['scope'] != encodedScope) {
          throw StateError('Original preparation scope changed.');
        }
        return V2Request(
          row['request_id'] as String,
          scope,
          V2Observation.fromJson(jsonDecode(row['observation'] as String)),
          false,
        );
      }
      final id = const Uuid().v4();
      _database.execute(
        '''
        INSERT INTO offline_v2_requests
          (request_id,staff_user_id,event_id,assignment_id,scope,observation)
        VALUES (?,?,?,?,?,?);
        ''',
        [
          id,
          staffUserId,
          scope.eventId,
          scope.assignmentId,
          encodedScope,
          jsonEncode(observation.toJson()),
        ],
      );
      return V2Request(id, scope, observation, true);
    });
  }

  V2SavedPreparation? findV2Preparation(V2Scope scope) {
    _ensureOpen();
    final rows = _database.select(
      '''
      SELECT p.preparation_id, r.scope FROM offline_v2_preparations p
      JOIN offline_v2_requests r ON r.request_id = p.request_id
      WHERE p.staff_user_id = ? AND p.event_id = ? AND r.assignment_id = ?;
      ''',
      [staffUserId, scope.eventId, scope.assignmentId],
    );
    if (rows.isEmpty) return null;
    if (rows.single['scope'] != jsonEncode(scope.toJson())) {
      throw StateError('Original preparation scope changed.');
    }
    return readV2Preparation(rows.single['preparation_id'] as String);
  }

  void saveV2Preparation(
    V2Request request,
    V2Preparation preparation,
    V2Anchor anchor,
  ) {
    _v2Transaction(() {
      final rows = _database.select(
        '''
        SELECT scope, observation FROM offline_v2_requests
        WHERE request_id = ? AND staff_user_id = ? AND event_id = ?
          AND assignment_id = ?;
        ''',
        [request.id, staffUserId, request.scope.eventId, request.scope.assignmentId],
      );
      if (rows.length != 1 ||
          rows.single['scope'] != jsonEncode(request.scope.toJson()) ||
          rows.single['observation'] != jsonEncode(anchor.request.toJson())) {
        throw StateError('Original preparation request unavailable.');
      }
      V2Preparation.parse(
        preparation.receipt,
        request.scope,
        staffUserId,
        request.id,
      );
      if (anchor.provenance == 'original' &&
          (!request.created || preparation.replayed)) {
        throw StateError('Replay cannot establish a new clock anchor.');
      }
      _database.execute(
        '''
        INSERT INTO offline_v2_preparations
          (preparation_id,request_id,staff_user_id,event_id,receipt,anchor)
        VALUES (?,?,?,?,?,?);
        ''',
        [
          preparation.id,
          request.id,
          staffUserId,
          request.scope.eventId,
          jsonEncode(preparation.receipt),
          jsonEncode(anchor.toJson()),
        ],
      );
    });
  }

  V2SavedPreparation readV2Preparation(String id) {
    _ensureOpen();
    final rows = _database.select(
      '''
      SELECT p.*, r.scope, r.observation FROM offline_v2_preparations p
      JOIN offline_v2_requests r ON r.request_id = p.request_id
        AND r.staff_user_id = p.staff_user_id AND r.event_id = p.event_id
      WHERE p.preparation_id = ? AND p.staff_user_id = ?;
      ''',
      [id, staffUserId],
    );
    if (rows.length != 1) throw StateError('Preparation unavailable.');
    final row = rows.single;
    final scope = V2Scope.fromJson(jsonDecode(row['scope'] as String));
    final preparation = V2Preparation.parse(
      jsonDecode(row['receipt'] as String),
      scope,
      staffUserId,
      row['request_id'] as String,
    );
    final anchor = V2Anchor.fromJson(jsonDecode(row['anchor'] as String));
    if (preparation.id != id ||
        preparation.eventId != row['event_id'] ||
        jsonEncode(anchor.request.toJson()) != row['observation'] ||
        (preparation.replayed && anchor.provenance == 'original')) {
      throw StateError('Stored successor context is inconsistent.');
    }
    final intent = row['intent_count'] as int?;
    final raw = row['completion_receipt'] as String?;
    return V2SavedPreparation(
      preparation: preparation,
      scope: scope,
      anchor: anchor,
      captureClosed: row['capture_closed'] == 1,
      disposition: row['disposition'] as String?,
      intent: intent,
      completionReceipt: raw == null
          ? null
          : v2Completion(jsonDecode(raw), id, staffUserId, intent!),
    );
  }

  V2Claim createV2Claim({
    required String preparationId,
    required String checkpointId,
    required String studentId,
    required V2Observation qr,
    required V2Observation confirmation,
  }) {
    if (!isApprovedDevelopmentStudentId(studentId)) {
      throw StateError('Development scanning accepts synthetic IDs only.');
    }
    return _v2Transaction(() {
      final saved = readV2Preparation(preparationId);
      if (!saved.canCapture ||
          !saved.preparation.checkpoints.any((c) => c.id == checkpointId) ||
          _hasUnsettledLegacy()) {
        throw StateError('Local capture scope is unavailable.');
      }
      if (installationUnresolvedCount() >=
          SecureAttendanceStore.offlineQueueCapacity) {
        throw StateError('The unresolved offline queue is full.');
      }
      final blocked = _database.select(
        '''
        SELECT 1 FROM offline_v2_claims
        WHERE staff_user_id = ? AND event_id = ? AND checkpoint_id = ?
          AND student_id = ? AND status = 'blocked' LIMIT 1;
        ''',
        [staffUserId, saved.preparation.eventId, checkpointId, studentId],
      );
      if (blocked.isNotEmpty) {
        throw StateError('Resolve or escalate the original evidence first.');
      }
      final id = const Uuid().v4();
      final clock = saved.anchor.evidence(saved.preparation.issued, qr, confirmation);
      validateV2Clock(clock);
      final payload = jsonEncode({
        'p_preparation_id': preparationId,
        'p_capture_id': id,
        'p_checkpoint_id': checkpointId,
        'p_student_id': studentId,
        'p_clock': clock,
      });
      _database.execute(
        '''
        INSERT INTO offline_v2_claims
          (capture_id,preparation_id,staff_user_id,event_id,checkpoint_id,
           student_id,payload,status)
        VALUES (?,?,?,?,?,?,?,'queued');
        ''',
        [id, preparationId, staffUserId, saved.preparation.eventId,
          checkpointId, studentId, payload],
      );
      return V2Claim(id, preparationId, payload, V2ClaimState.queued);
    });
  }

  V2Claim _readV2Claim(Row row) {
    final claim = V2Claim(
      row['capture_id'] as String,
      row['preparation_id'] as String,
      row['payload'] as String,
      V2ClaimState.values.byName(row['status'] as String),
    );
    final payload = v2Object(claim.parameters, {
      'p_preparation_id', 'p_capture_id', 'p_checkpoint_id', 'p_student_id', 'p_clock',
    });
    if (payload['p_capture_id'] != claim.id ||
        payload['p_preparation_id'] != claim.preparationId ||
        payload['p_checkpoint_id'] != row['checkpoint_id'] ||
        payload['p_student_id'] != row['student_id'] ||
        !isApprovedDevelopmentStudentId(payload['p_student_id'] as String?)) {
      throw StateError('Stored successor claim scope is inconsistent.');
    }
    validateV2Clock(payload['p_clock']);
    return claim;
  }

  List<V2Claim> unresolvedV2Claims(String preparationId) {
    readV2Preparation(preparationId);
    return _database.select(
      '''
      SELECT * FROM offline_v2_claims
      WHERE preparation_id = ? AND staff_user_id = ? AND status != 'submitted'
      ORDER BY rowid;
      ''',
      [preparationId, staffUserId],
    ).map(_readV2Claim).toList();
  }

  V2Counts v2Counts(String preparationId) {
    readV2Preparation(preparationId);
    final rows = _database.select(
      '''
      SELECT status, count(*) AS total FROM offline_v2_claims
      WHERE preparation_id = ? AND staff_user_id = ? GROUP BY status;
      ''',
      [preparationId, staffUserId],
    );
    final counts = {for (final r in rows) r['status']: r['total'] as int};
    return V2Counts(
      counts['queued'] ?? 0,
      counts['attempted'] ?? 0,
      counts['submitted'] ?? 0,
      counts['blocked'] ?? 0,
    );
  }

  void markV2Attempted(V2Claim claim) {
    _v2Transaction(() {
      final rows = _database.select(
        '''
        SELECT payload, status FROM offline_v2_claims
        WHERE capture_id = ? AND preparation_id = ? AND staff_user_id = ?;
        ''',
        [claim.id, claim.preparationId, staffUserId],
      );
      if (rows.length != 1 ||
          rows.single['payload'] != claim.payload ||
          !['queued', 'attempted'].contains(rows.single['status'])) {
        throw StateError('Original successor claim unavailable.');
      }
      _database.execute(
        "UPDATE offline_v2_claims SET status = 'attempted' "
        'WHERE capture_id = ? AND staff_user_id = ?;',
        [claim.id, staffUserId],
      );
    });
  }

  // A definitive no-admission response is not an ambiguous lost acknowledgement.
  void markV2NotAdmitted(V2Claim claim) {
    _v2Transaction(() {
      final rows = _database.select(
        'SELECT payload, status FROM offline_v2_claims '
        'WHERE capture_id = ? AND preparation_id = ? AND staff_user_id = ?;',
        [claim.id, claim.preparationId, staffUserId],
      );
      if (rows.length != 1 ||
          rows.single['payload'] != claim.payload ||
          rows.single['status'] != 'attempted') {
        throw StateError('Original successor attempt unavailable.');
      }
      _database.execute(
        "UPDATE offline_v2_claims SET status = 'queued' "
        'WHERE capture_id = ? AND staff_user_id = ?;',
        [claim.id, staffUserId],
      );
    });
  }

  void acknowledgeV2(V2Claim claim, Object? raw) {
    final ack = v2Acknowledgement(raw, claim.preparationId, claim.id);
    if (offlineInstant(ack['received_at']).isBefore(
      readV2Preparation(claim.preparationId).preparation.issued,
    )) {
      throw const FormatException('Acknowledgement predates preparation.');
    }
    _v2Transaction(() {
      final rows = _database.select(
        '''
        SELECT payload, status FROM offline_v2_claims
        WHERE capture_id = ? AND preparation_id = ? AND staff_user_id = ?;
        ''',
        [claim.id, claim.preparationId, staffUserId],
      );
      if (rows.length != 1 ||
          rows.single['payload'] != claim.payload ||
          rows.single['status'] != 'attempted') {
        throw StateError('Original successor attempt unavailable.');
      }
      _database.execute(
        "UPDATE offline_v2_claims SET status = 'submitted', acknowledgement = ? "
        'WHERE capture_id = ? AND staff_user_id = ?;',
        [jsonEncode(ack), claim.id, staffUserId],
      );
    });
  }

  void blockV2(V2Claim claim) {
    _v2Transaction(() {
      final rows = _database.select(
        '''
        SELECT payload, status FROM offline_v2_claims
        WHERE capture_id = ? AND preparation_id = ? AND staff_user_id = ?;
        ''',
        [claim.id, claim.preparationId, staffUserId],
      );
      if (rows.length != 1 ||
          rows.single['payload'] != claim.payload ||
          rows.single['status'] != 'attempted') {
        throw StateError('Original successor attempt unavailable.');
      }
      _database.execute(
        "UPDATE offline_v2_claims SET status = 'blocked' "
        'WHERE capture_id = ? AND staff_user_id = ?;',
        [claim.id, staffUserId],
      );
    });
  }

  void stopV2Capture(String id) {
    readV2Preparation(id);
    _database.execute(
      'UPDATE offline_v2_preparations SET capture_closed = 1 '
      'WHERE preparation_id = ? AND staff_user_id = ?;',
      [id, staffUserId],
    );
  }

  void recordV2Status(String id, V2Status status) {
    _v2Transaction(() {
      final saved = readV2Preparation(id);
      final counts = v2Counts(id);
      final previous = _database.select(
        'SELECT server_count, server_state, server_sealed, server_deadline FROM offline_v2_preparations '
        'WHERE preparation_id = ? AND staff_user_id = ?;',
        [id, staffUserId],
      ).single;
      final previousCount = previous['server_count'] as int?;
      final previousState = previous['server_state'] as String?;
      final previousDeadline = previous['server_deadline'] as String?;
      const states = ['DRAFT', 'OPEN', 'SYNCING', 'FINALIZED'];
      if (status.count < counts.submitted ||
          (previousCount != null && status.count < previousCount) ||
          (previousState != null && states.indexOf(status.state) < states.indexOf(previousState)) ||
          (previous['server_sealed'] == 1 && !status.sealed) ||
          (previousDeadline != null && (status.deadline == null ||
              offlineInstant(status.deadline).isBefore(offlineInstant(previousDeadline)) ||
              (previous['server_sealed'] == 1 &&
                  offlineInstant(status.deadline) != offlineInstant(previousDeadline)))) ||
          (saved.disposition != null &&
              (saved.disposition != status.disposition ||
                  previousCount != status.count))) {
        throw StateError('Server status contradicts retained evidence.');
      }
      _database.execute(
        '''
        UPDATE offline_v2_preparations
        SET capture_closed = CASE WHEN ? = 1 THEN 1 ELSE capture_closed END,
          disposition = ?, server_count = ?, server_state = ?,
          server_sealed = ?, server_deadline = ?
        WHERE preparation_id = ? AND staff_user_id = ?;
        ''',
        [status.permitsCapture ? 0 : 1, status.disposition, status.count, status.state, status.sealed ? 1 : 0, status.deadline, id, staffUserId],
      );
    });
  }

  void persistV2CompletionIntent(String id, int count) {
    _v2Transaction(() {
      final saved = readV2Preparation(id);
      final counts = v2Counts(id);
      if (counts.unresolved != 0 ||
          counts.submitted != count ||
          (saved.intent != null && saved.intent != count) ||
          (saved.disposition != null &&
              (saved.disposition != 'completed' || saved.intent == null))) {
        throw StateError('Cannot declare a different or unresolved count.');
      }
      _database.execute(
        '''
        UPDATE offline_v2_preparations
        SET capture_closed = 1, intent_count = ?
        WHERE preparation_id = ? AND staff_user_id = ?;
        ''',
        [count, id, staffUserId],
      );
    });
  }

  void recordV2Completion(String id, Object? raw) {
    _v2Transaction(() {
      final saved = readV2Preparation(id);
      final count = saved.intent;
      if (count == null ||
          (saved.disposition != null && saved.disposition != 'completed')) {
        throw StateError('Original completion intent unavailable.');
      }
      final receipt = v2Completion(raw, id, staffUserId, count);
      if (offlineInstant(receipt['accounted_at']).isBefore(saved.preparation.issued)) {
        throw const FormatException('Completion predates preparation.');
      }
      if (saved.completionReceipt != null) {
        final prior = saved.completionReceipt!;
        if (prior['accounted_at'] != receipt['accounted_at']) {
          throw StateError('Original completion receipt changed.');
        }
        return;
      }
      _database.execute(
        '''
        UPDATE offline_v2_preparations SET capture_closed = 1,
          disposition = 'completed', server_count = ?, completion_receipt = ?
        WHERE preparation_id = ? AND staff_user_id = ?;
        ''',
        [count, jsonEncode(receipt), id, staffUserId],
      );
    });
  }
}
