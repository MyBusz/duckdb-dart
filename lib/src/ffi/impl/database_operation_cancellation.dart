part of 'implementation.dart';

/// Mixin that provides cancellation support for database operations
mixin DatabaseOperationCancellation {
  /// Get the bindings instance
  Bindings get bindings;

  /// Get the database isolate instance
  ConnectionIsolate get isolate;

  /// Get the connection handle
  Pointer<duckdb_connection> get handle;

  /// Helper method to execute a database operation with cancellation support
  Future<T> runWithCancellation<T>({
    required DatabaseOperation operation,
    required Future<T> Function(Future<int> future) processResult,
    required String operationDescription,
    DuckDBCancellationToken? token,
  }) async {
    if (token != null && token.isCancelled) {
      throw DuckDBCancelledException('Operation cancelled');
    }

    final execution = isolate.execute(operation);
    final operationId = execution.$1;
    final operationFuture = execution.$2;
    final startAcknowledgement = execution.$3;
    final processedResult = processResult(operationFuture);

    Future<T> operationHandler() async {
      try {
        final result = await processedResult;
        if (token?.isCancelled ?? false) {
          throw DuckDBCancelledException('Operation cancelled');
        }
        return result;
      } on Object {
        // An explicit cancellation always wins over a native error or result
        // observed in the same dispatch/response turn.
        if (token?.isCancelled ?? false) {
          throw DuckDBCancelledException('Operation cancelled');
        }
        rethrow;
      }
    }

    Future<T> cancellationHandler() async {
      await token!.cancelled;

      isolate.markOperationCancelled(operationId);
      final removed = await isolate.cancelOperation(operationId);
      if (removed) {
        try {
          await processedResult;
        } on Object {
          // The removed operation settles with cancellation below.
        }
        throw DuckDBCancelledException('Operation cancelled');
      }

      // The operation was dispatched and is therefore not safely removable.
      // Wait only for a start acknowledgement or terminal response: no polling
      // and no wait on a native COPY after it has already completed.
      final started = await Future.any<bool>([
        startAcknowledgement,
        operationFuture.then<bool>(
          (_) => false,
          onError: (Object _, StackTrace __) => false,
        ),
      ]);
      if (started && isolate.currentOperationId == operationId) {
        bindings.duckdb_interrupt(handle.value);
      }

      try {
        await processedResult;
      } on Object {
        // The cancellation terminal is deliberately authoritative.
      }
      throw DuckDBCancelledException('Operation cancelled');
    }

    final result = await Future.any<T>([
      operationHandler(),
      if (token != null) cancellationHandler(),
    ]);

    return result;
  }
}
