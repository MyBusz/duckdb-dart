import 'dart:convert';
import 'dart:io';

import 'companions.dart';
import 'errors.dart';
import 'inspector.dart';

abstract interface class ImmutableReleaseDownloader {
  Future<void> download({
    required String repository,
    required String tag,
    required String archiveName,
    required Directory destination,
  });
}

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  required bool runInShell,
});

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) =>
    Process.run(executable, arguments, runInShell: runInShell);

final class GhImmutableReleaseDownloader implements ImmutableReleaseDownloader {
  GhImmutableReleaseDownloader({ProcessRunner processRunner = _runProcess})
      : _processRunner = processRunner;

  final ProcessRunner _processRunner;

  @override
  Future<void> download({
    required String repository,
    required String tag,
    required String archiveName,
    required Directory destination,
  }) async {
    await ensureSafeDirectory(
      destination,
      create: true,
      label: 'release download directory',
    );
    final view = await _run(<String>[
      'release',
      'view',
      tag,
      '--repo',
      repository,
      '--json',
      'isImmutable,tagName,assets',
    ]);
    final release = _decodeRelease(view.stdout);
    if (release['isImmutable'] != true || release['tagName'] != tag) {
      fail('GitHub does not report the exact release tag as immutable');
    }
    final assets = release['assets'];
    if (assets is! List<Object?>) {
      fail('GitHub returned an invalid release asset list');
    }
    final names = <String>{};
    for (final value in assets) {
      if (value is! Map<Object?, Object?> || value['name'] is! String) {
        fail('GitHub returned an invalid release asset list');
      }
      if (!names.add(value['name']! as String)) {
        fail('GitHub returned duplicate release asset names');
      }
    }
    if (names.length != releaseAssetNames.length ||
        !names.containsAll(releaseAssetNames)) {
      fail('The immutable release does not have the exact seven assets');
    }

    final result = await _run(<String>[
      'release',
      'download',
      tag,
      '--repo',
      repository,
      '--dir',
      destination.path,
      '--pattern',
      'assets.lock.json',
      '--pattern',
      'SHA256SUMS',
      '--pattern',
      archiveName,
    ]);
    if (result.exitCode != 0) {
      fail('GitHub CLI could not download the selected release assets');
    }
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    try {
      final result = await _processRunner(
        'gh',
        List<String>.unmodifiable(arguments),
        runInShell: false,
      );
      if (result.exitCode != 0) {
        fail('GitHub CLI rejected the immutable release operation');
      }
      return result;
    } on NativeArtifactsException {
      rethrow;
    } on Object {
      fail('GitHub CLI is required to fetch native release assets');
    }
  }
}

Map<String, Object?> _decodeRelease(Object output) {
  if (output is! String ||
      output.length > 4 * 1024 * 1024 ||
      utf8.encode(output).length > 4 * 1024 * 1024) {
    fail('GitHub CLI returned invalid release data');
  }
  try {
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, Object?>) {
      fail('GitHub CLI returned invalid release data');
    }
    return decoded;
  } on NativeArtifactsException {
    rethrow;
  } on FormatException {
    fail('GitHub CLI returned malformed release data');
  }
}
