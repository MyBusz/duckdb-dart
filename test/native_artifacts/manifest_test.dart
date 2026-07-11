import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_artifacts/companions.dart';
import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/manifest.dart';
import 'fixture.dart';

void main() {
  final schema = File('native/native-artifacts.schema.json');
  late Directory scratch;

  setUp(() {
    scratch = Directory('.dart_tool/native-artifacts-manifest-test')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('defines the exact seven release assets', () {
    expect(releaseAssetNames, <String>[
      'duckdb-android-arm64-v8a-x86_64.zip',
      'duckdb-ios-xcframework.zip',
      'duckdb-macos-universal.zip',
      'duckdb-linux-x86_64.zip',
      'duckdb-windows-x64.zip',
      'assets.lock.json',
      'SHA256SUMS',
    ]);
    expect(checksumEntryNames, releaseAssetNames.sublist(0, 6));
  });

  test('loads the minimal five-target manifest', () async {
    final fixture = await createNativeFixture(scratch);
    final manifest = await NativeManifest.load(
      fixture.manifestFile,
      schemaFile: schema,
    );
    expect(manifest.artifacts.map((value) => value.target), <String>[
      'android',
      'ios',
      'macos',
      'linux',
      'windows',
    ]);
    final toolchains = manifest.json['toolchains']! as Map<String, Object?>;
    final tools = toolchains['buildTools']! as List<Object?>;
    expect(tools[4], <String, Object?>{
      'name': 'linux-clang',
      'version': '14.0.0',
    });
  });

  test('accepts the selected Linux Clang version as release data', () async {
    final json = syntheticManifest();
    final toolchains = json['toolchains']! as Map<String, Object?>;
    final tools = toolchains['buildTools']! as List<Object?>;
    (tools[4]! as Map<String, Object?>)['version'] = '19.1.7';
    final file = File('${scratch.path}/linux-clang-version.json')
      ..writeAsStringSync(jsonEncode(json));
    final manifest = await NativeManifest.load(file, schemaFile: schema);
    expect(
      ((manifest.json['toolchains']! as Map<String, Object?>)['buildTools']!
          as List<Object?>)[4],
      <String, Object?>{'name': 'linux-clang', 'version': '19.1.7'},
    );
  });

  for (final mutation in <String, void Function(Map<String, Object?>)>{
    'unknown metadata': (json) => json['extra'] = true,
    'missing metadata': (json) => json.remove('toolchains'),
    'missing licenses': (json) => json.remove('licenses'),
    'wrong wrapper license': (json) {
      final licenses = json['licenses']! as List<Object?>;
      (licenses.first! as Map<String, Object?>)['identifier'] = 'BSD-3-Clause';
    },
    'extra license': (json) => (json['licenses']! as List<Object?>).add(
          <String, Object?>{'path': 'other', 'identifier': 'MIT'},
        ),
    'missing build tool': (json) {
      final toolchains = json['toolchains']! as Map<String, Object?>;
      (toolchains['buildTools']! as List<Object?>).removeLast();
    },
    'wrong build tool identity': (json) {
      final toolchains = json['toolchains']! as Map<String, Object?>;
      final tools = toolchains['buildTools']! as List<Object?>;
      (tools[4]! as Map<String, Object?>)['name'] = 'arbitrary-compiler';
    },
    'wrong release': (json) => json['releaseTag'] = 'other',
    'wrong source type': (json) => json['sourceCommit'] = 1,
    'extra artifact': (json) =>
        (json['artifacts']! as List<Object?>).add(<String, Object?>{}),
    'missing artifact': (json) =>
        (json['artifacts']! as List<Object?>).removeLast(),
    'wrong platform mapping': (json) {
      final artifact =
          (json['artifacts']! as List<Object?>).first! as Map<String, Object?>;
      final platforms = artifact['supportedPlatforms']! as List<Object?>;
      final platform = platforms.first! as Map<String, Object?>;
      platform['architectures'] = ['arm64-v8a'];
    },
    'escaping install destination': (json) {
      final artifact =
          (json['artifacts']! as List<Object?>).first! as Map<String, Object?>;
      final members = artifact['members']! as List<Object?>;
      final member = members.first! as Map<String, Object?>;
      member['installDestination'] = '../libduckdb.so';
    },
    'missing required member': (json) {
      final artifacts = json['artifacts']! as List<Object?>;
      final android = artifacts.first! as Map<String, Object?>;
      (android['members']! as List<Object?>).removeLast();
    },
    'wrong required member': (json) {
      final artifacts = json['artifacts']! as List<Object?>;
      final linux = artifacts[3]! as Map<String, Object?>;
      final members = linux['members']! as List<Object?>;
      final member = members.first! as Map<String, Object?>;
      member
        ..['path'] = 'other.so'
        ..['installDestination'] = 'linux/Libraries/release/other.so';
    },
    'duplicate required member': (json) {
      final artifacts = json['artifacts']! as List<Object?>;
      final android = artifacts.first! as Map<String, Object?>;
      final members = android['members']! as List<Object?>;
      members[1] = jsonDecode(jsonEncode(members.first));
    },
  }.entries) {
    test('rejects ${mutation.key}', () async {
      final json = syntheticManifest();
      mutation.value(json);
      final file = File('${scratch.path}/bad.json')
        ..writeAsStringSync(jsonEncode(json));
      await expectLater(
        NativeManifest.load(file, schemaFile: schema),
        throwsA(isA<NativeArtifactsException>()),
      );
    });
  }

  test('allows additional exact members after the essential members', () async {
    final json = syntheticManifest();
    final artifacts = json['artifacts']! as List<Object?>;
    final ios = artifacts[1]! as Map<String, Object?>;
    (ios['members']! as List<Object?>).add(
      memberJson(
        'ios',
        'duckdb.xcframework/ios-arm64/duckdb.framework/Info.plist',
      ),
    );
    final file = File('${scratch.path}/additional.json')
      ..writeAsStringSync(jsonEncode(json));
    final manifest = await NativeManifest.load(file, schemaFile: schema);
    expect(manifest.artifactFor('ios').members, hasLength(4));
  });

  test('rejects duplicate JSON keys', () async {
    final file = File('${scratch.path}/duplicate.json')
      ..writeAsStringSync('{"schemaVersion":1,"schemaVersion":1}');
    await expectLater(
      NativeManifest.load(file, schemaFile: schema),
      throwsA(isA<NativeArtifactsException>()),
    );
  });
}
