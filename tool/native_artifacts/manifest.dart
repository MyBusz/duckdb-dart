import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'companions.dart';
import 'errors.dart';
import 'inspector.dart';
import 'schema_validator.dart';

const maxManifestBytes = 1024 * 1024;
const maxSchemaBytes = 1024 * 1024;

const requiredBuildToolNames = <String>[
  'cmake',
  'ninja',
  'linux-clang',
  'xcode',
  'apple-clang',
  'visual-studio',
  'msvc',
];

const requiredLicenses = <Map<String, String>>[
  <String, String>{'path': 'LICENSE', 'identifier': 'MIT'},
  <String, String>{
    'path': 'licenses/duckdb/LICENSE',
    'identifier': 'MIT',
  },
];

final class NativeManifest {
  NativeManifest._(this.json, this.bytes, this.sha256, this.artifacts);

  final Map<String, Object?> json;
  final List<int> bytes;
  final String sha256;
  final List<NativeArtifact> artifacts;

  String get sourceCommit => json['sourceCommit']! as String;

  String get manifestReleaseTag => json['releaseTag']! as String;

  NativeArtifact artifactFor(String target) {
    for (final artifact in artifacts) {
      if (artifact.target == target) return artifact;
    }
    fail('Unknown native target "$target"');
  }

  static Future<NativeManifest> load(
    File file, {
    required File schemaFile,
  }) async {
    try {
      final manifestBytes = await _readContract(file, maxManifestBytes);
      final schemaBytes = await _readContract(schemaFile, maxSchemaBytes);
      rejectDuplicateJsonKeys(manifestBytes, 'manifest');
      rejectDuplicateJsonKeys(schemaBytes, 'schema');
      final decoded = jsonDecode(utf8.decode(manifestBytes));
      final decodedSchema = jsonDecode(utf8.decode(schemaBytes));
      if (decoded is! Map<String, Object?> ||
          decodedSchema is! Map<String, Object?>) {
        fail('The native artifact manifest or schema is not a JSON object');
      }
      JsonSchemaValidator(decodedSchema).validate(decoded);
      final result = NativeManifest._(
        decoded,
        manifestBytes,
        crypto.sha256.convert(manifestBytes).toString(),
        (decoded['artifacts']! as List<Object?>)
            .map(
              (value) =>
                  NativeArtifact.fromJson(value! as Map<String, Object?>),
            )
            .toList(growable: false),
      );
      result._validateDomain();
      return result;
    } on NativeArtifactsException {
      rethrow;
    } on FileSystemException {
      fail('Unable to read the native artifact manifest contract');
    } on FormatException {
      fail('The native artifact manifest is not valid JSON');
    }
  }

  void _validateDomain() {
    if (manifestReleaseTag != releaseTag || json['coreCommit'] != coreCommit) {
      fail('The native release identity is invalid');
    }
    if (artifacts.length != archiveNamesByTarget.length) {
      fail('The manifest does not contain the exact native target set');
    }
    final toolchains = json['toolchains']! as Map<String, Object?>;
    final buildTools = (toolchains['buildTools']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final toolNames = buildTools
        .map((tool) => tool['name']! as String)
        .toList(growable: false);
    if (toolNames.length != requiredBuildToolNames.length) {
      fail('The manifest does not contain the exact native build tools');
    }
    for (var index = 0; index < requiredBuildToolNames.length; index++) {
      if (toolNames[index] != requiredBuildToolNames[index]) {
        fail('The manifest native build tools are not in contract order');
      }
    }
    final licenses =
        (json['licenses']! as List<Object?>).cast<Map<String, Object?>>();
    if (licenses.length != requiredLicenses.length) {
      fail('The manifest does not contain the exact license records');
    }
    for (var index = 0; index < requiredLicenses.length; index++) {
      if (licenses[index]['path'] != requiredLicenses[index]['path'] ||
          licenses[index]['identifier'] !=
              requiredLicenses[index]['identifier']) {
        fail('The manifest contains an invalid license record');
      }
    }
    for (var index = 0; index < artifacts.length; index++) {
      final target = archiveNamesByTarget.keys.elementAt(index);
      final artifact = artifacts[index];
      if (artifact.target != target ||
          artifact.fileName != archiveNamesByTarget[target]) {
        fail('Native artifacts are not in contract order');
      }
      validateMemberMappings(artifact);
    }
  }
}

final class NativeArtifact {
  NativeArtifact._({
    required this.json,
    required this.target,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.members,
  });

  factory NativeArtifact.fromJson(Map<String, Object?> json) =>
      NativeArtifact._(
        json: json,
        target: json['target']! as String,
        fileName: json['fileName']! as String,
        size: json['size']! as int,
        sha256: json['sha256']! as String,
        members: (json['members']! as List<Object?>)
            .map(
              (value) => NativeMember.fromJson(
                value! as Map<String, Object?>,
              ),
            )
            .toList(growable: false),
      );

  final Map<String, Object?> json;
  final String target;
  final String fileName;
  final int size;
  final String sha256;
  final List<NativeMember> members;
}

final class NativeMember {
  NativeMember._({
    required this.path,
    required this.size,
    required this.sha256,
    required this.installDestination,
  });

  factory NativeMember.fromJson(Map<String, Object?> json) => NativeMember._(
        path: json['path']! as String,
        size: json['size']! as int,
        sha256: json['sha256']! as String,
        installDestination: json['installDestination']! as String,
      );

  final String path;
  final int size;
  final String sha256;
  final String installDestination;
}

Future<List<int>> _readContract(File file, int maximum) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    fail('The native artifact contract is not a regular file');
  }
  if (await file.length() > maximum) {
    fail('The native artifact contract exceeds its size limit');
  }
  return file.readAsBytes();
}

void rejectDuplicateJsonKeys(List<int> bytes, String label) {
  final text = utf8.decode(bytes);
  final stack = <_JsonContext>[];
  var index = 0;
  while (index < text.length) {
    final code = text.codeUnitAt(index);
    if (code == 0x22) {
      final start = index++;
      var escaped = false;
      while (index < text.length) {
        final current = text.codeUnitAt(index++);
        if (escaped) {
          escaped = false;
        } else if (current == 0x5c) {
          escaped = true;
        } else if (current == 0x22) {
          break;
        }
      }
      if (index > text.length || text.codeUnitAt(index - 1) != 0x22) return;
      if (stack.isNotEmpty && stack.last.object && stack.last.expectingKey) {
        var cursor = index;
        while (cursor < text.length && _isWhitespace(text.codeUnitAt(cursor))) {
          cursor++;
        }
        if (cursor < text.length && text.codeUnitAt(cursor) == 0x3a) {
          final key = jsonDecode(text.substring(start, index))! as String;
          if (!stack.last.keys.add(key)) {
            fail('The $label contains a duplicate key');
          }
          stack.last.expectingKey = false;
        }
      }
      continue;
    }
    if (code == 0x7b) stack.add(_JsonContext.object());
    if (code == 0x5b) stack.add(_JsonContext.array());
    if ((code == 0x7d || code == 0x5d) && stack.isNotEmpty) stack.removeLast();
    if (code == 0x2c && stack.isNotEmpty && stack.last.object) {
      stack.last.expectingKey = true;
    }
    index++;
  }
}

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

final class _JsonContext {
  _JsonContext.object()
      : object = true,
        expectingKey = true;
  _JsonContext.array()
      : object = false,
        expectingKey = false;

  final bool object;
  bool expectingKey;
  final Set<String> keys = <String>{};
}
