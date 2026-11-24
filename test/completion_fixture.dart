import 'package:hnu_dash_mobile/offline_capture.dart';

Map<String, Object?> statusResponse(
  OfflinePreparation prep, {
  int uploaded = 0,
  String? disposition,
  bool sealed = false,
  String state = 'OPEN',
}) => {
  'preparation_id': prep.id,
  'event_id': prep.eventId,
  'event_state': state,
  'expires_at': prep.expires.toIso8601String(),
  'upload_cutoff': prep.cutoff.toIso8601String(),
  'sealed_at': sealed ? prep.cutoff.toIso8601String() : null,
  'uploaded_count': uploaded,
  'disposition': disposition,
  'declared_count': disposition == 'completed' ? uploaded : null,
  'accounted_at': disposition == null ? null : prep.issued.toIso8601String(),
  'can_upload': disposition == null && !sealed && state != 'FINALIZED',
  'can_complete': disposition == null && state != 'FINALIZED',
};

Map<String, Object> completionResponse(
  OfflinePreparation prep,
  int count, {
  bool replayed = false,
}) => {
  'preparation_id': prep.id,
  'disposition': 'completed',
  'uploaded_count': count,
  'declared_count': count,
  'accounted_at': prep.issued.toIso8601String(),
  'accounted_by': prep.staffId,
  'replayed': replayed,
};
