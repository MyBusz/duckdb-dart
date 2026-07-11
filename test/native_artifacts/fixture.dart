import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../tool/native_artifacts/companions.dart';
import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/inspector.dart';
import '../../tool/native_artifacts/trust.dart';

final class NativeFixture {
  const NativeFixture({
    required this.root,
    required this.releaseDirectory,
    required this.cacheDirectory,
    required this.packageRoot,
    required this.manifestFile,
    required this.manifestJson,
  });

  final Directory root;
  final Directory releaseDirectory;
  final Directory cacheDirectory;
  final Directory packageRoot;
  final File manifestFile;
  final Map<String, Object?> manifestJson;
}

final class FakeReleaseDownloader implements ImmutableReleaseDownloader {
  FakeReleaseDownloader(this.releaseDirectory, {this.immutable = true});

  final Directory releaseDirectory;
  final bool immutable;
  int calls = 0;

  @override
  Future<void> download({
    required String repository,
    required String tag,
    required String archiveName,
    required Directory destination,
  }) async {
    calls++;
    if (!immutable || repository != releaseRepository || tag != releaseTag) {
      fail('The fake release is not immutable');
    }
    await destination.create(recursive: true);
    for (final name in ['assets.lock.json', 'SHA256SUMS', archiveName]) {
      await File('${releaseDirectory.path}/$name')
          .copy('${destination.path}/$name');
    }
  }
}

Future<NativeFixture> createNativeFixture(Directory root) async {
  final release = Directory('${root.path}/release')
    ..createSync(recursive: true);
  final packageRoot = Directory('${root.path}/package')..createSync();
  final manifest = syntheticManifest();
  final artifacts =
      (manifest['artifacts']! as List<Object?>).cast<Map<String, Object?>>();
  for (final artifact in artifacts) {
    final members =
        (artifact['members']! as List<Object?>).cast<Map<String, Object?>>();
    final entries = <MapEntry<String, List<int>>>[];
    for (var index = 0; index < members.length; index++) {
      final member = members[index];
      final bytes = utf8.encode('${artifact['target']}-member-$index');
      member['size'] = bytes.length;
      member['sha256'] = sha256.convert(bytes).toString();
      entries.add(MapEntry(member['path']! as String, bytes));
    }
    final archiveBytes = buildStoredZip(entries);
    artifact['size'] = archiveBytes.length;
    artifact['sha256'] = sha256.convert(archiveBytes).toString();
    File('${release.path}/${artifact['fileName']}')
        .writeAsBytesSync(archiveBytes);
  }

  final manifestFile = File('${release.path}/assets.lock.json');
  manifestFile.writeAsStringSync(jsonEncode(manifest));
  rewriteChecksums(release, manifest);
  return NativeFixture(
    root: root,
    releaseDirectory: release,
    cacheDirectory: Directory('${root.path}/cache'),
    packageRoot: packageRoot,
    manifestFile: manifestFile,
    manifestJson: manifest,
  );
}

Map<String, Object?> syntheticManifest() => <String, Object?>{
      'schemaVersion': 1,
      'releaseTag': releaseTag,
      'sourceCommit': '1' * 40,
      'coreCommit': coreCommit,
      'toolchains': <String, Object?>{
        'flutter': '3.41.3',
        'dart': '3.11.1',
        'androidNdk': '28.2.13676358',
        'buildTools': <Object?>[
          {'name': 'cmake', 'version': '4.0.2'},
          {'name': 'ninja', 'version': '1.12.1'},
          {'name': 'linux-clang', 'version': '18.1.3'},
          {'name': 'xcode', 'version': '26.0'},
          {'name': 'apple-clang', 'version': '17.0.0'},
          {'name': 'visual-studio', 'version': '17.14.0'},
          {'name': 'msvc', 'version': '19.44.0'},
        ],
      },
      'staticExtensions': ['icu', 'parquet', 'json'],
      'licenses': <Object?>[
        {'path': 'LICENSE', 'identifier': 'MIT'},
        {'path': 'licenses/duckdb/LICENSE', 'identifier': 'MIT'},
      ],
      'artifacts': <Object?>[
        artifactJson(
          target: 'android',
          supportedPlatforms: [
            platform('android', ['arm64-v8a', 'x86_64'], minimum: '21'),
          ],
          members: [
            memberJson('android', 'arm64-v8a/libduckdb.so'),
            memberJson('android', 'x86_64/libduckdb.so'),
          ],
        ),
        artifactJson(
          target: 'ios',
          supportedPlatforms: [
            platform('ios', ['arm64'], minimum: '13.0'),
            platform('ios-simulator', ['arm64', 'x86_64'], minimum: '13.0'),
          ],
          members: [
            memberJson('ios', 'duckdb.xcframework/Info.plist'),
            memberJson(
              'ios',
              'duckdb.xcframework/ios-arm64/duckdb.framework/duckdb',
            ),
            memberJson(
              'ios',
              'duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb',
            ),
          ],
        ),
        artifactJson(
          target: 'macos',
          supportedPlatforms: [
            platform('macos', ['x86_64'], minimum: '10.15'),
            platform('macos', ['arm64'], minimum: '11.0'),
          ],
          members: [memberJson('macos', 'libduckdb.dylib')],
        ),
        artifactJson(
          target: 'linux',
          supportedPlatforms: [
            platform('linux', ['x86_64']),
          ],
          members: [memberJson('linux', 'libduckdb.so')],
        ),
        artifactJson(
          target: 'windows',
          supportedPlatforms: [
            platform('windows', ['x64']),
          ],
          members: [memberJson('windows', 'duckdb.dll')],
        ),
      ],
    };

