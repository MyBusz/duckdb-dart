import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_artifacts/companions.dart';
import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/trust.dart';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory('.dart_tool/native-artifacts-trust-test')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('uses exact shell-free GitHub CLI view and download arguments',
      () async {
    final runner = _RecordingRunner(<Object>[
      _releaseResult(),
      ProcessResult(2, 0, '', ''),
    ]);
    final destination = Directory('${scratch.path}/download');
    await GhImmutableReleaseDownloader(processRunner: runner.call).download(
      repository: releaseRepository,
      tag: releaseTag,
      archiveName: archiveNamesByTarget['linux']!,
      destination: destination,
    );
    expect(runner.calls, <_ProcessCall>[
      const _ProcessCall(
        'gh',
        <String>[
          'release',
          'view',
          releaseTag,
          '--repo',
          releaseRepository,
          '--json',
          'isImmutable,tagName,assets',
        ],
        false,
      ),
      _ProcessCall(
        'gh',
        <String>[
          'release',
          'download',
          releaseTag,
          '--repo',
          releaseRepository,
          '--dir',
          destination.path,
          '--pattern',
          'assets.lock.json',
          '--pattern',
          'SHA256SUMS',
          '--pattern',
          'duckdb-linux-x86_64.zip',
        ],
        false,
      ),
    ]);
  });

  for (final mutation in <String, void Function(Map<String, Object?>)>{
    'non-immutable release': (json) => json['isImmutable'] = false,
    'wrong tag': (json) => json['tagName'] = 'wrong',
    'missing asset': (json) => (json['assets']! as List<Object?>).removeLast(),
    'extra asset': (json) =>
        (json['assets']! as List<Object?>).add(<String, Object?>{'name': 'x'}),
    'duplicate asset': (json) => (json['assets']! as List<Object?>).add(
          <String, Object?>{'name': releaseAssetNames.first},
        ),
    'invalid asset': (json) =>
        (json['assets']! as List<Object?>)[0] = <String, Object?>{'name': 1},
  }.entries) {
    test('rejects ${mutation.key}', () async {
      final json = _releaseJson();
      mutation.value(json);
      await _expectRejected(
        scratch,
        _RecordingRunner(<Object>[
          ProcessResult(1, 0, jsonEncode(json), ''),
        ]),
      );
    });
  }

  test('rejects malformed and oversized GitHub JSON', () async {
    for (final output in <String>['{', 'x' * (4 * 1024 * 1024 + 1)]) {
      await _expectRejected(
        scratch,
        _RecordingRunner(<Object>[ProcessResult(1, 0, output, '')]),
      );
    }
  });

  test('rejects nonzero and thrown subprocess results', () async {
    await _expectRejected(
      scratch,
      _RecordingRunner(<Object>[ProcessResult(1, 1, '', 'failed')]),
    );
    await _expectRejected(
      scratch,
      _RecordingRunner(<Object>[
        const ProcessException('gh', <String>[], 'missing'),
      ]),
    );
  });

  test('rejects a failed download subprocess', () async {
    await _expectRejected(
      scratch,
      _RecordingRunner(<Object>[
        _releaseResult(),
        ProcessResult(2, 1, '', 'failed'),
      ]),
    );
  });
}

Future<void> _expectRejected(
  Directory scratch,
  _RecordingRunner runner,
) async {
  await expectLater(
    GhImmutableReleaseDownloader(processRunner: runner.call).download(
      repository: releaseRepository,
      tag: releaseTag,
      archiveName: archiveNamesByTarget['linux']!,
      destination: Directory(
        '${scratch.path}/rejected-${scratch.listSync().length}',
      ),
    ),
    throwsA(isA<NativeArtifactsException>()),
  );
}

Map<String, Object?> _releaseJson() => <String, Object?>{
      'isImmutable': true,
      'tagName': releaseTag,
      'assets': <Object?>[
        for (final name in releaseAssetNames) <String, Object?>{'name': name},
      ],
    };

ProcessResult _releaseResult() =>
    ProcessResult(1, 0, jsonEncode(_releaseJson()), '');

final class _RecordingRunner {
  _RecordingRunner(this.results);

  final List<Object> results;
  final List<_ProcessCall> calls = <_ProcessCall>[];

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    required bool runInShell,
  }) async {
    calls.add(_ProcessCall(executable, arguments, runInShell));
    final result = results.removeAt(0);
    if (result is ProcessResult) return result;
    throw result;
  }
}

final class _ProcessCall {
  const _ProcessCall(this.executable, this.arguments, this.runInShell);

  final String executable;
  final List<String> arguments;
  final bool runInShell;

  @override
  bool operator ==(Object other) =>
      other is _ProcessCall &&
      executable == other.executable &&
      runInShell == other.runInShell &&
      _listEquals(arguments, other.arguments);

  @override
  int get hashCode =>
      Object.hash(executable, Object.hashAll(arguments), runInShell);
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
