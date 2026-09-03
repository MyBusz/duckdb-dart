part of 'implementation.dart';

/// Contains the state of a connection needed for finalization.
///
/// This is extracted into separate object so that it can be used as a
/// finalization token. It will get disposed when the main database is no longer
/// reachable without being closed.
class _FinalizableConnection extends FinalizablePart {
  final Bindings _bindings;
  final Pointer<duckdb_connection> _handle;

  _FinalizableConnection(this._bindings, this._handle);

  @override
  void dispose() {
    _bindings.duckdb_disconnect(_handle);
    _handle.free();
  }
}

/// States for the single native streaming result a DuckDB connection may own.
///
/// DuckDB's streaming C API keeps execution state on the connection. Keeping
/// this lease separate from [ConnectionImpl] makes it possible for a result
/// finalizer to release an abandoned stream without retaining the public
/// result object.
enum _StreamingLeaseState {
  idle,
  pending,
  active,
  fetching,
  abandoned,
  closing,
  exhausted,
  disposed,
}

class _StreamingLease {
  _StreamingLeaseState _state = _StreamingLeaseState.idle;
  int _liveAppenders = 0;
  Future<void>? _handoff;
  _StreamingResultResources? _resource;
  bool _connectionClosing = false;
  Pointer<duckdb_result>? _unresolvedResultCell;

  bool get isConnectionBlocked => _state != _StreamingLeaseState.idle;

  _StreamingResultResources? get resource => _resource;
  bool get hasUnresolvedNativeOwnership => _unresolvedResultCell != null;
  Pointer<duckdb_result>? get unresolvedResultCell => _unresolvedResultCell;

  void ensureConnectionOperationAllowed() {
    if (isConnectionBlocked) {
      throw StateError(
        'Connection is leased by a native streaming result. Dispose the result '
        'after leaving its stream before starting another operation.',
      );
    }
  }

  void beginPending() {
    if (_connectionClosing) {
      throw StateError('Connection is being disposed');
    }
    ensureConnectionOperationAllowed();
    if (_liveAppenders != 0) {
      throw StateError(
        'Cannot execute a native streaming result while an appender is live.',
      );
    }
    _state = _StreamingLeaseState.pending;
  }

  void trackHandoff(Future<void> handoff) {
    _handoff = handoff;
  }

  Future<void> waitForHandoff() async {
    final handoff = _handoff;
    if (handoff != null) {
      try {
        await handoff;
      } catch (_) {
        // The streaming call reports its own error. Connection shutdown only
        // needs to wait until its native output cell can no longer be exposed.
      }
    }
  }

  void activate(_StreamingResultResources resource) {
    _resource = resource;
    _state = _StreamingLeaseState.active;
  }

  void beginFetch(_StreamingResultResources resource) {
    if (!identical(_resource, resource) ||
        (_state != _StreamingLeaseState.active &&
            _state != _StreamingLeaseState.abandoned)) {
      throw StateError('Streaming result is no longer active');
    }
    _state = _StreamingLeaseState.fetching;
  }

  void finishFetch(_StreamingResultResources resource) {
    if (identical(_resource, resource) &&
        _state == _StreamingLeaseState.fetching) {
      _state = _StreamingLeaseState.active;
    }
  }

  void markAbandoned(_StreamingResultResources resource) {
    if (identical(_resource, resource) &&
        (_state == _StreamingLeaseState.active ||
            _state == _StreamingLeaseState.fetching)) {
      _state = _StreamingLeaseState.abandoned;
    }
  }

  void markExhausted(_StreamingResultResources resource) {
    if (identical(_resource, resource)) {
      _state = _StreamingLeaseState.exhausted;
    }
  }

  void beginClosing(_StreamingResultResources resource) {
    if (identical(_resource, resource)) {
      _state = _StreamingLeaseState.closing;
    }
  }

  void markConnectionClosing() {
    _connectionClosing = true;
    if (_state != _StreamingLeaseState.idle) {
      _state = _StreamingLeaseState.closing;
    }
    _resource?._markClosing();
  }

  void releasePending() {
    if (_resource == null && !hasUnresolvedNativeOwnership) {
      _state = _StreamingLeaseState.idle;
    }
  }

  void retainUnresolvedResultCell(Pointer<duckdb_result> result) {
    _unresolvedResultCell = result;
  }

  void resolveUnresolvedResultCell(Pointer<duckdb_result> result) {
    if (identical(_unresolvedResultCell, result)) {
      _unresolvedResultCell = null;
    }
  }

