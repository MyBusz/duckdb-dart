import 'dart:convert';
import 'dart:io';

import 'companions.dart';
import 'errors.dart';
import 'inspector.dart';
import 'io_utils.dart';
import 'manifest.dart';

final class ValidatedAssets {
  const ValidatedAssets(
    this.directory,
    this.digests,
    this.sumsSize,
    this.sumsSha256,
  );

  final Directory directory;
  final Map<String, String> digests;
  final int sumsSize;
  final String sumsSha256;

  File file(String name) => File(
        '${directory.path}${Platform.pathSeparator}$name',
      );
}

Future<ValidatedAssets> validateLocalRelease(
  NativeManifest manifest,
  Directory releaseDirectory,
) async {
  await _requireExactFiles(
    releaseDirectory,
    releaseAssetNames,
    'local release',
  );
  final result = await validateChecksums(manifest, releaseDirectory);
  for (final artifact in manifest.artifacts) {
    await verifyAssetFile(
      result.file(artifact.fileName),
      artifact.size,
      artifact.sha256,
      'Release archive',
    );
  }
  return result;
}

Future<ValidatedAssets> validateSelectedDownload(
  NativeManifest manifest,
  NativeArtifact artifact,
  Directory downloadDirectory,
) async {
  await _requireExactFiles(
    downloadDirectory,
    <String>['assets.lock.json', 'SHA256SUMS', artifact.fileName],
    'release download',
  );
  final result = await validateChecksums(manifest, downloadDirectory);
  await verifyAssetFile(
    result.file(artifact.fileName),
    artifact.size,
    artifact.sha256,
    'Downloaded archive',
  );
  return result;
}

Future<ValidatedAssets> validateChecksums(
  NativeManifest manifest,
  Directory directory,
) async {
  final sumsFile = File(
    '${directory.path}${Platform.pathSeparator}SHA256SUMS',
  );
  final bytes = await readBounded(sumsFile, 16 * 1024, 'SHA256SUMS');
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    fail('SHA256SUMS is not UTF-8');
  }
  if (!text.endsWith('\n') || text.contains('\r')) {
    fail('SHA256SUMS is not in canonical lowercase format');
  }
  final lines = text.substring(0, text.length - 1).split('\n');
  if (lines.length != checksumEntryNames.length) {
    fail('SHA256SUMS does not contain exactly six entries');
  }
  final pattern = RegExp(r'^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$');
  final digests = <String, String>{};
  for (var index = 0; index < lines.length; index++) {
    final match = pattern.firstMatch(lines[index]);
    if (match == null) fail('SHA256SUMS is malformed');
    final name = match.group(2)!;
    if (name != checksumEntryNames[index] ||
        !digests.addName(name, match.group(1)!)) {
      fail('SHA256SUMS has duplicate, missing, or out-of-order entries');
    }
  }
  if (digests['assets.lock.json'] != manifest.sha256) {
    fail('SHA256SUMS does not match assets.lock.json');
  }
  for (final artifact in manifest.artifacts) {
    if (digests[artifact.fileName] != artifact.sha256) {
      fail('SHA256SUMS does not match the archive metadata');
    }
  }
  await verifyAssetFile(
    File('${directory.path}${Platform.pathSeparator}assets.lock.json'),
    manifest.bytes.length,
    manifest.sha256,
    'assets.lock.json',
  );
  return ValidatedAssets(
    directory,
    Map.unmodifiable(digests),
    bytes.length,
    await hashFile(sumsFile),
  );
}

Future<void> verifyAssetFile(
  File file,
  int expectedSize,
  String expectedSha256,
  String label,
) async {
  await requireRegularFile(file, label);
  if (await file.length() != expectedSize ||
      await hashFile(file) != expectedSha256) {
    fail('$label has the wrong size or checksum');
  }
}

Future<void> _requireExactFiles(
  Directory directory,
  List<String> expectedNames,
  String label,
) async {
  await ensureSafeDirectory(directory, create: false, label: label);
  final names = <String>{};
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        fail('The $label contains a non-file entry');
      }
      names.add(entity.uri.pathSegments.where((part) => part.isNotEmpty).last);
    }
  } on NativeArtifactsException {
    rethrow;
  } on FileSystemException {
    fail('Unable to enumerate the $label');
  }
  if (names.length != expectedNames.length ||
      !names.containsAll(expectedNames)) {
    fail('The $label does not contain the exact expected asset set');
  }
}

extension on Map<String, String> {
  bool addName(String name, String digest) {
    if (containsKey(name)) return false;
    this[name] = digest;
    return true;
  }
}