Map<String, Object?> artifactJson({
  required String target,
  required List<Map<String, Object?>> supportedPlatforms,
  required List<Map<String, Object?>> members,
}) =>
    <String, Object?>{
      'target': target,
      'fileName': archiveNamesByTarget[target],
      'size': 1,
      'sha256': 'a' * 64,
      'supportedPlatforms': supportedPlatforms,
      'members': members,
    };

Map<String, Object?> platform(
  String name,
  List<String> architectures, {
  String? minimum,
}) =>
    <String, Object?>{
      'platform': name,
      'architectures': architectures,
      if (minimum != null) 'minimumOsVersion': minimum,
    };

Map<String, Object?> memberJson(String target, String memberPath) =>
    <String, Object?>{
      'path': memberPath,
      'size': 1,
      'sha256': 'a' * 64,
      'installDestination': '${installRootForTarget(target)}/$memberPath',
    };

void rewriteChecksums(
  Directory release,
  Map<String, Object?> manifest,
) {
  final sums = StringBuffer();
  for (final name in checksumEntryNames) {
    sums.writeln(
      '${sha256.convert(File('${release.path}/$name').readAsBytesSync())}  $name',
    );
  }
  File('${release.path}/SHA256SUMS').writeAsStringSync(sums.toString());
}

List<int> buildStoredZip(Iterable<MapEntry<String, List<int>>> entries) =>
    buildRawZip(
      entries
          .map((entry) => RawZipEntry(entry.key, entry.value))
          .toList(growable: false),
    );

final class RawZipEntry {
  const RawZipEntry(
    this.name,
    this.data, {
    this.localName,
    this.flags = 0,
    this.localFlags,
    this.method = 0,
    this.localMethod,
    this.versionMadeBy = 20,
    this.versionNeeded = 20,
    this.localVersionNeeded,
    this.externalAttributes = 0,
    this.compressedData,
    this.declaredUncompressedSize,
    this.declaredCompressedSize,
    this.crc,
    this.localCrc,
    this.localCompressedSize,
    this.localUncompressedSize,
    this.extra = const <int>[],
    this.localExtra,
    this.comment = const <int>[],
    this.localOffset,
  });

  final String name;
  final String? localName;
  final List<int> data;
  final int flags;
  final int? localFlags;
  final int method;
  final int? localMethod;
  final int versionMadeBy;
  final int versionNeeded;
  final int? localVersionNeeded;
  final int externalAttributes;
  final List<int>? compressedData;
  final int? declaredUncompressedSize;
  final int? declaredCompressedSize;
  final int? crc;
  final int? localCrc;
  final int? localCompressedSize;
  final int? localUncompressedSize;
  final List<int> extra;
  final List<int>? localExtra;
  final List<int> comment;
  final int? localOffset;
}

List<int> buildRawZip(
  List<RawZipEntry> entries, {
  List<int> archiveComment = const <int>[],
}) {
  final output = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;
  for (final entry in entries) {
    final name = ascii.encode(entry.name);
    final localName = ascii.encode(entry.localName ?? entry.name);
    final compressed = entry.compressedData ?? entry.data;
    final compressedSize = entry.declaredCompressedSize ?? compressed.length;
    final uncompressedSize =
        entry.declaredUncompressedSize ?? entry.data.length;
    final checksum = entry.crc ?? crc32(entry.data);
    final localExtra = entry.localExtra ?? entry.extra;
    final actualOffset = offset;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(
        4,
        entry.localVersionNeeded ?? entry.versionNeeded,
        Endian.little,
      )
      ..setUint16(6, entry.localFlags ?? entry.flags, Endian.little)
      ..setUint16(8, entry.localMethod ?? entry.method, Endian.little)
      ..setUint32(14, entry.localCrc ?? checksum, Endian.little)
      ..setUint32(
        18,
        entry.localCompressedSize ?? compressedSize,
        Endian.little,
      )
      ..setUint32(
        22,
        entry.localUncompressedSize ?? uncompressedSize,
        Endian.little,
      )
      ..setUint16(26, localName.length, Endian.little)
      ..setUint16(28, localExtra.length, Endian.little);
    output
      ..add(local.buffer.asUint8List())
      ..add(localName)
      ..add(localExtra)
      ..add(compressed);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, entry.versionMadeBy, Endian.little)
      ..setUint16(6, entry.versionNeeded, Endian.little)
      ..setUint16(8, entry.flags, Endian.little)
      ..setUint16(10, entry.method, Endian.little)
      ..setUint32(16, checksum, Endian.little)
      ..setUint32(20, compressedSize, Endian.little)
      ..setUint32(24, uncompressedSize, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint16(30, entry.extra.length, Endian.little)
      ..setUint16(32, entry.comment.length, Endian.little)
      ..setUint32(38, entry.externalAttributes, Endian.little)
      ..setUint32(42, entry.localOffset ?? actualOffset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name)
      ..add(entry.extra)
      ..add(entry.comment);
    offset += 30 + localName.length + localExtra.length + compressed.length;
  }
  final centralBytes = central.takeBytes();
  output.add(centralBytes);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little)
    ..setUint16(20, archiveComment.length, Endian.little);
  output
    ..add(eocd.buffer.asUint8List())
    ..add(archiveComment);
  return output.takeBytes();
}

int crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    var current = (crc ^ byte) & 0xff;
    for (var bit = 0; bit < 8; bit++) {
      current = (current & 1) != 0 ? (current >> 1) ^ 0xedb88320 : current >> 1;
    }
    crc = (crc >> 8) ^ current;
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
