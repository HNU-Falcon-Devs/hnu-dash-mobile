import 'offline_capture.dart';

int completionCount(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw const FormatException('Invalid preparation count.');
  }
  return value;
}

Map _exactObject(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const FormatException('Invalid preparation accounting response.');
  }
  return value;
}

class OfflineAccounting {
  const OfflineAccounting(
    this.disposition,
    this.uploaded,
    this.declared,
    this.accountedAt,
  );

  final String disposition;
  final int uploaded;
  final int? declared;
  final DateTime accountedAt;

  factory OfflineAccounting.parse(Map value) {
    final disposition = value['disposition'];
    final uploaded = completionCount(value['uploaded_count']);
    final declared = value['declared_count'] == null
        ? null
        : completionCount(value['declared_count']);
    if (disposition is! String ||
        ![
          'completed',
          'missing',
          'lost',
          'revoked',
          'undrained',
        ].contains(disposition) ||
        (disposition == 'completed'
            ? declared != uploaded
            : declared != null)) {
      throw const FormatException('Invalid accounting disposition.');
    }
    return OfflineAccounting(
      disposition,
      uploaded,
      declared,
      offlineInstant(value['accounted_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'disposition': disposition,
    'uploaded_count': uploaded,
    'declared_count': declared,
    'accounted_at': accountedAt.toIso8601String(),
  };

  static OfflineAccounting acknowledgement(
    Object? raw,
    OfflinePreparation preparation,
    int count,
  ) {
    final value = _exactObject(raw, {
      'preparation_id',
      'disposition',
      'uploaded_count',
      'declared_count',
      'accounted_at',
      'accounted_by',
      'replayed',
    });
    final accounting = OfflineAccounting.parse(value);
    if (offlineUuid(value['preparation_id']) != preparation.id ||
        offlineUuid(value['accounted_by']) != preparation.staffId ||
        value['replayed'] is! bool ||
        accounting.disposition != 'completed' ||
        accounting.declared != count ||
        accounting.accountedAt.isBefore(preparation.issued)) {
      throw const FormatException('Completion acknowledgement mismatch.');
    }
    return accounting;
  }
}

class OfflinePreparationStatus {
  const OfflinePreparationStatus({
    required this.preparationId,
    required this.eventState,
    required this.uploaded,
    required this.sealedAt,
    required this.accounting,
    required this.canUpload,
    required this.canComplete,
  });

  final String preparationId, eventState;
  final int uploaded;
  final DateTime? sealedAt;
  final OfflineAccounting? accounting;
  final bool canUpload, canComplete;

  bool get permitsCapture =>
      eventState == 'OPEN' &&
      accounting == null &&
      sealedAt == null &&
      canUpload;

  factory OfflinePreparationStatus.parse(Object? raw, OfflinePreparation prep) {
    final value = _exactObject(raw, {
      'preparation_id',
      'event_id',
      'event_state',
      'expires_at',
      'upload_cutoff',
      'sealed_at',
      'uploaded_count',
      'disposition',
      'declared_count',
      'accounted_at',
      'can_upload',
      'can_complete',
    });
    final state = value['event_state'];
    final uploaded = completionCount(value['uploaded_count']);
    final sealed = value['sealed_at'] == null
        ? null
        : offlineInstant(value['sealed_at']);
    final accounting = value['disposition'] == null
        ? null
        : OfflineAccounting.parse(value);
    final canUpload = value['can_upload'];
    final canComplete = value['can_complete'];
    if (offlineUuid(value['preparation_id']) != prep.id ||
        offlineUuid(value['event_id']) != prep.eventId ||
        offlineInstant(value['expires_at']) != prep.expires ||
        offlineInstant(value['upload_cutoff']) != prep.cutoff ||
        state is! String ||
        !['OPEN', 'SYNCING', 'FINALIZED'].contains(state) ||
        canUpload is! bool ||
        canComplete is! bool ||
        (sealed != null && (sealed.isBefore(prep.cutoff) || state == 'OPEN')) ||
        (accounting == null &&
            (value['declared_count'] != null ||
                value['accounted_at'] != null)) ||
        (accounting != null &&
            (accounting.accountedAt.isBefore(prep.issued) ||
                canUpload ||
                canComplete)) ||
        (canUpload && (sealed != null || state == 'FINALIZED')) ||
        (canComplete != (accounting == null && state != 'FINALIZED'))) {
      throw const FormatException('Preparation status mismatch.');
    }
    return OfflinePreparationStatus(
      preparationId: prep.id,
      eventState: state,
      uploaded: uploaded,
      sealedAt: sealed,
      accounting: accounting,
      canUpload: canUpload,
      canComplete: canComplete,
    );
  }
}

class OfflinePreparationSummary {
  const OfflinePreparationSummary(
    this.preparation,
    this.counts,
    this.intent,
    this.accounting,
  );

  final OfflinePreparation preparation;
  final OfflineQueueCounts counts;
  final int? intent;
  final OfflineAccounting? accounting;

  bool get drained => counts.queued == 0 && counts.blocked == 0;
  bool get captureStopped => intent != null || accounting != null;
}