  void release(_StreamingResultResources resource) {
    if (!identical(_resource, resource)) return;

    _resource = null;
    _state = _StreamingLeaseState.disposed;
    if (!_connectionClosing) {
      _state = _StreamingLeaseState.idle;
    }
  }

  void registerAppender() {
    ensureConnectionOperationAllowed();
    if (_connectionClosing) {
      throw StateError('Connection is being disposed');
    }
    _liveAppenders++;
  }

  void unregisterAppender() {
    if (_liveAppenders > 0) {
      _liveAppenders--;
    }
  }
}

class ConnectionImpl extends Connection with DatabaseOperationCancellation {
  static final _log = Logger('duckdb');
  final Bindings _bindings;
  final _FinalizableConnection _finalizable;
  final Finalizer<FinalizablePart> _finalizer = disposeFinalizer;
  late final ConnectionIsolate _isolate;
  bool _isClosed = false;
  bool _isDisposed = false;
  Future<void>? _disposeFuture;
  final _streamingLease = _StreamingLease();

  Pointer<duckdb_connection> get _handle => _finalizable._handle;

  @override
  Bindings get bindings => _bindings;

  @override
  ConnectionIsolate get isolate => _isolate;

  @override
  Pointer<duckdb_connection> get handle => _handle;

  @override
  String? get id => _isolate._debugId;

  static void _initializeLogging() {
    hierarchicalLoggingEnabled = true;
  }

  static Future<ConnectionImpl> create(
    Bindings bindings,
    Pointer<duckdb_connection> handle, {
    bool isTransferred = false,
    String? id,
  }) async {
    _initializeLogging();
    final conn = ConnectionImpl._(bindings, handle);
    _log.fine('Creating new connection...');
    conn._isolate = await ConnectionIsolate.create(id: id);
    _log.fine(
      'Created [Connection:${conn._isolate._debugId}${isTransferred ? ':transferred' : ':new'}]',
    );
    return conn;
  }

  ConnectionImpl._(this._bindings, Pointer<duckdb_connection> handle)
      : _finalizable = _FinalizableConnection(_bindings, handle) {
    _finalizer.attach(this, _finalizable, detach: this);
  }

  static Future<ConnectionImpl> connect(
    Database database, {
    String? id,
  }) async {
    final bindings = (duckdb as DuckDB).bindings;
    final outConn = allocate<duckdb_connection>();

    if (bindings.duckdb_connect(
          (database.handle as Pointer<duckdb_database>).value,
          outConn,
        ) ==
        duckdb_state.DuckDBError) {
      throw DuckDBException("could not create database connection");
    }

    return ConnectionImpl.create(
      bindings,
      outConn,
      isTransferred: false,
      id: id,
    );
  }

  static Future<ConnectionImpl> connectWithTransferred(
    TransferableDatabaseImpl database, {
    String? id,
  }) async {
    final bindings = (duckdb as DuckDB).bindings;
    final outConn = allocate<duckdb_connection>();

    if (bindings.duckdb_connect(
          (database.handle as Pointer<duckdb_database>).value,
          outConn,
        ) ==
        duckdb_state.DuckDBError) {
      throw DuckDBException("could not create database connection");
    }

    return ConnectionImpl.create(
      bindings,
      outConn,
      isTransferred: true,
      id: id,
    );
  }

