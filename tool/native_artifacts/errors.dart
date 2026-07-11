final class NativeArtifactsException implements Exception {
  NativeArtifactsException(this.message);

  final String message;

  @override
  String toString() => message;
}

Never fail(String message) => throw NativeArtifactsException(message);
