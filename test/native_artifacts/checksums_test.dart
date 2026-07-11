import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_artifacts/checksums.dart';
import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/manifest.dart';
import 'fixture.dart';

void main() {
  late Directory scratch;
  late NativeFixture fixture;
  late NativeManifest manifest;
  late File sums;
  late String original;

  setUp(() async {
    scratch = Directory('.dart_tool/native-artifacts-checksum-test')
      ..createSync(recursive: true);
    fixture = await createNativeFixture(scratch);
    manifest = await NativeManifest.load(
      fixture.manifestFile,
      schemaFile: File('native/native-artifacts.schema.json'),
    );
    sums = File('${fixture.releaseDirectory.path}/SHA256SUMS');
    original = sums.readAsStringSync();
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('accepts exact seven assets and six checksum lines', () async {
    final assets = await validateLocalRelease(
      manifest,
      fixture.releaseDirectory,
    );
    expect(assets.digests, hasLength(6));
  });

  for (final mutation in <String, String Function(String)>{
    'malformed digest': (value) => value.replaceFirst(RegExp('[0-9a-f]'), 'Z'),
    'missing line': (value) =>
        '${value.trimRight().split('\n').skip(1).join('\n')}\n',
    'extra line': (value) => '$value${'0' * 64}  extra.zip\n',
    'duplicate filename': (value) {
      final lines = value.trimRight().split('\n');
      lines[1] = '${lines[1].substring(0, 66)}${lines[0].substring(66)}';
      return '${lines.join('\n')}\n';
    },
    'self checksum': (value) {
      final lines = value.trimRight().split('\n');
      lines[0] = '${lines[0].substring(0, 66)}SHA256SUMS';
      return '${lines.join('\n')}\n';
    },
  }.entries) {
    test('rejects ${mutation.key}', () async {
      sums.writeAsStringSync(mutation.value(original));
      await expectLater(
        validateLocalRelease(manifest, fixture.releaseDirectory),
        throwsA(isA<NativeArtifactsException>()),
      );
    });
  }

  test('rejects an extra release asset', () async {
    File('${fixture.releaseDirectory.path}/extra').writeAsStringSync('extra');
    await expectLater(
      validateLocalRelease(manifest, fixture.releaseDirectory),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('rejects a missing release asset', () async {
    File('${fixture.releaseDirectory.path}/duckdb-windows-x64.zip')
        .deleteSync();
    await expectLater(
      validateLocalRelease(manifest, fixture.releaseDirectory),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('rejects a tampered release archive', () async {
    File('${fixture.releaseDirectory.path}/duckdb-linux-x86_64.zip')
        .writeAsStringSync('tampered');
    await expectLater(
      validateLocalRelease(manifest, fixture.releaseDirectory),
      throwsA(isA<NativeArtifactsException>()),
    );
  });
}
