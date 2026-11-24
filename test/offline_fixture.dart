import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/secure_value_store.dart';

const staffA = 'a0000000-0000-4000-8000-000000000001';
const staffB = 'a0000000-0000-4000-8000-000000000002';
const assignmentA = 'b0000000-0000-4000-8000-000000000001';
const assignmentB = 'b0000000-0000-4000-8000-000000000002';
const preparationA = 'c0000000-0000-4000-8000-000000000001';
const preparationB = 'c0000000-0000-4000-8000-000000000002';
const eventId = 'd0000000-0000-4000-8000-000000000001';
const checkpointId = 'e0000000-0000-4000-8000-000000000001';
const requestId = 'f0000000-0000-4000-8000-000000000001';

class MemorySecureValues implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class OfflineFixture {
  OfflineFixture(
    this.issued, {
    this.staff = staffA,
    this.assignment = assignmentA,
    this.preparation = preparationA,
  });

  final DateTime issued;
  final String staff, assignment, preparation;
  DateTime get starts => issued.subtract(const Duration(hours: 1));
  DateTime get ends => issued.add(const Duration(hours: 2));
  DateTime get closes => issued.add(const Duration(hours: 1));
  DateTime get cutoff => closes.add(const Duration(hours: 24));

  OfflineCheckpoint get checkpoint => OfflineCheckpoint(
    checkpointId,
    'Entrance',
    'IN',
    starts,
    closes,
  );

  Map<String, Object> response(
    String request, {
    bool replayed = false,
    DateTime? serverIssued,
  }) => {
    'preparation_id': preparation,
    'request_id': request,
    'event_id': eventId,
    'assignment_id': assignment,
    'staff_user_id': staff,
    'event_title': 'Synthetic Assembly',
    'event_starts_at': starts.toIso8601String(),
    'event_ends_at': ends.toIso8601String(),
    'issued_at': (serverIssued ?? issued).toIso8601String(),
    'expires_at': closes.toIso8601String(),
    'upload_cutoff': cutoff.toIso8601String(),
    'checkpoints': [checkpoint.toJson()],
    'replayed': replayed,
  };

  OfflinePreparation parse(String request) => OfflinePreparation.parse(
    response(request),
    eventId: eventId,
    assignmentId: assignment,
    staffId: staff,
    requestId: request,
  );

  OfflineTimeGuard guard(OfflinePreparation preparation) => OfflineTimeGuard(
    preparation: preparation,
    elapsed: () => const Duration(seconds: 5),
    wallNow: () => issued.add(const Duration(seconds: 4)),
    requestWall: issued.subtract(const Duration(seconds: 1)),
    receivedElapsed: const Duration(seconds: 2),
  );
}

Map<String, Object> acknowledgement(
  Map<String, dynamic> request, {
  bool replayed = false,
}) => {
  'capture_id': request['p_capture_id'] as String,
  'preparation_id': request['p_preparation_id'] as String,
  'status': 'submitted',
  'received_at': DateTime.now().toUtc().toIso8601String(),
  'replayed': replayed,
};
