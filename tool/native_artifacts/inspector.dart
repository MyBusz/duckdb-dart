import 'dart:io';

import 'package:path/path.dart' as path;

import 'errors.dart';
import 'manifest.dart';

const requiredMemberPathsByTarget = <String, List<String>>{
  'android': <String>[
    'arm64-v8a/libduckdb.so',
    'x86_64/libduckdb.so',
  ],
  'ios': <String>[
    'duckdb.xcframework/Info.plist',
    'duckdb.xcframework/ios-arm64/duckdb.framework/duckdb',
    'duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb',
  ],
  'macos': <String>['libduckdb.dylib'],
  'linux': <String>['libduckdb.so'],
  'windows': <String>['duckdb.dll'],
};

const requiredPlatformsByTarget = <String, Map<String, List<String>>>{
  'android': <String, List<String>>{
    'android': <String>['arm64-v8a', 'x86_64'],
  },
  'ios': <String, List<String>>{
    'ios': <String>['arm64'],
    'ios-simulator': <String>['arm64', 'x86_64'],
  },
  'macos': <String, List<String>>{
    'macos': <String>['x86_64', 'arm64'],
  },
  'linux': <String, List<String>>{
    'linux': <String>['x86_64'],
  },
  'windows': <String, List<String>>{
    'windows': <String>['x64'],
  },
};

void validateMemberMappings(NativeArtifact artifact) {
  final installRoot = installRootForTarget(artifact.target);
  final memberPaths = <String>{};
  final caseFoldedMemberPaths = <String>{};
  final destinations = <String>{};
  final caseFoldedDestinations = <String>{};
  for (final member in artifact.members) {
    validateRelativePath(member.path, 'archive member');
    validateRelativePath(member.installDestination, 'install destination');
    if (!memberPaths.add(member.path) ||
        !caseFoldedMemberPaths.add(member.path.toLowerCase()) ||
        !destinations.add(member.installDestination) ||
        !caseFoldedDestinations.add(member.installDestination.toLowerCase())) {
      fail('The manifest contains duplicate member paths or destinations');
    }
    final expected = '$installRoot/${member.path}';
    if (member.installDestination != expected) {
      fail('An install destination does not match its archive member');
    }
  }
  final requiredMembers = requiredMemberPathsByTarget[artifact.target];
  if (requiredMembers == null || !memberPaths.containsAll(requiredMembers)) {
    fail('The manifest is missing a required native member');
  }

  final platformValues = (artifact.json['supportedPlatforms']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final actualPlatforms = <String, Set<String>>{};
  for (final platform in platformValues) {
    final name = platform['platform']! as String;
    final architectures =
        (platform['architectures']! as List<Object?>).cast<String>();
    actualPlatforms.putIfAbsent(name, () => <String>{}).addAll(architectures);
  }
  final requiredPlatforms = requiredPlatformsByTarget[artifact.target]!;
  if (actualPlatforms.length != requiredPlatforms.length) {
    fail('The manifest platform records do not match the native members');
  }
  for (final platform in requiredPlatforms.entries) {
    final actual = actualPlatforms[platform.key];
    if (actual == null ||
        actual.length != platform.value.length ||
        !actual.containsAll(platform.value)) {
      fail('The manifest architectures do not match the required members');
    }
  }
}

void validateRelativePath(String value, String label) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      RegExp('^[A-Za-z]:').hasMatch(value)) {
    fail('The $label path is unsafe');
  }
  final segments = value.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    fail('The $label path is unsafe');
  }
}

String installRootForTarget(String target) => switch (target) {
      'android' => 'android/src/main/jniLibs',
      'ios' => 'ios/Libraries/release',
      'macos' => 'macos/Libraries/release',
      'linux' => 'linux/Libraries/release',
      'windows' => 'windows/Libraries/release',
      _ => fail('Unknown native target'),
    };

String resolveInside(String root, String relative, String label) {
  validateRelativePath(relative.replaceAll(path.separator, '/'), label);
  final absoluteRoot = path.normalize(path.absolute(root));
  final resolved = path.normalize(
    path.joinAll(<String>[
      absoluteRoot,
      ...relative.split('/'),
    ]),
  );
  if (!path.isWithin(absoluteRoot, resolved)) {
    fail('The $label path escapes its root');
  }
  return resolved;
}

Future<void> ensureSafeDirectory(
  Directory directory, {
  required bool create,
  required String label,
}) async {
  final absolute = path.normalize(path.absolute(directory.path));
  var current = path.rootPrefix(absolute);
  for (final segment in path.split(absolute)) {
    if (segment.isEmpty || segment == path.rootPrefix(absolute)) continue;
    current = path.join(current, segment);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link) fail('The $label path is symlinked');
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      fail('The $label path contains a non-directory component');
    }
  }
  if (create) await Directory(absolute).create(recursive: true);
  if (await FileSystemEntity.type(absolute, followLinks: false) !=
      FileSystemEntityType.directory) {
    fail('The $label is missing, symlinked, or not a directory');
  }
}

Future<void> ensureSafeParents(
  Directory root,
  String destinationPath,
  String label,
) async {
  final rootPath = path.normalize(path.absolute(root.path));
  final parentPath =
      path.normalize(path.absolute(path.dirname(destinationPath)));
  if (!path.equals(rootPath, parentPath) &&
      !path.isWithin(rootPath, parentPath)) {
    fail('The $label path escapes its root');
  }
  await ensureSafeDirectory(root, create: false, label: label);
  var current = rootPath;
  final relative = path.relative(parentPath, from: rootPath);
  if (relative == '.') return;
  for (final segment in path.split(relative)) {
    current = path.join(current, segment);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link) fail('The $label path is symlinked');
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      fail('The $label path contains a non-directory component');
    }
  }
}

Future<Directory> createUniqueDirectory(
  Directory parent,
  String prefix,
  String label,
) async {
  await ensureSafeDirectory(parent, create: true, label: label);
  final directory = await parent.createTemp(prefix);
  await ensureSafeDirectory(parent, create: false, label: label);
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    fail('The $label temporary directory is not a directory');
  }
  return directory;
}
