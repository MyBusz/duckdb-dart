require File.expand_path('../ios/native_artifact_verifier', __dir__)

DuckdbNativeArtifactVerifier.verify!(
  plugin_root: File.expand_path('..', __dir__),
  target: 'macos'
)

Pod::Spec.new do |s|
  s.name             = 'dart_duckdb'
  s.version          = File.read(File.expand_path('../pubspec.yaml', __dir__)).match(/version:\s+(\d+\.\d+\.\d+)/)[1]
  s.summary          = 'A new flutter plugin project.'
  s.description      = <<-DESC
    A new flutter plugin project.
  DESC
  s.homepage         = 'https://tigereye.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tigereye' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.osx.vendored_libraries = 'Libraries/release/libduckdb.dylib'

end
