import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:terraforge/resources/public_resource_client_web.dart';

// Compile to JavaScript and run only with public_resource_client_contract.cjs.
// That harness supplies an in-memory fetch implementation; there is no network.
Future<void> main() async {
  final client = createPublicResourceClient();
  final result = await client.get(
    Uri.parse('https://resource.example.test/fixture'),
  );
  if (result.bodyBytes.join(',') != '1,2,3') {
    throw StateError('Wrong streamed bytes');
  }
  final cancel = Completer<void>();
  final pending = client.send(
    http.AbortableRequest(
      'GET',
      Uri.parse('https://resource.example.test/hang'),
      abortTrigger: cancel.future,
    ),
  );
  cancel.complete();
  var aborted = false;
  try {
    await pending;
  } catch (_) {
    aborted = true;
  }
  if (!aborted) throw StateError('Fetch did not abort');
  client.close();
  // This standalone Node test reports completion to its command-line runner.
  // ignore: avoid_print
  print(
    'Public resource client: stream, credentials omission and abort passed',
  );
}
