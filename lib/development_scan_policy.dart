/// Development safeguard only: never a security boundary against modified apps.
///
/// The numeric value is the exact synthetic Student ID from the Backend M2.3
/// database integration fixture and its frozen test roster.
const backendSyntheticRosterStudentId = '00000123456';

final _canonicalStudentId = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final _syntheticFixtureId = RegExp(r'^SYNTHETIC-[A-Za-z0-9-]+$');

bool isCanonicalStudentId(String? value) =>
    value != null && _canonicalStudentId.hasMatch(value);

/// Only explicitly marked mock IDs and the Backend's synthetic fixture pass.
/// Neither a runtime switch nor a build-time override enables real IDs.
bool isApprovedDevelopmentStudentId(String? value) =>
    isCanonicalStudentId(value) &&
    (value == backendSyntheticRosterStudentId ||
        _syntheticFixtureId.hasMatch(value!));
