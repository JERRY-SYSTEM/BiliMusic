import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/services/bili_http.dart';

void main() {
  late HttpServer server;
  late Uri uri;
  StreamSubscription<HttpRequest>? subscription;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/');
  });
  tearDown(() async {
    await server.close(force: true);
    await subscription?.cancel();
    subscription = null;
  });

  for (final sendHeaders in [false, true]) {
    test('timeout releases connections when ${sendHeaders ? 'body' : 'headers'} stall', () async {
      subscription = server.listen((request) async {
        if (request.uri.path == '/ok') {
          request.response.write('ok');
          await request.response.close();
        } else if (sendHeaders) {
          request.response.write('partial');
          await request.response.flush();
          // Deliberately never close the response.
        }
      });
      // More requests than the concurrency limit: timed-out operations must
      // free their slots, including waiters that time out before connecting.
      await Future.wait(List.generate(12, (_) async {
        await expectLater(
          withHttpResponse(uri, (res) => res.transform(utf8.decoder).join(),
            timeout: const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()),
        );
      }));
      expect(await withHttpResponse(uri.resolve('/ok'),
        (res) => res.transform(utf8.decoder).join()), 'ok');
    });
  }

  test('consumer failure does not poison subsequent requests', () async {
    subscription = server.listen((request) async {
      request.response.write('ok');
      await request.response.close();
    });
    await expectLater(withHttpResponse<void>(uri, (_) async {
      throw const FormatException('bad response');
    }), throwsFormatException);
    expect(await withHttpResponse(uri,
      (res) => res.transform(utf8.decoder).join()), 'ok');
  });
}
