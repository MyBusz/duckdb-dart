import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_artifacts/cache.dart';
import '../../tool/native_artifacts/companions.dart';
import '../../tool/native_artifacts/errors.dart';
import '../../tool/native_artifacts/install.dart';
import '../../tool/native_artifacts/service.dart';
import 'fixture.dart';

void main() {
  final schema = File('native/native-artifacts.schema.json');
  late Directory scratch;

  setUp(() {
    scratch = Directory('.dart_tool/native-artifacts-bootstrap-test')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('local candidate seed validates and caches all five targets', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    for (final target in archiveNamesByTarget.keys) {
      expect(
        Directory(
          '${fixture.cacheDirectory.path}/$releaseTag/$target',
        ).existsSync(),
        isTrue,
      );
      await service.verifyCacheOffline(
        target: target,
        cacheDirectory: fixture.cacheDirectory,
      );
    }
  });

  test('public fetch accepts an immutable exact release', () async {
    final fixture = await createNativeFixture(scratch);
    final downloader = FakeReleaseDownloader(fixture.releaseDirectory);
    final service = NativeArtifactsService(
      schemaFile: schema,
      releaseDownloader: downloader,
    );
    await service.fetchPublished(
      target: 'linux',
      cacheDirectory: fixture.cacheDirectory,
    );
    expect(downloader.calls, 1);
    expect(
      Directory(
        '${fixture.cacheDirectory.path}/$releaseTag/linux',
      ).listSync().map((entity) => entity.uri.pathSegments.last),
      containsAll(<String>[
        'assets.lock.json',
        'SHA256SUMS',
        'duckdb-linux-x86_64.zip',
      ]),
    );
  });

  test('public fetch rejects a release not reported immutable', () async {
    final fixture = await createNativeFixture(scratch);
    final downloader = FakeReleaseDownloader(
      fixture.releaseDirectory,
      immutable: false,
    );
    final service = NativeArtifactsService(
      schemaFile: schema,
      releaseDownloader: downloader,
    );
    await expectLater(
      service.fetchPublished(
        target: 'linux',
        cacheDirectory: fixture.cacheDirectory,
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
    expect(
      Directory('${fixture.cacheDirectory.path}/$releaseTag/linux')
          .existsSync(),
      isFalse,
    );
  });

  test('offline install never calls the downloader', () async {
    final fixture = await createNativeFixture(scratch);
    final downloader = FakeReleaseDownloader(fixture.releaseDirectory);
    final service = NativeArtifactsService(
      schemaFile: schema,
      releaseDownloader: downloader,
    );
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    await service.installOffline(
      target: 'linux',
      cacheDirectory: fixture.cacheDirectory,
      packageRoot: fixture.packageRoot,
    );
    expect(downloader.calls, 0);
    expect(
      File(
        '${fixture.packageRoot.path}/linux/Libraries/release/libduckdb.so',
      ).existsSync(),
      isTrue,
    );
  });

  test('installs the exact destination mapping for every target', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    final manifest = await service.loadManifest(fixture.manifestFile);
    for (final artifact in manifest.artifacts) {
      await service.installOffline(
        target: artifact.target,
        cacheDirectory: fixture.cacheDirectory,
        packageRoot: fixture.packageRoot,
      );
      for (final member in artifact.members) {
        expect(
          File('${fixture.packageRoot.path}/${member.installDestination}')
              .existsSync(),
          isTrue,
        );
      }
    }
  });

  test('offline verification rejects a tampered cache archive', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    File(
      '${fixture.cacheDirectory.path}/$releaseTag/linux/duckdb-linux-x86_64.zip',
    ).writeAsStringSync('tampered');
    await expectLater(
      service.verifyCacheOffline(
        target: 'linux',
        cacheDirectory: fixture.cacheDirectory,
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('installed output verification rejects later tampering', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    await service.installOffline(
      target: 'linux',
      cacheDirectory: fixture.cacheDirectory,
      packageRoot: fixture.packageRoot,
    );
    final manifest = await service.loadManifest(fixture.manifestFile);
    final artifact = manifest.artifactFor('linux');
    File(
      '${fixture.packageRoot.path}/${artifact.members.single.installDestination}',
    ).writeAsStringSync('tampered');
    await expectLater(
      verifyInstalledArtifact(artifact, fixture.packageRoot),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('failed install removes its atomic stage', () async {
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    final cache = NativeArtifactCache(
      root: fixture.cacheDirectory,
      schemaFile: schema,
    );
    final cached = await cache.verify('linux');
    File(
      '${cached.extractedDirectory.path}/${cached.artifact.members.single.path}',
    ).writeAsStringSync('tampered');
    await expectLater(
      installArtifact(cached, fixture.packageRoot),
      throwsA(isA<NativeArtifactsException>()),
    );
    final parent = Directory('${fixture.packageRoot.path}/linux/Libraries');
    expect(
      parent.existsSync()
          ? parent
              .listSync()
              .where((entity) => entity.path.contains('.stage-'))
              .toList()
          : <FileSystemEntity>[],
      isEmpty,
    );
    await cached.extractedDirectory.delete(recursive: true);
  });

  test('rejects a symlinked cache root', () async {
    if (Platform.isWindows) return;
    final fixture = await createNativeFixture(scratch);
    final outside = Directory('${scratch.path}/outside-cache')..createSync();
    Link(fixture.cacheDirectory.path).createSync(outside.path);
    await expectLater(
      NativeArtifactsService(schemaFile: schema).seedLocalCandidate(
        releaseDirectory: fixture.releaseDirectory,
        cacheDirectory: fixture.cacheDirectory,
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
  });

  test('rejects a symlinked install component', () async {
    if (Platform.isWindows) return;
    final fixture = await createNativeFixture(scratch);
    final service = NativeArtifactsService(schemaFile: schema);
    await service.seedLocalCandidate(
      releaseDirectory: fixture.releaseDirectory,
      cacheDirectory: fixture.cacheDirectory,
    );
    final outside = Directory('${scratch.path}/outside-install')..createSync();
    Link('${fixture.packageRoot.path}/linux').createSync(outside.path);
    await expectLater(
      service.installOffline(
        target: 'linux',
        cacheDirectory: fixture.cacheDirectory,
        packageRoot: fixture.packageRoot,
      ),
      throwsA(isA<NativeArtifactsException>()),
    );
  });
}
