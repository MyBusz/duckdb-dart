import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'inspector.dart';
import 'io_utils.dart';
import 'manifest.dart';

const maxArchiveBytes = 512 * 1024 * 1024;
const maxMemberBytes = 256 * 1024 * 1024;
const maxExpandedBytes = 1024 * 1024 * 1024;
const maxArchiveEntries = 64;
const maxCompressionRatio = 200;
const maxCentralDirectoryBytes = 1024 * 1024;
const maxZipNameBytes = 4096;
const maxZipExtraBytes = 16 * 1024;
const maxZipCommentBytes = 16 * 1024;

final class ZipVerificationResult {
  const ZipVerificationResult(this.memberDigests);

  final Map<String, String> memberDigests;
}

Future<ZipVerificationResult> verifyAndExtractZip(
  File archiveFile,
  NativeArtifact artifact,
  Directory outputRoot,
) async {
  await requireRegularFile(archiveFile, 'Native archive');
  final archiveLength = await archiveFile.length();
  if (archiveLength != artifact.size ||
      archiveLength <= 0 ||
      archiveLength > maxArchiveBytes) {
    fail('Archive size is outside the contract limits');
  }
  await ensureSafeDirectory(
    outputRoot.parent,
    create: true,
    label: 'archive extraction parent',
  );
  final outputType =
      await FileSystemEntity.type(outputRoot.path, followLinks: false);
  if (outputType != FileSystemEntityType.notFound &&
      outputType != FileSystemEntityType.directory) {
    fail('Archive extraction output is not a safe directory');
  }
  if (outputType == FileSystemEntityType.directory) {
    final existingEntries =
        await outputRoot.list(followLinks: false).take(1).toList();
    if (existingEntries.isNotEmpty) {
      fail('Archive extraction output is not empty');
    }
  }

  await _preflightZip(archiveFile, artifact, archiveLength);

  final input = InputFileStream(archiveFile.path);
  Archive? archive;
  try {
    final decoder = ZipDecoder();
    archive = decoder.decodeStream(input);
    final headers = decoder.directory.fileHeaders;
    if (decoder.directory.numberOfThisDisk != 0 ||
        decoder.directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        decoder.directory.totalCentralDirectoryEntriesOnThisDisk !=
            decoder.directory.totalCentralDirectoryEntries ||
        headers.isEmpty ||
        headers.length > maxArchiveEntries ||
        headers.length != archive.length ||
        headers.length != artifact.members.length) {
      fail('Archive directory structure is invalid');
    }

    final expected = {
      for (final member in artifact.members) member.path: member,
    };
    final names = <String>{};
    var declaredTotal = 0;
    for (final header in headers) {
      final local = header.file;
      final name = header.filename;
      validateRelativePath(name, 'archive member');
      if (!names.add(name) ||
          local == null ||
          local.filename != name ||
          local.flags != header.generalPurposeBitFlag ||
          local.crc32 != header.crc32 ||
          local.compressedSize != header.compressedSize ||
          local.uncompressedSize != header.uncompressedSize ||
          header.diskNumberStart != 0 ||
          header.generalPurposeBitFlag & 1 != 0 ||
          header.compressionMethod != 0 && header.compressionMethod != 8) {
        fail('Archive headers or member names are invalid');
      }
      final member = expected[name];
      if (member == null ||
          header.uncompressedSize != member.size ||
          header.uncompressedSize <= 0 ||
          header.uncompressedSize > maxMemberBytes ||
          header.compressedSize <= 0 ||
          header.uncompressedSize >
              header.compressedSize * maxCompressionRatio) {
        fail('Archive member metadata does not match the manifest');
      }
      declaredTotal += header.uncompressedSize;
      if (declaredTotal > maxExpandedBytes) {
        fail('Archive expanded size exceeds the fixed limit');
      }
    }
    if (names.length != expected.length || !names.containsAll(expected.keys)) {
      fail('Archive members do not exactly match the manifest');
    }

    await outputRoot.create();
    await ensureSafeDirectory(
      outputRoot,
      create: false,
      label: 'archive extraction output',
    );
    final digests = <String, String>{};
    var extractedTotal = 0;
    for (final entry in archive) {
      final member = expected[entry.name];
      final modeType = entry.mode & 0xf000;
      if (member == null ||
          !entry.isFile ||
          entry.isSymbolicLink ||
          modeType != 0 && modeType != 0x8000 ||
          entry.size != member.size) {
        fail('Archive contains a non-regular or mismatched member');
      }
      final destination = File(
        resolveInside(
          outputRoot.path,
          entry.name,
          'archive member',
        ),
      );
      await ensureSafeParents(outputRoot, destination.path, 'archive output');
      await destination.parent.create(recursive: true);
      await ensureSafeParents(outputRoot, destination.path, 'archive output');
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        fail('Archive output member already exists');
      }
      final output = _VerifiedFileOutput(
        destination,
        maximumBytes: min(member.size, maxMemberBytes),
      );
      try {
        entry.writeContent(output);
        output.closeSync();
      } on NativeArtifactsException {
        output.abort();
        rethrow;
      } on Object {
        output.abort();
        fail('Archive member decompression failed');
      }
      if (output.length != member.size ||
          output.crc32 != entry.crc32 ||
          output.digest != member.sha256) {
        fail('An extracted member failed checksum or size verification');
      }
      extractedTotal += output.length;
      if (extractedTotal > maxExpandedBytes) {
        fail('Archive expanded size exceeds the fixed limit');
      }
      digests[entry.name] = output.digest;
    }
    if (extractedTotal != declaredTotal) {
      fail('Archive expanded size does not match its metadata');
    }
    return ZipVerificationResult(Map.unmodifiable(digests));
  } on NativeArtifactsException {
    await deleteIfExists(outputRoot);
    rethrow;
  } on Object {
    await deleteIfExists(outputRoot);
    fail('Archive decoding failed');
  } finally {
    if (archive != null) {
      for (final entry in archive) {
        entry.closeSync();
      }
    }
    input.closeSync();
  }
}

