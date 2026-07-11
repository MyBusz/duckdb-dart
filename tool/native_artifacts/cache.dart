import 'dart:io';

import 'checksums.dart';
import 'companions.dart';
import 'errors.dart';
import 'inspector.dart';
import 'io_utils.dart';
import 'manifest.dart';
import 'zip.dart';

final class CachedArtifact {
  const CachedArtifact({
    required this.directory,
    required this.manifest,
    required this.artifact,
    required this.extractedDirectory,
  });

  final Directory directory;
  final NativeManifest manifest;
  final NativeArtifact artifact;
  final Directory extractedDirectory;
}

final class NativeArtifactCache {
  NativeArtifactCache({required this.root, required this.schemaFile});

  final Directory root;
  final File schemaFile;

  Directory targetDirectory(String target) => Directory(
        '${root.path}${Platform.pathSeparator}$releaseTag${Platform.pathSeparator}$target',
      );

  Future<void> store(
    NativeManifest manifest,
    NativeArtifact artifact,
    ValidatedAssets assets,
  ) async {
    await ensureSafeDirectory(root, create: true, label: 'cache root');
    final releaseRoot = Directory(
      '${root.path}${Platform.pathSeparator}$releaseTag',
    );
    await ensureSafeDirectory(
      releaseRoot,
      create: true,
      label: 'release cache root',
    );
    final destination = targetDirectory(artifact.target);
    final stage = await createUniqueDirectory(
      releaseRoot,
      '.${artifact.target}.stage-',
      'release cache root',
    );
    Directory? backupRoot;
    Directory? backup;
    try {
      await copyVerified(
        assets.file('assets.lock.json'),
        File('${stage.path}${Platform.pathSeparator}assets.lock.json'),
        expectedSize: manifest.bytes.length,
        expectedSha256: manifest.sha256,
      );
      await copyVerified(
        assets.file('SHA256SUMS'),
        File('${stage.path}${Platform.pathSeparator}SHA256SUMS'),
        expectedSize: assets.sumsSize,
        expectedSha256: assets.sumsSha256,
      );
      await copyVerified(
        assets.file(artifact.fileName),
        File('${stage.path}${Platform.pathSeparator}${artifact.fileName}'),
        expectedSize: artifact.size,
        expectedSha256: artifact.sha256,
      );
      final existing = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (existing != FileSystemEntityType.notFound) {
        if (existing != FileSystemEntityType.directory) {
          fail('The cache target is not a directory');
        }
        backupRoot = await createUniqueDirectory(
          releaseRoot,
          '.${artifact.target}.old-',
          'release cache root',
        );
        backup = Directory(
          '${backupRoot.path}${Platform.pathSeparator}previous',
        );
        await ensureSafeDirectory(
          releaseRoot,
          create: false,
          label: 'release cache root',
        );
        await destination.rename(backup.path);
      }
      try {
        await ensureSafeDirectory(
          releaseRoot,
          create: false,
          label: 'release cache root',
        );
        if (await FileSystemEntity.type(
              destination.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          fail('The cache target changed before promotion');
        }
        await stage.rename(destination.path);
      } on Object {
        if (backup != null && await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
      if (backupRoot != null) await deleteIfExists(backupRoot);
    } finally {
      await deleteIfExists(stage);
      if (backup != null &&
          await backup.exists() &&
          !await destination.exists()) {
        await backup.rename(destination.path);
      }
      if (backupRoot != null) await deleteIfExists(backupRoot);
    }
  }

  Future<CachedArtifact> verify(String target) async {
    if (!archiveNamesByTarget.containsKey(target)) {
      fail('Unknown native target "$target"');
    }
    await ensureSafeDirectory(root, create: false, label: 'cache root');
    final directory = targetDirectory(target);
    await ensureSafeDirectory(
      directory,
      create: false,
      label: 'cached native artifact',
    );
    final manifest = await NativeManifest.load(
      File('${directory.path}${Platform.pathSeparator}assets.lock.json'),
      schemaFile: schemaFile,
    );
    final artifact = manifest.artifactFor(target);
    final assets =
        await validateSelectedDownload(manifest, artifact, directory);
    final extracted = await createUniqueDirectory(
      root,
      '.verify-$target-',
      'cache root',
    );
    try {
      await verifyAndExtractZip(
        assets.file(artifact.fileName),
        artifact,
        extracted,
      );
      return CachedArtifact(
        directory: directory,
        manifest: manifest,
        artifact: artifact,
        extractedDirectory: extracted,
      );
    } on Object {
      await deleteIfExists(extracted);
      rethrow;
    }
  }
}
