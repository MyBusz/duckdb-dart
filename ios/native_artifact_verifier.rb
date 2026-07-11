require 'digest'
require 'json'

module DuckdbNativeArtifactVerifier
  MAX_LOCK_BYTES = 1024 * 1024
  INSTALL_ROOTS = {
    'ios' => 'ios/Libraries/release',
    'macos' => 'macos/Libraries/release'
  }.freeze
  FILE_NAMES = {
    'ios' => 'duckdb-ios-xcframework.zip',
    'macos' => 'duckdb-macos-universal.zip'
  }.freeze
  REQUIRED_MEMBERS = {
    'ios' => [
      'duckdb.xcframework/Info.plist',
      'duckdb.xcframework/ios-arm64/duckdb.framework/duckdb',
      'duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb'
    ].freeze,
    'macos' => ['libduckdb.dylib'].freeze
  }.freeze
  SUPPORTED_PLATFORMS = {
    'ios' => [
      {'platform' => 'ios', 'architectures' => ['arm64'], 'minimumOsVersion' => '13.0'},
      {
        'platform' => 'ios-simulator',
        'architectures' => ['arm64', 'x86_64'],
        'minimumOsVersion' => '13.0'
      }
    ].freeze,
    'macos' => [
      {'platform' => 'macos', 'architectures' => ['x86_64'], 'minimumOsVersion' => '10.15'},
      {'platform' => 'macos', 'architectures' => ['arm64'], 'minimumOsVersion' => '11.0'}
    ].freeze
  }.freeze

  class VerificationError < StandardError; end
  class DuplicateKeyError < StandardError; end

  class UniqueKeyHash < Hash
    def []=(key, value)
      raise DuplicateKeyError, "duplicate JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  module_function

  def verify!(plugin_root:, target:)
    install_root = INSTALL_ROOTS[target]
    fail_verification("unsupported Apple target #{target.inspect}") unless install_root

    root = File.expand_path(plugin_root)
    lock_path = File.join(root, 'native', 'assets.lock.json')
    lock_stat = File.lstat(lock_path)
    unless lock_stat.file? && !lock_stat.symlink? && lock_stat.size.positive? &&
           lock_stat.size <= MAX_LOCK_BYTES
      fail_verification('native/assets.lock.json is not a bounded regular file')
    end

    manifest = JSON.parse(File.binread(lock_path), object_class: UniqueKeyHash)
    fail_verification('native/assets.lock.json is not a JSON object') unless manifest.is_a?(Hash)
    unless manifest['schemaVersion'] == 1 &&
           manifest['releaseTag'] == 'native-duckdb-1.4.2-r1' &&
           manifest['coreCommit'] == '68d7555f68bd25c1a251ccca2e6338949c33986a' &&
           manifest['staticExtensions'] == ['icu', 'parquet', 'json']
      fail_verification('native/assets.lock.json has the wrong release identity')
    end
    artifacts = manifest['artifacts']
    fail_verification('native/assets.lock.json has no artifact array') unless artifacts.is_a?(Array)

    targets = artifacts.map do |artifact|
      unless artifact.is_a?(Hash) && artifact['target'].is_a?(String)
        fail_verification('native/assets.lock.json has a malformed artifact record')
      end
      artifact['target']
    end
    if targets.length != targets.uniq.length
      fail_verification('native/assets.lock.json has duplicate target records')
    end
    artifact = artifacts.find { |candidate| candidate['target'] == target }
    fail_verification("native/assets.lock.json has no exact #{target} target") unless artifact
    unless artifact['fileName'] == FILE_NAMES[target] &&
           artifact['size'].is_a?(Integer) && artifact['size'].positive? &&
           artifact['sha256'].is_a?(String) && artifact['sha256'].match?(/\A[0-9a-f]{64}\z/) &&
           artifact['supportedPlatforms'] == SUPPORTED_PLATFORMS[target]
      fail_verification("native/assets.lock.json has an invalid #{target} artifact identity")
    end

    members = artifact['members']
    unless members.is_a?(Array) && members.length.between?(1, 64)
      fail_verification("the #{target} target has no bounded member array")
    end

    paths = {}
    destinations = {}
    members.each do |member|
      verify_member!(root, target, install_root, member, paths, destinations)
    end
    unless REQUIRED_MEMBERS[target].all? { |path| paths.key?(path.downcase) }
      fail_verification("the #{target} target is missing a required member")
    end
    true
  rescue VerificationError => error
    raise "dart_duckdb: native artifact verification failed: #{error.message}"
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise 'dart_duckdb: native artifact verification failed: native/assets.lock.json or an installed member is absent'
  rescue Errno::EACCES, Errno::ELOOP, IOError, SystemCallError => error
    raise "dart_duckdb: native artifact verification failed: unable to read lock/install: #{error.message}"
  rescue JSON::ParserError, DuplicateKeyError => error
    raise "dart_duckdb: native artifact verification failed: corrupt native/assets.lock.json: #{error.message}"
  end

  def verify_member!(root, target, install_root, member, paths, destinations)
    fail_verification("the #{target} target has a malformed member") unless member.is_a?(Hash)
    path = member['path']
    destination = member['installDestination']
    size = member['size']
    sha256 = member['sha256']
    validate_path!(path, 'archive member')
    validate_path!(destination, 'install destination')
    unless size.is_a?(Integer) && size.positive? &&
           sha256.is_a?(String) && sha256.match?(/\A[0-9a-f]{64}\z/)
      fail_verification("the #{target} target has invalid member size or SHA-256 metadata")
    end
    unless destination == "#{install_root}/#{path}"
      fail_verification("the #{target} target has an unexpected member destination")
    end

    folded_path = path.downcase
    folded_destination = destination.downcase
    if paths.key?(folded_path) || destinations.key?(folded_destination)
      fail_verification("the #{target} target has duplicate or case-colliding members")
    end
    paths[folded_path] = true
    destinations[folded_destination] = true

    installed = File.expand_path(destination, root)
    root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
    unless installed.start_with?(root_prefix)
      fail_verification("the #{target} target member escapes the plugin checkout")
    end
    verify_regular_path!(root, destination)
    stat = File.lstat(installed)
    unless stat.file? && !stat.symlink? && stat.size == size
      fail_verification("installed #{target} member is absent, symlinked, non-regular, or has the wrong size")
    end
    unless Digest::SHA256.file(installed).hexdigest == sha256
      fail_verification("installed #{target} member failed SHA-256 verification")
    end
  end

  def validate_path!(value, label)
    unless value.is_a?(String) && !value.empty? && value.ascii_only? &&
           value.bytes.all? { |byte| byte.between?(0x20, 0x7e) } &&
           !value.start_with?('/') && !value.end_with?('/') &&
           !value.include?('\\') && !value.match?(/\A[A-Za-z]:/) &&
           value.split('/').none? { |segment| segment.empty? || segment == '.' || segment == '..' }
      fail_verification("unsafe #{label} path in native/assets.lock.json")
    end
  end

  def verify_regular_path!(root, destination)
    current = root
    segments = destination.split('/')
    segments.each_with_index do |segment, index|
      current = File.join(current, segment)
      stat = File.lstat(current)
      if stat.symlink?
        fail_verification('installed member path contains a symlink')
      end
      next if index == segments.length - 1

      fail_verification('installed member path contains a non-directory component') unless stat.directory?
    end
  end

  def fail_verification(message)
    raise VerificationError, message
  end
end
