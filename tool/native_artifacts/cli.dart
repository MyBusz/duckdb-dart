import 'dart:io';

import 'errors.dart';
import 'service.dart';

Future<int> runNativeArtifactsCli(
  List<String> arguments, {
  Directory? workingDirectory,
  File? schemaFile,
  NativeArtifactsService? service,
  IOSink? output,
  IOSink? errorOutput,
}) async {
  final cwd = workingDirectory ?? Directory.current;
  final stdoutSink = output ?? stdout;
  final stderrSink = errorOutput ?? stderr;
  try {
    if (arguments.isEmpty) fail(_usage);
    final command = arguments.first;
    final options = _parseOptions(arguments.sublist(1));
    final artifacts = service ??
        NativeArtifactsService(
          schemaFile: schemaFile ??
              File(_join(cwd.path, 'native/native-artifacts.schema.json')),
        );
    switch (command) {
      case 'validate-manifest':
        _rejectOptions(options, const {'--manifest'});
        await artifacts.loadManifest(
          File(_absolute(cwd, _required(options, '--manifest'))),
        );
        stdoutSink.writeln('Manifest is valid.');
      case 'list-targets':
        _rejectOptions(options, const {'--manifest'});
        final manifest = await artifacts.loadManifest(
          File(_absolute(cwd, _required(options, '--manifest'))),
        );
        for (final artifact in manifest.artifacts) {
          stdoutSink.writeln(artifact.target);
        }
      case 'seed-local':
        _rejectOptions(options, const {'--release-dir', '--cache-root'});
        await artifacts.seedLocalCandidate(
          releaseDirectory: Directory(
            _absolute(cwd, _required(options, '--release-dir')),
          ),
          cacheDirectory: Directory(
            _absolute(cwd, options['--cache-root'] ?? '.dart_tool/dart_duckdb'),
          ),
        );
        stdoutSink.writeln('Local candidate verified and cached.');
      case 'fetch':
        _rejectOptions(options, const {'--target', '--cache-root'});
        await artifacts.fetchPublished(
          target: _required(options, '--target'),
          cacheDirectory: Directory(
            _absolute(cwd, options['--cache-root'] ?? '.dart_tool/dart_duckdb'),
          ),
        );
        stdoutSink.writeln('Immutable release asset verified and cached.');
      case 'verify-cache':
        _rejectOptions(
          options,
          const {'--target', '--cache-root', '--offline'},
        );
        _requireOffline(options);
        await artifacts.verifyCacheOffline(
          target: _required(options, '--target'),
          cacheDirectory: Directory(
            _absolute(cwd, options['--cache-root'] ?? '.dart_tool/dart_duckdb'),
          ),
        );
        stdoutSink.writeln('Cached native artifact is valid.');
      case 'install':
        _rejectOptions(
          options,
          const {
            '--target',
            '--cache-root',
            '--package-root',
            '--offline',
          },
        );
        _requireOffline(options);
        await artifacts.installOffline(
          target: _required(options, '--target'),
          cacheDirectory: Directory(
            _absolute(cwd, options['--cache-root'] ?? '.dart_tool/dart_duckdb'),
          ),
          packageRoot: Directory(
            _absolute(cwd, options['--package-root'] ?? cwd.path),
          ),
        );
        stdoutSink.writeln('Native artifact installed.');
      default:
        fail('Unknown native artifact command. $_usage');
    }
    return 0;
  } on NativeArtifactsException catch (error) {
    stderrSink.writeln('native-artifacts: ${error.message}');
    return 64;
  } on Object {
    stderrSink.writeln('native-artifacts: operation failed safely');
    return 74;
  }
}

Map<String, String?> _parseOptions(List<String> arguments) {
  final result = <String, String?>{};
  var index = 0;
  while (index < arguments.length) {
    final option = arguments[index];
    if (!option.startsWith('--') || option.contains('=')) {
      fail('Invalid command-line argument');
    }
    if (result.containsKey(option)) fail('Duplicate command-line option');
    if (option == '--offline') {
      result[option] = null;
      index++;
      continue;
    }
    if (index + 1 >= arguments.length ||
        arguments[index + 1].startsWith('--')) {
      fail('Missing value for a command-line option');
    }
    result[option] = arguments[index + 1];
    index += 2;
  }
  return result;
}

String _required(Map<String, String?> options, String name) {
  final value = options[name];
  if (value == null || value.isEmpty) fail('Missing required option $name');
  return value;
}

void _rejectOptions(Map<String, String?> options, Set<String> allowed) {
  if (options.keys.any((option) => !allowed.contains(option))) {
    fail('Unsupported command-line option');
  }
}

void _requireOffline(Map<String, String?> options) {
  if (!options.containsKey('--offline')) {
    fail('This command requires --offline');
  }
}

String _absolute(Directory cwd, String value) =>
    File(value).isAbsolute ? value : _join(cwd.path, value);

String _join(String base, String child) =>
    '$base${base.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';

const _usage =
    'Use seed-local, fetch, verify-cache --offline, install --offline, '
    'validate-manifest, or list-targets.';
