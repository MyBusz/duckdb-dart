import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_artifacts/cli.dart';
import '../../tool/native_artifacts/service.dart';
import 'fixture.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory('.dart_tool/native-artifacts-cli-test')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('seed-local and offline install use the documented options', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(
      schemaFile: File('native/native-artifacts.schema.json'),
    );
    expect(
      await runNativeArtifactsCli(
        [
          'seed-local',
          '--release-dir',
          fixture.releaseDirectory.path,
          '--cache-root',
          fixture.cacheDirectory.path,
        ],
        service: service,
      ),
      0,
    );
    expect(
      await runNativeArtifactsCli(
        [
          'install',
          '--target',
          'linux',
          '--cache-root',
          fixture.cacheDirectory.path,
          '--package-root',
          fixture.packageRoot.path,
          '--offline',
        ],
        service: service,
      ),
      0,
    );
  });

  test('fetch uses the injected immutable release downloader', () async {
    final fixture = await createNativeFixture(scratch);
    final downloader = FakeReleaseDownloader(fixture.releaseDirectory);
    final result = await runNativeArtifactsCli(
      [
        'fetch',
        '--target',
        'windows',
        '--cache-root',
        fixture.cacheDirectory.path,
      ],
      service: NativeArtifactsService(
        schemaFile: File('native/native-artifacts.schema.json'),
        releaseDownloader: downloader,
      ),
    );
    expect(result, 0);
    expect(downloader.calls, 1);
  });

  test('install rejects a missing offline marker', () async {
    final errors = StreamController<List<int>>();
    final bytes = <int>[];
    errors.stream.listen(bytes.addAll);
    final sink = IOSink(errors.sink);
    final result = await runNativeArtifactsCli(
      ['install', '--target', 'linux'],
      errorOutput: sink,
    );
    await sink.close();
    expect(result, isNonZero);
    expect(utf8.decode(bytes), contains('requires --offline'));
  });
}