  @override
  Future<void> dispose() {
    if (_isDisposed) return Future<void>.value();
    final existing = _disposeFuture;
    if (existing != null) return existing;

    final dispose = _disposeImpl();
    _disposeFuture = dispose;
    unawaited(
      dispose.then(
        (_) {
          if (identical(_disposeFuture, dispose)) {
            _disposeFuture = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_disposeFuture, dispose)) {
            _disposeFuture = null;
          }
        },
      ),
    );
    return dispose;
  }

  Future<void> _disposeImpl() async {
    if (_isDisposed) {
      _log.fine('Already closed [Connection:${_isolate._debugId}]');
      return;
    }

    _log.fine('Starting dispose... [Connection:${_isolate._debugId}]');
    try {
      // First mark as closed to prevent new operations
      _isClosed = true;
      _streamingLease.markConnectionClosing();

      // Interrupt any ongoing operations
      _log.fine(
        'Interrupting DuckDB connection... [Connection:${_isolate._debugId}]',
      );
      _bindings.duckdb_interrupt(_handle.value);

      // A streaming execution can still be queued when dispose is requested.
      // Wait for the handoff to either destroy its output or install a result
      // resource before the connection and its isolate are torn down.
      await _streamingLease.waitForHandoff();

      await _retryUnresolvedStreamingResult();
      if (_streamingLease.hasUnresolvedNativeOwnership) {
        throw StateError(
          'Cannot safely close a connection with unacknowledged native streaming cleanup.',
        );
      }

      final streamingResource = _streamingLease.resource;
      if (streamingResource != null) {
        await streamingResource.close(fromConnectionDispose: true);
      }

      // Dispose the database isolate first to prevent new operations from being queued
      _log.fine(
        'Disposing connection isolate... [Connection:${_isolate._debugId}]',
      );
      await _isolate.dispose();

      // Finally detach the finalizer and dispose the connection
      _log.fine('Closing connection... [Connection:${_isolate._debugId}]');
      _finalizer.detach(this);
      _finalizable.dispose();
      _isDisposed = true;
    } catch (e, st) {
      _log.severe(
        'Error during dispose [Connection:${_isolate._debugId}]',
        e,
        st,
      );
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError("This connection has already been closed");
    }
  }

  void _ensureConnectionOperationAllowed() {
    _ensureOpen();
    _streamingLease.ensureConnectionOperationAllowed();
  }

  void _beginStreamingExecution() {
    _ensureOpen();
    _streamingLease.beginPending();
  }

  void _trackStreamingHandoff(Future<void> handoff) {
    _streamingLease.trackHandoff(handoff);
  }

  void _releasePendingStreamingLease() {
    _streamingLease.releasePending();
  }

  void _activateStreamingResult(_StreamingResultResources resource) {
    _streamingLease.activate(resource);
  }

  Future<void> _destroyUnexposedStreamingResult(
    Pointer<duckdb_result> result,
  ) async {
    try {
      await _destroyOwnedStreamingResultCell(result);
      _streamingLease.resolveUnresolvedResultCell(result);
    } catch (_) {
      // Keep the caller-owned cell reachable until a later serialized retry
      // can prove that DuckDB consumed it.
      _streamingLease.retainUnresolvedResultCell(result);
      rethrow;
    }
  }

  Future<void> _retryUnresolvedStreamingResult() async {
    final result = _streamingLease.unresolvedResultCell;
    if (result == null) return;
    await _destroyOwnedStreamingResultCell(result);
    _streamingLease.resolveUnresolvedResultCell(result);
  }

  Future<void> _destroyOwnedStreamingResultCell(
    Pointer<duckdb_result> result,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < 2; attempt++) {
      if (_isStreamingResultCellEmpty(result)) {
        calloc.free(result);
        return;
      }

      try {
        await _isolate
            .execute(
              DestroyStreamingResultOperation(
                result.address,
                dropAcknowledgement:
                    StreamingTestHooks._takeDestroyAcknowledgementLoss(),
              ),
            )
            .$2;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }

      // Once the future settles the worker cannot access this stable caller
      // cell. Retry only while its value still proves native ownership exists.
      if (_isStreamingResultCellEmpty(result)) {
        calloc.free(result);
        return;
      }
    }

    if (lastError != null && lastStackTrace != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace);
    }
    throw StateError(
      'Native streaming result destruction was not acknowledged',
    );
  }

  void _registerAppender() {
    _ensureOpen();
    _streamingLease.registerAppender();
  }

  void _unregisterAppender() {
    _streamingLease.unregisterAppender();
  }

  Future<void> _closeStreamingResource(
    _StreamingResultResources resource, {
    bool fromConnectionDispose = false,
  }) {
    final existing = resource._closeFuture;
    if (existing != null) return existing;

    final close = _closeStreamingResourceImpl(resource, fromConnectionDispose);
    resource._closeFuture = close;
    unawaited(
      close.then(
        (_) {
          if (identical(resource._closeFuture, close)) {
            resource._closeFuture = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(resource._closeFuture, close)) {
            resource._closeFuture = null;
          }
        },
      ),
    );
    return close;
  }

  Future<void> _closeStreamingResourceImpl(
    _StreamingResultResources resource,
    bool fromConnectionDispose,
  ) async {
    if (resource._isNativeClosed) return;

    _streamingLease.beginClosing(resource);
    resource._closing = true;

    // An interrupt is safe when no fetch is in flight and is required to make
    // an in-flight fetch settle before its result can be destroyed.
    if (!_isClosed || fromConnectionDispose) {
      _bindings.duckdb_interrupt(_handle.value);
    }

    final fetch = resource._fetchInFlight;
    if (fetch != null) {
      try {
        await fetch;
      } catch (_) {
        // A settled fetch no longer has access to its caller-owned chunk cell.
        // Continue through serialized cleanup; the fetch caller sees its own
        // original error.
      }
    }

    // The resource retains its chunk cell until this isolate operation has
    // positively acknowledged destruction. A failed acknowledgement leaves
    // the resource and connection lease intact rather than risking a second
    // native destroy.
    await resource.destroyCurrentChunk();

    if (!resource._isNativeClosed) {
      await _destroyOwnedStreamingResultCell(resource.result);
      resource._markNativeClosed();
    }

    _streamingLease.release(resource);
  }

  @override
  Future<ResultSet> query(
    String query, {
    DuckDBCancellationToken? token,
  }) async {
    _ensureConnectionOperationAllowed();

    return runWithCancellation(
      operation: QueryOperation(
        connectionPointer: _handle.address,
        query: query,
      ),
      processResult: (future) async {
        final resultPointer = await future;
        final result = Pointer<duckdb_result>.fromAddress(resultPointer);

        final error = _bindings.duckdb_result_error(result);
        if (!error.isNullPointer) {
          try {
            final errorString = error.readString();
            throw DuckDBException(errorString);
          } finally {
            _bindings.duckdb_destroy_result(result);
          }
        }
        return ResultSetImpl.withResult(result);
      },
      operationDescription: query,
      token: token,
    );
  }

  @override
  Future<void> execute(
    String query, {
    DuckDBCancellationToken? token,
  }) async {
    _ensureConnectionOperationAllowed();

    return runWithCancellation(
      operation: QueryOperation(
        connectionPointer: _handle.address,
        query: query,
      ),
      processResult: (future) async {
        final resultPointer = await future;
        final result = Pointer<duckdb_result>.fromAddress(resultPointer);
        try {
          // Check for errors but discard the result
          final error = _bindings.duckdb_result_error(result);
          if (!error.isNullPointer) {
            final errorString = error.readString();
            throw DuckDBException(errorString);
          }
        } finally {
          _bindings.duckdb_destroy_result(result);
        }
      },
      operationDescription: query,
      token: token,
    );
  }

  @override
  Future<PreparedStatement> prepare(
    String query, {
    DuckDBCancellationToken? token,
  }) async {
    _ensureConnectionOperationAllowed();
    return PreparedStatementImpl.prepare(this, query, token: token);
  }

  @override
  Future<Appender> append(String table, String? schema) async {
    _ensureOpen();
    _registerAppender();
    try {
      return AppenderImpl.withConnection(this, table, schema);
    } catch (_) {
      _unregisterAppender();
      rethrow;
    }
  }

  @override
  Future<Iterable<String>> getColumnOrder(String table) async {
    _ensureConnectionOperationAllowed();
    final sql = """
      SELECT column_name
      FROM information_schema.columns
      WHERE table_name = '$table'
      ORDER BY ordinal_position;
    """;

    final resultSet = await query(sql);
    try {
      return resultSet
          .fetchAll()
          .map((row) => row[0]! as String)
          .toList(growable: false);
    } finally {
      await resultSet.dispose();
    }
  }

  @override
  Future<void> interrupt() async {
    _ensureOpen();
    _bindings.duckdb_interrupt(_handle.value);
  }
}

class QueryOperation extends DatabaseOperation {
  final String query;

  const QueryOperation({
    required super.connectionPointer,
    required this.query,
  });

  @override
  Future<int> execute() async {
    final bindings = (duckdb as DuckDB).bindings;
    final connection =
        Pointer<duckdb_connection>.fromAddress(connectionPointer);
    final result = allocate<duckdb_result>();
    final queryPtr = query.toNativeUtf8().cast<Char>();

    try {
      if (bindings.duckdb_query(connection.value, queryPtr, result) ==
          duckdb_state.DuckDBError) {
        try {
          final errorString = bindings.duckdb_result_error(result).readString();
          throw DuckDBException(errorString);
        } finally {
          bindings.duckdb_destroy_result(result);
          result.free();
        }
      }
      return result.address;
    } finally {
      queryPtr.free();
    }
  }

  @override
  String toString() {
    return 'QueryOperation(query: $query)';
  }
}
