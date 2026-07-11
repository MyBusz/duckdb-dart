import 'dart:io';

import 'package:path/path.dart' as path;

import 'cache.dart';
import 'checksums.dart';
import 'errors.dart';
import 'inspector.dart';
import 'io_utils.dart';
import 'manifest.dart';

Future<void> installArtifact(
  CachedArtifact cached,
  Directory packageRoot,
) async {
  final artifact = cached.artifact;
  await ensureSafeDirectory(
    packageRoot,
    create: false,
    label: 'package root',
  );
  final installRoot = installRootForTarget(artifact.target);
  final targetPath = resolveInside(
    packageRoot.path,
    installRoot,
    'install root',
  );
  await ensureSafeParents(packageRoot, targetPath, 'install root');
  final target = Directory(targetPath);
  await target.parent.create(recursive: true);
  await ensureSafeParents(packageRoot, targetPath, 'install root');
  final stage = await createUniqueDirectory(
    target.parent,
    '.${path.basename(targetPath)}.stage-',
    'install staging parent',
  );
  Directory? backupRoot;
  Directory? backup;
  var promoted = false;
  var completed = false;
  try {
    for (final member in artifact.members) {
      final relative = path.posix.relative(
        member.installDestination,
        from: installRoot,
      );
      validateRelativePath(relative, 'install destination');
      final source = File(
        resolveInside(
          cached.extractedDirectory.path,
          member.path,
          'extracted member',
        ),
      );
      final destination = File(
        resolveInside(
          stage.path,
          relative,
          'staged install destination',
        ),
      );
      await ensureSafeParents(
        stage,
        destination.path,
        'staged install destination',
      );
      await destination.parent.create(recursive: true);
      await ensureSafeParents(
        stage,
        destination.path,
        'staged install destination',
      );
      await copyVerified(
        source,
        destination,
        expectedSize: member.size,
        expectedSha256: member.sha256,
      );
    }

    final existing = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (existing != FileSystemEntityType.notFound) {
      if (existing != FileSystemEntityType.directory) {
        fail('The native install root is not a directory');
      }
      backupRoot = await createUniqueDirectory(
        target.parent,
        '.${path.basename(targetPath)}.old-',
        'install staging parent',
      );
      backup = Directory('${backupRoot.path}${Platform.pathSeparator}previous');
      await ensureSafeParents(packageRoot, targetPath, 'install root');
      await target.rename(backup.path);
    }
    try {
      await ensureSafeParents(packageRoot, targetPath, 'install root');
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        fail('The native install root changed before promotion');
      }
      await stage.rename(target.path);
      promoted = true;
    } on Object {
      if (backup != null && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    await verifyInstalledArtifact(artifact, packageRoot);
    if (backupRoot != null) await deleteIfExists(backupRoot);
    completed = true;
  } finally {
    await deleteIfExists(stage);
    if (!completed && promoted) {
      await deleteIfExists(target);
      if (backup != null && await backup.exists()) {
        await backup.rename(target.path);
      }
    } else if (!completed &&
        backup != null &&
        await backup.exists() &&
        !await target.exists()) {
      await backup.rename(target.path);
    }
    if (backupRoot != null) await deleteIfExists(backupRoot);
  }
}

Future<void> verifyInstalledArtifact(
  NativeArtifact artifact,
  Directory packageRoot,
) async {
  await ensureSafeDirectory(
    packageRoot,
    create: false,
    label: 'package root',
  );
  for (final member in artifact.members) {
    final destinationPath = resolveInside(
      packageRoot.path,
      member.installDestination,
      'installed member',
    );
    await ensureSafeParents(packageRoot, destinationPath, 'installed member');
    await verifyAssetFile(
      File(destinationPath),
      member.size,
      member.sha256,
      'Installed native member',
    );
  }
}
