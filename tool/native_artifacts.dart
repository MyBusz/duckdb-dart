import 'dart:io';

import 'native_artifacts/cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runNativeArtifactsCli(arguments);
}
