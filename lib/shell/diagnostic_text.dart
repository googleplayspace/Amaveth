/// Keep diagnostic meaning while removing credentials from console and URLs.
String diagnosticText(String value) {
  var result = value.replaceAllMapped(
    RegExp(
      r'''((?:password|passwd|access_token|refresh_token|token|api_key|auth_key|session|authorization|cookie|secret)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,"';}]+)''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[redacted]',
  );
  result = result.replaceAllMapped(
    RegExp(r'Bearer\s+[^\s,"\x27]+', caseSensitive: false),
    (_) => 'Bearer [redacted]',
  );
  return result.length > 8192 ? '${result.substring(0, 8192)}…' : result;
}

String diagnosticUrl(Uri uri) => uri
    .replace(
      queryParameters: {
        for (final entry in uri.queryParameters.entries)
          entry.key:
              RegExp(
                r'token|password|secret|auth|cookie',
                caseSensitive: false,
              ).hasMatch(entry.key)
              ? '[redacted]'
              : entry.value,
      },
    )
    .toString();
