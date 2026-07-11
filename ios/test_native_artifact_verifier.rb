require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

require_relative 'native_artifact_verifier'

module Pod
  class Spec
    class << self
      attr_accessor :created

      def new
        spec = allocate
        spec.send(:initialize)
        self.created = spec
        yield spec
        spec
      end
    end

    attr_reader :assignments

    def initialize
      @assignments = {}
    end

    def dependency(*); end

    def ios
      self
    end

    def osx
      self
    end

    def method_missing(name, *arguments)
      if name.to_s.end_with?('=')
        @assignments[name] = arguments
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.end_with?('=') || super
    end
  end
end

class NativeArtifactVerifierTest
  def initialize
    @temporary = Dir.mktmpdir('duckdb-podspec-test')
    @root = File.join(@temporary, 'plugin')
    FileUtils.mkdir_p(File.join(@root, 'native'))
  end

  def close
    FileUtils.remove_entry(@temporary)
  end

  def assert(condition, message = 'assertion failed')
    raise message unless condition
  end

  def assert_raises(pattern)
    yield
    raise "expected failure matching #{pattern.inspect}"
  rescue RuntimeError => error
    raise "unexpected error: #{error.message}" unless pattern.match?(error.message)
  end

  def install_member(target, member_path, content)
    destination = File.join(target, 'Libraries', 'release', member_path)
    absolute = File.join(@root, destination)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content)
    {
      'path' => member_path,
      'size' => content.bytesize,
      'sha256' => Digest::SHA256.hexdigest(content),
      'installDestination' => destination
    }
  end

  def write_lock(artifacts)
    File.binwrite(
      File.join(@root, 'native', 'assets.lock.json'),
      JSON.generate(
        'schemaVersion' => 1,
        'releaseTag' => 'native-duckdb-1.4.2-r1',
        'coreCommit' => '68d7555f68bd25c1a251ccca2e6338949c33986a',
        'staticExtensions' => ['icu', 'parquet', 'json'],
        'artifacts' => artifacts
      )
    )
  end

  def artifact(target, members)
    platforms = if target == 'ios'
                  [
                    {'platform' => 'ios', 'architectures' => ['arm64'], 'minimumOsVersion' => '13.0'},
                    {
                      'platform' => 'ios-simulator',
                      'architectures' => ['arm64', 'x86_64'],
                      'minimumOsVersion' => '13.0'
                    }
                  ]
                else
                  [
                    {'platform' => 'macos', 'architectures' => ['x86_64'], 'minimumOsVersion' => '10.15'},
                    {'platform' => 'macos', 'architectures' => ['arm64'], 'minimumOsVersion' => '11.0'}
                  ]
                end
    {
      'target' => target,
      'fileName' => target == 'ios' ? 'duckdb-ios-xcframework.zip' : 'duckdb-macos-universal.zip',
      'size' => 1,
      'sha256' => 'a' * 64,
      'supportedPlatforms' => platforms,
      'members' => members
    }
  end

  def install_ios_members
    [
      install_member('ios', 'duckdb.xcframework/Info.plist', 'ios-info'),
      install_member(
        'ios',
        'duckdb.xcframework/ios-arm64/duckdb.framework/duckdb',
        'ios-device'
      ),
      install_member(
        'ios',
        'duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb',
        'ios-simulator'
      )
    ]
  end

  def test_accepts_exact_ios_and_macos_installs
    ios_members = install_ios_members
    macos_member = install_member('macos', 'libduckdb.dylib', 'macos')
    write_lock([artifact('ios', ios_members), artifact('macos', [macos_member])])

    assert DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'ios')
    assert DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'macos')
  end

  def test_rejects_tampered_installed_member
    member = install_member('macos', 'libduckdb.dylib', 'expected')
    write_lock([artifact('macos', [member])])
    File.binwrite(File.join(@root, member['installDestination']), 'tampered')

    assert_raises(/wrong size|SHA-256/) do
      DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'macos')
    end
  end

  def test_rejects_wrong_destination_and_duplicate_json_keys
    member = install_ios_members.first
    member['installDestination'] = 'macos/Libraries/release/Info.plist'
    write_lock([artifact('ios', [member])])
    assert_raises(/unexpected member destination/) do
      DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'ios')
    end

    File.binwrite(
      File.join(@root, 'native', 'assets.lock.json'),
      '{"artifacts":[],"artifacts":[]}'
    )
    assert_raises(/corrupt/) do
      DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'ios')
    end
  end

  def test_rejects_symlinked_install_member
    member = install_member('macos', 'libduckdb.dylib', 'macos')
    installed = File.join(@root, member['installDestination'])
    FileUtils.mv(installed, "#{installed}.real")
    File.symlink("#{installed}.real", installed)
    write_lock([artifact('macos', [member])])

    assert_raises(/symlink/) do
      DuckdbNativeArtifactVerifier.verify!(plugin_root: @root, target: 'macos')
    end
  end

  def test_podspecs_evaluate_valid_and_reject_tampered_metadata
    source_root = File.expand_path('..', __dir__)
    FileUtils.mkdir_p(File.join(@root, 'ios'))
    FileUtils.mkdir_p(File.join(@root, 'macos'))
    FileUtils.cp(__FILE__.sub('test_native_artifact_verifier.rb', 'native_artifact_verifier.rb'),
                 File.join(@root, 'ios', 'native_artifact_verifier.rb'))
    $LOADED_FEATURES << File.join(@root, 'ios', 'native_artifact_verifier.rb')
    FileUtils.cp(File.join(source_root, 'ios', 'dart_duckdb.podspec'),
                 File.join(@root, 'ios', 'dart_duckdb.podspec'))
    FileUtils.cp(File.join(source_root, 'macos', 'dart_duckdb.podspec'),
                 File.join(@root, 'macos', 'dart_duckdb.podspec'))
    File.write(File.join(@root, 'pubspec.yaml'), "version: 1.2.3\n")

    ios_members = install_ios_members
    macos_member = install_member('macos', 'libduckdb.dylib', 'macos')
    write_lock([artifact('ios', ios_members), artifact('macos', [macos_member])])
    load File.join(@root, 'ios', 'dart_duckdb.podspec')
    assert !Pod::Spec.created.assignments.key?(:prepare_command=)
    load File.join(@root, 'macos', 'dart_duckdb.podspec')
    assert !Pod::Spec.created.assignments.key?(:prepare_command=)

    macos_member['sha256'] = '0' * 64
    write_lock([artifact('ios', ios_members), artifact('macos', [macos_member])])
    assert_raises(/SHA-256/) { load File.join(@root, 'macos', 'dart_duckdb.podspec') }
  end
end

methods = NativeArtifactVerifierTest.instance_methods(false).grep(/^test_/).sort
failures = []
methods.each do |method|
  test = NativeArtifactVerifierTest.new
  begin
    test.public_send(method)
    puts "PASS #{method}"
  rescue StandardError => error
    failures << "FAIL #{method}: #{error.class}: #{error.message}"
  ensure
    test.close
  end
end
unless failures.empty?
  warn failures.join("\n")
  exit 1
end
puts "#{methods.length} Ruby verifier tests passed"
