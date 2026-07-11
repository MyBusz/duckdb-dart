const releaseRepository = 'MyBusz/duckdb-dart';
const releaseTag = 'native-duckdb-1.4.2-r1';
const coreCommit = '68d7555f68bd25c1a251ccca2e6338949c33986a';

const archiveNamesByTarget = <String, String>{
  'android': 'duckdb-android-arm64-v8a-x86_64.zip',
  'ios': 'duckdb-ios-xcframework.zip',
  'macos': 'duckdb-macos-universal.zip',
  'linux': 'duckdb-linux-x86_64.zip',
  'windows': 'duckdb-windows-x64.zip',
};

const releaseAssetNames = <String>[
  'duckdb-android-arm64-v8a-x86_64.zip',
  'duckdb-ios-xcframework.zip',
  'duckdb-macos-universal.zip',
  'duckdb-linux-x86_64.zip',
  'duckdb-windows-x64.zip',
  'assets.lock.json',
  'SHA256SUMS',
];

const checksumEntryNames = <String>[
  'duckdb-android-arm64-v8a-x86_64.zip',
  'duckdb-ios-xcframework.zip',
  'duckdb-macos-universal.zip',
  'duckdb-linux-x86_64.zip',
  'duckdb-windows-x64.zip',
  'assets.lock.json',
];
