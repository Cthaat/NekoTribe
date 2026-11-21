// Match the existing Nuxt/Go/Rust JS trim set, including BOM, excluding NEL.
final _v2Trim = RegExp(
  r'^[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+|[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+$',
);

String trimAuthInput(String value) => value.replaceAll(_v2Trim, '');

bool validNewPassword(String value) => trimAuthInput(value).length >= 6;

final _emailPattern = RegExp(
  r"^(?!\.)(?!.*\.\.)([A-Z0-9_'+\-\.]*)[A-Z0-9_+-]@([A-Z0-9][A-Z0-9\-]*\.)+[A-Z]{2,}$",
  caseSensitive: false,
);

bool validNewEmail(String value) =>
    _emailPattern.hasMatch(trimAuthInput(value));
bool validRegistrationName(String value) => trimAuthInput(value).length >= 2;