Future<void> _preflightZip(
  File archiveFile,
  NativeArtifact artifact,
  int archiveLength,
) async {
  RandomAccessFile? file;
  try {
    file = await archiveFile.open();
    final reader = _ZipReader(file, archiveLength);
    final eocd = await _readEocd(reader);
    final centralBytes =
        await reader.read(eocd.centralOffset, eocd.centralSize);
    final central = ByteData.sublistView(centralBytes);
    final entries = <_RawZipEntry>[];
    final names = <String>{};
    final caseFoldedNames = <String>{};
    var position = 0;
    var expandedTotal = 0;
    for (var index = 0; index < eocd.entryCount; index++) {
      if (position + 46 > centralBytes.length ||
          central.getUint32(position, Endian.little) != 0x02014b50) {
        fail('ZIP central directory is malformed');
      }
      final versionNeeded = central.getUint16(position + 6, Endian.little);
      final flags = central.getUint16(position + 8, Endian.little);
      final method = central.getUint16(position + 10, Endian.little);
      final crc = central.getUint32(position + 16, Endian.little);
      final compressedSize = central.getUint32(position + 20, Endian.little);
      final uncompressedSize = central.getUint32(position + 24, Endian.little);
      final nameLength = central.getUint16(position + 28, Endian.little);
      final extraLength = central.getUint16(position + 30, Endian.little);
      final commentLength = central.getUint16(position + 32, Endian.little);
      final diskStart = central.getUint16(position + 34, Endian.little);
      final externalAttributes =
          central.getUint32(position + 38, Endian.little);
      final localOffset = central.getUint32(position + 42, Endian.little);
      final recordLength = 46 + nameLength + extraLength + commentLength;
      if (nameLength <= 0 ||
          nameLength > maxZipNameBytes ||
          extraLength > maxZipExtraBytes ||
          commentLength > maxZipCommentBytes ||
          position + recordLength > centralBytes.length) {
        fail('ZIP central directory fields exceed the contract bounds');
      }
      final nameBytes = Uint8List.sublistView(
        centralBytes,
        position + 46,
        position + 46 + nameLength,
      );
      final name = _decodeZipPath(nameBytes);
      validateRelativePath(name, 'archive member');
      final extraStart = position + 46 + nameLength;
      _validateExtraField(
        Uint8List.sublistView(
          centralBytes,
          extraStart,
          extraStart + extraLength,
        ),
      );
      _validateRawEntryMetadata(
        versionNeeded: versionNeeded,
        flags: flags,
        method: method,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        diskStart: diskStart,
        externalAttributes: externalAttributes,
        localOffset: localOffset,
      );
      if (!names.add(name) || !caseFoldedNames.add(name.toLowerCase())) {
        fail('ZIP contains duplicate or case-colliding member names');
      }
      expandedTotal += uncompressedSize;
      if (expandedTotal > maxExpandedBytes) {
        fail('Archive expanded size exceeds the fixed limit');
      }
      entries.add(
        _RawZipEntry(
          nameBytes: nameBytes,
          name: name,
          versionNeeded: versionNeeded,
          flags: flags,
          method: method,
          crc: crc,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localOffset: localOffset,
        ),
      );
      position += recordLength;
    }
    if (position != centralBytes.length ||
        entries.length != artifact.members.length) {
      fail('ZIP central directory is not an exact contiguous record set');
    }

    final expected = <String, NativeMember>{
      for (final member in artifact.members) member.path: member,
    };
    for (final entry in entries) {
      final member = expected[entry.name];
      if (member == null || member.size != entry.uncompressedSize) {
        fail('ZIP member metadata does not match the manifest');
      }
      await _readAndValidateLocalHeader(reader, eocd.centralOffset, entry);
    }
    if (!names.containsAll(expected.keys)) {
      fail('ZIP members do not exactly match the manifest');
    }

    entries
        .sort((left, right) => left.localOffset.compareTo(right.localOffset));
    var nextOffset = 0;
    for (final entry in entries) {
      if (entry.localOffset != nextOffset) {
        fail('ZIP local records overlap or contain unreferenced bytes');
      }
      nextOffset = entry.dataEnd;
    }
    if (nextOffset != eocd.centralOffset) {
      fail('ZIP local data does not end at the central directory');
    }
  } on NativeArtifactsException {
    rethrow;
  } on FileSystemException {
    fail('Unable to preflight the native ZIP');
  } finally {
    await file?.close();
  }
}

