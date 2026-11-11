import 'dart:io';

/// A transport/link change alone does not prove the IM endpoint is reachable.
Future<bool> shellNetworkReachable(Uri entry) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final request = await client
        .openUrl('HEAD', entry)
        .timeout(const Duration(seconds: 4));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 4));
    await response.drain<void>().timeout(const Duration(seconds: 4));
    // Even an HTTP 401/405 is evidence of successful HTTPS transport.
    return response.statusCode >= 100 && response.statusCode < 600;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
