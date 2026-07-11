import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../tool/native_artifacts/companions.dart';
import '../../tool/native_artifacts/service.dart';
import 'fixture.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory('.dart_tool/native-artifacts-generator-test')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('generated candidate passes the authoritative Dart bootstrap', () async {
    final fixture = await createNativeFixture(scratch);
    final input = Directory('${scratch.path}/generator-input')..createSync();
    for (final archiveName in archiveNamesByTarget.values) {
      File('${fixture.releaseDirectory.path}/$archiveName').copySync(
        '${input.path}/$archiveName',
      );
    }
    const sourceCommit = '1111111111111111111111111111111111111111';
    const tools = <String, List<Map<String, String>>>{
      'android': [
        {'name': 'android-cmake', 'version': '3.22.1'},
        {'name': 'android-ninja', 'version': '1.10.2'},
      ],
      'linux': [
        {'name': 'linux-cmake', 'version': '3.22.1'},
        {'name': 'linux-ninja', 'version': '1.10.1'},
        {'name': 'linux-clang', 'version': '14.0.0'},
      ],
      'apple': [
        {'name': 'apple-cmake', 'version': '4.0.2'},
        {'name': 'apple-ninja', 'version': '1.12.1'},
        {'name': 'xcode', 'version': '16.4'},
        {'name': 'apple-clang', 'version': '17.0.0'},
      ],
      'windows': [
        {'name': 'windows-cmake', 'version': '4.0.2'},
        {'name': 'visual-studio', 'version': '17.14.35931.197'},
        {'name': 'msvc', 'version': '19.44.35207.1'},
      ],
    };
    for (final entry in tools.entries) {
      final metadata = <String, Object?>{
        'schemaVersion': 1,
        'platform': entry.key,
        'sourceCommit': sourceCommit,
        'coreCommit': coreCommit,
        'tools': entry.value,
      };
      File('${input.path}/${entry.key}-tools.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(metadata)}\n',
      );
    }

    final output = Directory('${scratch.path}/candidate');
    final result = await Process.run('python3', <String>[
      'tool/native_artifacts/generate_candidate.py',
      'generate',
      '--input-dir',
      input.path,
      '--source-commit',
      sourceCommit,
      '--output-dir',
      output.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    await NativeArtifactsService(
      schemaFile: File('native/native-artifacts.schema.json'),
    ).seedLocalCandidate(
      releaseDirectory: output,
      cacheDirectory: Directory('${scratch.path}/cache'),
    );
    expect(
      output.listSync().map((entry) => path.basename(entry.path)),
      unorderedEquals(releaseAssetNames),
    );
  });
}