Future<_RawEocd> _readEocd(_ZipReader reader) async {
  const eocdLength = 22;
  const maximumCommentLength = 0xffff;
  if (reader.length < eocdLength) fail('ZIP end record is missing');
  final tailLength = min(reader.length, eocdLength + maximumCommentLength);
  final tailOffset = reader.length - tailLength;
  final tail = await reader.read(tailOffset, tailLength);
  final data = ByteData.sublistView(tail);
  var eocdInTail = -1;
  for (var position = tailLength - eocdLength; position >= 0; position--) {
    if (data.getUint32(position, Endian.little) != 0x06054b50) continue;
    final commentLength = data.getUint16(position + 20, Endian.little);
    if (position + eocdLength + commentLength != tailLength) continue;
    final candidateOffset = tailOffset + position;
    final centralSize = data.getUint32(position + 12, Endian.little);
    final centralOffset = data.getUint32(position + 16, Endian.little);
    if (centralSize <= 0 || centralOffset + centralSize != candidateOffset) {
      continue;
    }
    if (commentLength != 0) {
      fail('ZIP archive comments are unsupported');
    }
    eocdInTail = position;
    break;
  }
  if (eocdInTail < 0) fail('ZIP end record is invalid');
  final eocdOffset = tailOffset + eocdInTail;
  if (eocdOffset >= 20 &&
      (await reader.uint32(eocdOffset - 20)) == 0x07064b50) {
    fail('ZIP64 archives are outside the native artifact contract');
  }
  final disk = data.getUint16(eocdInTail + 4, Endian.little);
  final centralDisk = data.getUint16(eocdInTail + 6, Endian.little);
  final diskEntries = data.getUint16(eocdInTail + 8, Endian.little);
  final totalEntries = data.getUint16(eocdInTail + 10, Endian.little);
  final centralSize = data.getUint32(eocdInTail + 12, Endian.little);
  final centralOffset = data.getUint32(eocdInTail + 16, Endian.little);
  if (disk != 0 ||
      centralDisk != 0 ||
      diskEntries != totalEntries ||
      totalEntries <= 0 ||
      totalEntries > maxArchiveEntries) {
    fail('ZIP is multi-disk or has an invalid entry count');
  }
  if (totalEntries == 0xffff ||
      centralSize == 0xffffffff ||
      centralOffset == 0xffffffff) {
    fail('ZIP64 archives are outside the native artifact contract');
  }
  if (centralSize <= 0 ||
      centralSize > maxCentralDirectoryBytes ||
      centralOffset + centralSize != eocdOffset) {
    fail('ZIP central directory is outside the contract bounds');
  }
  return _RawEocd(totalEntries, centralOffset, centralSize);
}

