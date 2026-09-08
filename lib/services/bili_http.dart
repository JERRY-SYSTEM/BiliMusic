import 'dart:async';
import 'dart:io';

/// The desktop-Chrome user-agent Bilibili's APIs expect. Their risk control
/// rejects requests that look like a bare Dart http client, so every service
/// that talks to them sends this exact string.
const kBiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// Shared [HttpClient] factory. Every service previously declared its own
/// static client with slightly different timeouts; one factory keeps the
/// pooling knobs consistent and fixes the ones that forgot a connection
/// timeout (an unset timeout lets a dead host hang a request forever).
HttpClient biliHttpClient({
  Duration connectionTimeout = const Duration(seconds: 10),
  Duration idleTimeout = const Duration(seconds: 30),
  int maxConnectionsPerHost = 4,
}) =>
    HttpClient()
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost;

final _httpWaiters = <Completer<void>>[];
int _activeHttpRequests = 0;

Future<void> _acquireHttpSlot(Duration timeout) async {
  if (_activeHttpRequests < 8) {
    _activeHttpRequests++;
    return;
  }
  final waiter = Completer<void>();
  _httpWaiters.add(waiter);
  try {
    await waiter.future.timeout(timeout);
  } catch (_) {
    if (!_httpWaiters.remove(waiter)) _releaseHttpSlot();
    rethrow;
  }
}

void _releaseHttpSlot() {
  if (_httpWaiters.isNotEmpty) {
    _httpWaiters.removeAt(0).complete();
  } else {
    _activeHttpRequests--;
  }
}

/// A bounded short request, including response headers and the entire body.
/// A Future timeout alone does not cancel socket I/O. Own this client so a
/// timeout can close it without interrupting unrelated downloads/playback.
Future<T> withHttpResponse<T>(
  Uri uri,
  Future<T> Function(HttpClientResponse response) consume, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async {
  await _acquireHttpSlot(timeout);
  HttpClient? client;
  try {
    final requestClient = biliHttpClient();
    client = requestClient;
    return await (() async {
      final request = await requestClient.getUrl(uri);
      headers.forEach((name, value) => request.headers.set(name, value));
      return await consume(await request.close());
    })().timeout(timeout);
  } finally {
    client?.close(force: true);
    _releaseHttpSlot();
  }
}
