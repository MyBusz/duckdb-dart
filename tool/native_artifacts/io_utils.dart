import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'errors.dart';

Future<String> hashFile(File file) async {
  try {
    return (await sha256.bind(file.openRead()).first).toString();
  } on FileSystemException {
    fail('Unable to read a native artifact file');
  }
}

Future<void> requireRegularFile(File file, String label) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    fail('$label is missing or is not a regular file');
  }
}

Future<List<int>> readBounded(File file, int maximum, String label) async {
  await requireRegularFile(file, label);
  if (await file.length() > maximum) fail('$label exceeds its size limit');
  try {
    return file.readAsBytes();
  } on FileSystemException {
    fail('Unable to read $label');
  }
}

Future<void> copyVerified(
  File source,
  File destination, {
  required int expectedSize,
  required String expectedSha256,
}) async {
  await requireRegularFile(source, 'Native artifact copy source');
  if (await source.length() != expectedSize) {
    fail('Native artifact copy source has the wrong size');
  }
  await destination.parent.create(recursive: true);
  RandomAccessFile? input;
  RandomAccessFile? output;
  final digestSink = _DigestSink();
  final hashSink = sha256.startChunkedConversion(digestSink);
  var copied = 0;
  try {
    input = await source.open();
    output = await destination.open(mode: FileMode.write);
    while (copied < expectedSize) {
      final chunk = await input.read(min(64 * 1024, expectedSize - copied));
      if (chunk.isEmpty) fail('Native artifact copy source changed');
      copied += chunk.length;
      hashSink.add(chunk);
      await output.writeFrom(chunk);
    }
    if ((await input.read(1)).isNotEmpty) {
      fail('Native artifact copy source changed');
    }
    hashSink.close();
    if (digestSink.value?.toString() != expectedSha256) {
      fail('Native artifact copy source has the wrong checksum');
    }
    await output.flush();
  } on NativeArtifactsException {
    rethrow;
  } on FileSystemException {
    fail('Unable to copy native artifact data');
  } finally {
    await input?.close();
    await output?.close();
  }
  if (await destination.length() != expectedSize ||
      await hashFile(destination) != expectedSha256) {
    fail('Copied native artifact data failed verification');
  }
}

Future<void> deleteIfExists(FileSystemEntity entity) async {
  final type = await FileSystemEntity.type(entity.path, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    await entity.delete(recursive: true);
  }
}

String uniqueSuffix() {
  final random = Random.secure();
  final bytes = List<int>.generate(12, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