void _validateRawEntryMetadata({
  required int versionNeeded,
  required int flags,
  required int method,
  required int compressedSize,
  required int uncompressedSize,
  required int diskStart,
  required int externalAttributes,
  required int localOffset,
}) {
  if (versionNeeded <= 0 || versionNeeded > 20 || diskStart != 0) {
    fail('ZIP version or disk metadata is unsupported');
  }
  // This fixed ZIP feature contract deliberately rejects data descriptors (bit 3)
  // so local CRC and sizes are available for comparison before Archive runs.
  if ((flags & ~0x0806) != 0 || (flags & 0x0001) != 0) {
    fail('ZIP encryption, data descriptors, or flags are unsupported');
  }
  if (method != 0 && method != 8) {
    fail('ZIP compression method is unsupported');
  }
  if (method == 0 && flags & 0x0006 != 0) {
    fail('Stored ZIP entries cannot use deflate option flags');
  }
  if (compressedSize <= 0 ||
      uncompressedSize <= 0 ||
      compressedSize == 0xffffffff ||
      uncompressedSize == 0xffffffff ||
      uncompressedSize > maxMemberBytes ||
      uncompressedSize > compressedSize * maxCompressionRatio ||
      method == 0 && compressedSize != uncompressedSize ||
      localOffset == 0xffffffff) {
    fail('ZIP member sizes are outside the contract limits');
  }
  final unixType = (externalAttributes >> 16) & 0xf000;
  if ((externalAttributes & 0x10) != 0 || unixType != 0 && unixType != 0x8000) {
    fail('ZIP symlink, directory, or special-file modes are unsupported');
  }
}

Future<void> _readAndValidateLocalHeader(
  _ZipReader reader,
  int centralOffset,
  _RawZipEntry entry,
) async {
  if (entry.localOffset < 0 || entry.localOffset + 30 > centralOffset) {
    fail('ZIP local header offset is outside the archive');
  }
  final bytes = await reader.read(entry.localOffset, 30);
  final local = ByteData.sublistView(bytes);
  if (local.getUint32(0, Endian.little) != 0x04034b50) {
    fail('ZIP local header signature is invalid');
  }
  final version = local.getUint16(4, Endian.little);
  final flags = local.getUint16(6, Endian.little);
  final method = local.getUint16(8, Endian.little);
  final crc = local.getUint32(14, Endian.little);
  final compressedSize = local.getUint32(18, Endian.little);
  final uncompressedSize = local.getUint32(22, Endian.little);
  final nameLength = local.getUint16(26, Endian.little);
  final extraLength = local.getUint16(28, Endian.little);
  if (nameLength <= 0 ||
      nameLength > maxZipNameBytes ||
      extraLength > maxZipExtraBytes) {
    fail('ZIP local name or extra field exceeds the contract bounds');
  }
  final dataStart = entry.localOffset + 30 + nameLength + extraLength;
  final dataEnd = dataStart + entry.compressedSize;
  if (dataStart > centralOffset || dataEnd > centralOffset) {
    fail('ZIP compressed member range is outside the local data region');
  }
  final variable =
      await reader.read(entry.localOffset + 30, nameLength + extraLength);
  final localName = Uint8List.sublistView(variable, 0, nameLength);
  _validateExtraField(
    Uint8List.sublistView(variable, nameLength, nameLength + extraLength),
  );
  if (version != entry.versionNeeded ||
      flags != entry.flags ||
      method != entry.method ||
      crc != entry.crc ||
      compressedSize != entry.compressedSize ||
      uncompressedSize != entry.uncompressedSize ||
      !_bytesEqual(localName, entry.nameBytes)) {
    fail('ZIP local and central headers do not match');
  }
  entry.dataEnd = dataEnd;
}

