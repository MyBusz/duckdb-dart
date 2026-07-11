import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/manifest.dart';
import '../../tool/native_artifacts/zip.dart';
import 'fixture.dart';

void main() {
  late Directory scratch;
  late NativeFixture fixture;
  late NativeArtifact artifact;

  setUp(() async {
    scratch = Directory('.dart_tool/native-artifacts-zip-test')
      ..createSync(recursive: true);
    fixture = await createNativeFixture(scratch);
    final manifest = await NativeManifest.load(
      fixture.manifestFile,
      schemaFile: File('native/native-artifacts.schema.json'),
    );
    artifact = manifest.artifactFor('linux');
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('extracts and hashes exact archive members', () async {
    final result = await verifyAndExtractZip(
      File('${fixture.releaseDirectory.path}/${artifact.fileName}'),
      artifact,
      Directory('${scratch.path}/output'),
    );
    expect(result.memberDigests, <String, String>{
      artifact.members.single.path: artifact.members.single.sha256,
    });
  });

  for (final name in ['../escape.so', '/absolute.so', r'C:\absolute.dll']) {
    test('rejects unsafe member path $name', () async {
      final bytes = utf8.encode('unsafe');
      await _expectArchiveRejected(
        scratch,
        artifact,
        [MapEntry(name, bytes)],
        memberPath: name,
      );
    });
  }

  test('rejects duplicate archive members', () async {
    final bytes = utf8.encode('duplicate');
    await _expectArchiveRejected(
      scratch,
      artifact,
      [
        MapEntry('libduckdb.so', bytes),
        MapEntry('libduckdb.so', bytes),
      ],
    );
  });

  test('rejects an extra or missing member', () async {
    await _expectArchiveRejected(
      scratch,
      artifact,
      [MapEntry('other.so', utf8.encode('other'))],
    );
  });

  test('rejects a member size mismatch', () async {
    final json = _artifactJson(artifact);
    final members = json['members']! as List<Object?>;
    (members.single! as Map<String, Object?>)['size'] = 999;
    await expectLater(
      verifyAndExtractZip(
        File('${fixture.releaseDirectory.path}/${artifact.fileName}'),
        NativeArtifact.fromJson(json),
        Directory('${scratch.path}/size-output'),
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('rejects a tampered member checksum', () async {
    final json = _artifactJson(artifact);
    final members = json['members']! as List<Object?>;
    (members.single! as Map<String, Object?>)['sha256'] = 'f' * 64;
    await expectLater(
      verifyAndExtractZip(
        File('${fixture.releaseDirectory.path}/${artifact.fileName}'),
        NativeArtifact.fromJson(json),
        Directory('${scratch.path}/hash-output'),
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('removes extraction output after failure', () async {
    final output = Directory('${scratch.path}/failed-output');
    final json = _artifactJson(artifact);
    final members = json['members']! as List<Object?>;
    (members.single! as Map<String, Object?>)['sha256'] = 'f' * 64;
    await expectLater(
      verifyAndExtractZip(
        File('${fixture.releaseDirectory.path}/${artifact.fileName}'),
        NativeArtifact.fromJson(json),
        output,
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
    expect(output.existsSync(), isFalse);
  });

  test('rejects more than 64 entries before Archive decode', () async {
    await _expectRawArchiveRejected(
      scratch,
      artifact,
      buildRawZip(<RawZipEntry>[
        for (var index = 0; index < 65; index++)
          RawZipEntry('member-$index', <int>[index]),
      ]),
    );
  });

  test('rejects a central directory over the fixed byte bound', () async {
    final extra = Uint8List(16 * 1024);
    ByteData.sublistView(extra)
      ..setUint16(0, 0x5455, Endian.little)
      ..setUint16(2, extra.length - 4, Endian.little);
    await _expectRawArchiveRejected(
      scratch,
      artifact,
      buildRawZip(<RawZipEntry>[
        for (var index = 0; index < 64; index++)
          RawZipEntry('member-$index', const <int>[1], extra: extra),
      ]),
    );
  });

  test('rejects a compressed symbolic-link bomb before decode', () async {
    final data = List<int>.filled(201, 0);
    await _expectRawArchiveRejected(
      scratch,
      artifact,
      buildRawZip(<RawZipEntry>[
        RawZipEntry(
          'libduckdb.so',
          data,
          method: 8,
          compressedData: const <int>[0],
          declaredCompressedSize: 1,
          declaredUncompressedSize: data.length,
          versionMadeBy: (3 << 8) | 20,
          externalAttributes: 0xa000 << 16,
        ),
      ]),
      memberData: data,
    );
  });

  test('accepts supported features from a newer creator version', () async {
    const data = <int>[1, 2, 3];
    final bytes = buildRawZip(const <RawZipEntry>[
      RawZipEntry(
        'libduckdb.so',
        data,
        versionMadeBy: (3 << 8) | 63,
      ),
    ]);
    final result = await _extractRawArchive(
      scratch,
      artifact,
      bytes,
      memberData: data,
    );
    expect(result.memberDigests, <String, String>{
      'libduckdb.so': sha256.convert(data).toString(),
    });
  });

  test('rejects an EOCD comment with a later signature before decode',
      () async {
    const data = <int>[1, 2, 3];
    final bytes = buildRawZip(
      const <RawZipEntry>[RawZipEntry('libduckdb.so', data)],
      archiveComment: const <int>[
        0x50,
        0x4b,
        0x05,
        0x06,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ],
    );
    await expectLater(
      _extractRawArchive(
        scratch,
        artifact,
        bytes,
        memberData: data,
      ),
      throwsA(
        isA<NativeArtifactsException>().having(
          (error) => error.message,
          'message',
          'ZIP archive comments are unsupported',
        ),
      ),
    );
  });

  for (final entry in <String, RawZipEntry>{
    'encryption': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      flags: 1,
    ),
    'data descriptor': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      flags: 8,
    ),
    'unsupported method': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      method: 12,
    ),
    'local/central method mismatch': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      method: 0,
      localMethod: 8,
    ),
    'local/central flag mismatch': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      localFlags: 0x0800,
    ),
    'local/central name mismatch': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      localName: 'libduckdb.s0',
    ),
    'local/central version mismatch': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      localVersionNeeded: 10,
    ),
    'malformed local offset': const RawZipEntry(
      'libduckdb.so',
      <int>[1],
      localOffset: 1,
    ),
    'out-of-range compressed data': RawZipEntry(
      'libduckdb.so',
      List<int>.filled(100, 1),
      method: 8,
      compressedData: const <int>[1],
      declaredCompressedSize: 100,
      declaredUncompressedSize: 100,
      localCompressedSize: 100,
      localUncompressedSize: 100,
    ),
  }.entries) {
    test('rejects ${entry.key} before Archive decode', () async {
      await _expectRawArchiveRejected(
        scratch,
        artifact,
        buildRawZip(<RawZipEntry>[entry.value]),
        memberData: entry.value.data,
      );
    });
  }

  test('rejects case-colliding ZIP names', () async {
    await _expectRawArchiveRejected(
      scratch,
      artifact,
      buildRawZip(const <RawZipEntry>[
        RawZipEntry('libduckdb.so', <int>[1]),
        RawZipEntry('LIBDUCKDB.SO', <int>[2]),
      ]),
    );
  });

  test('rejects a CRC failure during counted extraction', () async {
    const data = <int>[1, 2, 3];
    await _expectRawArchiveRejected(
      scratch,
      artifact,
      buildRawZip(<RawZipEntry>[
        RawZipEntry('libduckdb.so', data, crc: crc32(const <int>[9, 9, 9])),
      ]),
      memberData: data,
    );
  });

  test('rejects ZIP64 and multi-disk end records', () async {
    final base = Uint8List.fromList(
      buildRawZip(const <RawZipEntry>[
        RawZipEntry('libduckdb.so', <int>[1]),
      ]),
    );
    final zip64 = Uint8List.fromList(base);
    ByteData.sublistView(zip64).setUint16(
      zip64.length - 12,
      0xffff,
      Endian.little,
    );
    await _expectRawArchiveRejected(scratch, artifact, zip64);

    final multiDisk = Uint8List.fromList(base);
    ByteData.sublistView(multiDisk).setUint16(
      multiDisk.length - 18,
      1,
      Endian.little,
    );
    await _expectRawArchiveRejected(scratch, artifact, multiDisk);
  });
}

Future<void> _expectArchiveRejected(
  Directory scratch,
  NativeArtifact base,
  List<MapEntry<String, List<int>>> entries, {
  String? memberPath,
}) async {
  final bytes = buildStoredZip(entries);
  final file = File('${scratch.path}/bad-${scratch.listSync().length}.zip')
    ..writeAsBytesSync(bytes);
  final json = _artifactJson(base)
    ..['size'] = bytes.length
    ..['sha256'] = sha256.convert(bytes).toString();
  if (memberPath != null) {
    final members = json['members']! as List<Object?>;
    final member = members.single! as Map<String, Object?>;
    member
      ..['path'] = memberPath
      ..['size'] = entries.single.value.length
      ..['sha256'] = sha256.convert(entries.single.value).toString();
  }
  await expectLater(
    verifyAndExtractZip(
      file,
      NativeArtifact.fromJson(json),
      Directory('${scratch.path}/bad-output-${scratch.listSync().length}'),
    ),
    throwsA(isA<NativeArtifactsException>()),
  );
}

Map<String, Object?> _artifactJson(NativeArtifact artifact) =>
    jsonDecode(jsonEncode(artifact.json))! as Map<String, Object?>;

Future<void> _expectRawArchiveRejected(
  Directory scratch,
  NativeArtifact base,
  List<int> bytes, {
  List<int>? memberData,
}) async {
  await expectLater(
    _extractRawArchive(
      scratch,
      base,
      bytes,
      memberData: memberData,
    ),
    throwsA(isA<NativeArtifactsException>()),
  );
}

Future<ZipVerificationResult> _extractRawArchive(
  Directory scratch,
  NativeArtifact base,
  List<int> bytes, {
  List<int>? memberData,
}) async {
  final file = File('${scratch.path}/raw-bad-${scratch.listSync().length}.zip')
    ..writeAsBytesSync(bytes);
  final json = _artifactJson(base)
    ..['size'] = bytes.length
    ..['sha256'] = sha256.convert(bytes).toString();
  if (memberData != null) {
    final members = json['members']! as List<Object?>;
    final member = members.single! as Map<String, Object?>;
    member
      ..['size'] = memberData.length
      ..['sha256'] = sha256.convert(memberData).toString();
  }
  return verifyAndExtractZip(
    file,
    NativeArtifact.fromJson(json),
    Directory('${scratch.path}/raw-output-${scratch.listSync().length}'),
  );
}
