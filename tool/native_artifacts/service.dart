import 'dart:io';

import 'cache.dart';
import 'checksums.dart';
import 'companions.dart';
import 'errors.dart';
import 'inspector.dart';
import 'install.dart';
import 'io_utils.dart';
import 'manifest.dart';
import 'trust.dart';
import 'zip.dart';

final class NativeArtifactsService {
  NativeArtifactsService({
    required this.schemaFile,
    ImmutableReleaseDownloader? releaseDownloader,
  }) : releaseDownloader = releaseDownloader ?? GhImmutableReleaseDownloader();

  final File schemaFile;
  final ImmutableReleaseDownloader releaseDownloader;

  Future<NativeManifest> loadManifest(File file) =>
      NativeManifest.load(file, schemaFile: schemaFile);

  Future<void> seedLocalCandidate({
    required Directory releaseDirectory,
    required Directory cacheDirectory,
  }) async {
    await ensureSafeDirectory(
      releaseDirectory,
      create: false,
      label: 'local release directory',
    );
    await ensureSafeDirectory(
      cacheDirectory,
      create: true,
      label: 'cache root',
    );
    final manifest = await loadManifest(
      File('${releaseDirectory.path}${Platform.pathSeparator}assets.lock.json'),
    );
    final assets = await validateLocalRelease(manifest, releaseDirectory);

    final validationRoots = <Directory>[];
    try {
      for (final artifact in manifest.artifacts) {
        final output = await createUniqueDirectory(
          cacheDirectory,
          '.candidate-${artifact.target}-',
          'cache root',
        );
        validationRoots.add(output);
        await verifyAndExtractZip(
          assets.file(artifact.fileName),
          artifact,
          output,
        );
      }
    } finally {
      for (final directory in validationRoots) {
        await deleteIfExists(directory);
      }
    }

    final cache = NativeArtifactCache(
      root: cacheDirectory,
      schemaFile: schemaFile,
    );
    for (final artifact in manifest.artifacts) {
      await cache.store(manifest, artifact, assets);
    }
  }

  Future<void> fetchPublished({
    required String target,
    required Directory cacheDirectory,
  }) async {
    final archiveName = archiveNamesByTarget[target];
    if (archiveName == null) fail('Unknown native target "$target"');
    await ensureSafeDirectory(
      cacheDirectory,
      create: true,
      label: 'cache root',
    );
    final download = await createUniqueDirectory(
      cacheDirectory,
      '.download-$target-',
      'cache root',
    );
    try {
      await releaseDownloader.download(
        repository: releaseRepository,
        tag: releaseTag,
        archiveName: archiveName,
        destination: download,
      );
      final manifest = await loadManifest(
        File('${download.path}${Platform.pathSeparator}assets.lock.json'),
      );
      final artifact = manifest.artifactFor(target);
      if (artifact.fileName != archiveName) {
        fail('The downloaded manifest selected the wrong archive');
      }
      final assets = await validateSelectedDownload(
        manifest,
        artifact,
        download,
      );
      final extracted = await createUniqueDirectory(
        cacheDirectory,
        '.download-verify-$target-',
        'cache root',
      );
      try {
        await verifyAndExtractZip(
          assets.file(artifact.fileName),
          artifact,
          extracted,
        );
      } finally {
        await deleteIfExists(extracted);
      }
      await NativeArtifactCache(
        root: cacheDirectory,
        schemaFile: schemaFile,
      ).store(manifest, artifact, assets);
    } finally {
      await deleteIfExists(download);
    }
  }

  Future<void> verifyCacheOffline({
    required String target,
    required Directory cacheDirectory,
  }) async {
    final cached = await NativeArtifactCache(
      root: cacheDirectory,
      schemaFile: schemaFile,
    ).verify(target);
    await deleteIfExists(cached.extractedDirectory);
  }

  Future<void> installOffline({
    required String target,
    required Directory cacheDirectory,
    required Directory packageRoot,
  }) async {
    final cached = await NativeArtifactCache(
      root: cacheDirectory,
      schemaFile: schemaFile,
    ).verify(target);
    try {
      await installArtifact(cached, packageRoot);
    } finally {
      await deleteIfExists(cached.extractedDirectory);
    }
  }
}