String _decodeZipPath(Uint8List bytes) {
  if (bytes.any((byte) => byte < 0x20 || byte > 0x7e)) {
    fail('ZIP member names must use normalized printable UTF-8 paths');
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    fail('ZIP member name is not valid UTF-8');
  }
}

void _validateExtraField(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var position = 0;
  while (position < bytes.length) {
    if (position + 4 > bytes.length) fail('ZIP extra field is malformed');
    final identifier = data.getUint16(position, Endian.little);
    final length = data.getUint16(position + 2, Endian.little);
    position += 4;
    if (position + length > bytes.length) fail('ZIP extra field is malformed');
    if (identifier == 0x0001) {
      fail('ZIP64 extra fields are outside the native artifact contract');
    }
    position += length;
  }
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _ZipReader {
  _ZipReader(this.file, this.length);

  final RandomAccessFile file;
  final int length;

  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) {
      fail('ZIP read range is outside the archive');
    }
    await file.setPosition(offset);
    final bytes = await file.read(count);
    if (bytes.length != count) fail('ZIP ended inside a declared record');
    return Uint8List.fromList(bytes);
  }

  Future<int> uint32(int offset) async =>
      ByteData.sublistView(await read(offset, 4)).getUint32(0, Endian.little);
}

final class _RawEocd {
  const _RawEocd(this.entryCount, this.centralOffset, this.centralSize);

  final int entryCount;
  final int centralOffset;
  final int centralSize;
}

final class _RawZipEntry {
  _RawZipEntry({
    required this.nameBytes,
    required this.name,
    required this.versionNeeded,
    required this.flags,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
  });

  final Uint8List nameBytes;
  final String name;
  final int versionNeeded;
  final int flags;
  final int method;
  final int crc;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
  int dataEnd = -1;
}

final class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

final class _VerifiedFileOutput extends OutputStream {
  _VerifiedFileOutput(this.file, {required this.maximumBytes})
      : _handle = file.openSync(mode: FileMode.write),
        _digestCapture = _DigestCapture(),
        super(byteOrder: ByteOrder.littleEndian) {
    _hashSink = sha256.startChunkedConversion(_digestCapture);
  }

  final File file;
  final int maximumBytes;
  final RandomAccessFile _handle;
  final _DigestCapture _digestCapture;
  late final ByteConversionSink _hashSink;
  var _length = 0;
  var _crc = 0xffffffff;
  var _open = true;

  @override
  int get length => _length;

  int get crc32 => (_crc ^ 0xffffffff) & 0xffffffff;

  String get digest => _digestCapture.value?.toString() ?? '';

  @override
  bool get isOpen => _open;

  @override
  void clear() => fail('Clearing an extraction stream is forbidden');

  @override
  void flush() => _handle.flushSync();

  @override
  void writeByte(int value) => writeBytes([value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (!_open ||
        count < 0 ||
        count > bytes.length ||
        _length + count > maximumBytes) {
      fail('Archive output exceeds its member limit');
    }
    final chunk = count == bytes.length ? bytes : bytes.sublist(0, count);
    _handle.writeFromSync(chunk);
    _hashSink.add(chunk);
    for (final byte in chunk) {
      var current = (_crc ^ byte) & 0xff;
      for (var bit = 0; bit < 8; bit++) {
        current =
            (current & 1) != 0 ? (current >> 1) ^ 0xedb88320 : current >> 1;
      }
      _crc = (_crc >> 8) ^ current;
    }
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final count = min(stream.length, 64 * 1024);
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('Extraction streams cannot be read back');

  @override
  void closeSync() {
    if (!_open) return;
    _hashSink.close();
    _handle.flushSync();
    _handle.closeSync();
    _open = false;
  }

  void abort() {
    if (_open) {
      _handle.closeSync();
      _open = false;
    }
    if (file.existsSync()) file.deleteSync();
  }
}
