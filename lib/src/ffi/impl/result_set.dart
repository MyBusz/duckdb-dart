part of 'implementation.dart';

/// Contains the state of a connection needed for finalization.
///
/// This is extracted into separate object so that it can be used as a
/// finalization token. It will get disposed when the main database is no longer
/// reachable without being closed.
class _FinalizableResultSet extends FinalizablePart {
  final Bindings _bindings;
  final Pointer<duckdb_result> _handle;

  _FinalizableResultSet(this._bindings, this._handle);

  @override
  void dispose() {
    _bindings.duckdb_destroy_result(_handle);
    _handle.free();
  }
}

class _FinalizableStreamingResult extends FinalizablePart {
  final _StreamingResultResources _resources;

  _FinalizableStreamingResult(this._resources);

  @override
  void dispose() {
    // Finalizers must never directly destroy streaming native resources. The
    // connection isolate is the sole authority for acknowledged destruction.
    _resources.closeSilently();
  }
}

bool _isStreamingResultCellEmpty(Pointer<duckdb_result> result) =>
    result.ref.internal_data.isNullPointer;

class ResultSetImpl extends ResultSet {
  final _FinalizableResultSet? _finalizable;
  final _StreamingResultResources? _streamingResources;
  final _StreamingMetadata? _streamingMetadata;
  final Finalizer<FinalizablePart> _finalizer = disposeFinalizer;
  late final List<LogicalType?> _logicalTypes;

  /// https://duckdb.org/docs/api/c/data_chunk
  // Data chunks represent a horizontal slice of a table. They hold a number of vectors,
  // each of which can hold up to VECTOR_SIZE rows. The vector size can be obtained through
  // the duckdb_vector_size function and is configurable, but is usually set to 2048.
  var _currentChunkIndex = 0;
  DataChunkImpl? _currentChunk;
  final List<int> _chunkOffsets = [];
  final Map<int, int> _chunkOffsetToChunkIndex = HashMap();

  final Bindings _bindings;

  @override
  Pointer<duckdb_result> get handle {
    if (isStreaming) {
      throw StateError(
        'Native streaming results do not expose their native result handle.',
      );
    }
    return _finalizable!._handle;
  }

  Pointer<duckdb_result> get _nativeHandle =>
      _streamingResources?.result ?? _finalizable!._handle;

  bool _isClosed = false;
  bool _streamSubscriptionStarted = false;

  /// Cache the fixed values to make lookups fast.
  int? _columnCount;
  int? _chunkCount;
  int? _rowCount;
  List<String>? _columnNames;
  List<int>? _columnTypes;
  late final List<Column<Object?>?> _columnCache =
      List.filled(columnCount, null);

  /// The number of chunks in the result set
  int get chunkCount {
    _throwIfStreaming('chunkCount');
    return _chunkCount ??= _bindings.duckdb_result_chunk_count(handle.ref);
  }

  @override
  bool get isStreaming => _streamingResources != null;

  /// The number of columns in the result set
  @override
  int get columnCount =>
      _streamingMetadata?.columnCount ??
      (_columnCount ??= _bindings.duckdb_column_count(_nativeHandle));

  /// The total number of rows in the result set
  @override
  int get rowCount {
    _throwIfStreaming('rowCount');
    return _rowCount ??= _bindings.duckdb_row_count(_nativeHandle);
  }

  @override
  List<String> get columnNames {
    final metadata = _streamingMetadata;
    if (metadata != null) return metadata.columnNames;
    return _columnNames ??= List<String>.generate(
      columnCount,
      (index) =>
          _bindings.duckdb_column_name(_nativeHandle, index).readString(),
      growable: false,
    );
  }

  @override
  List<int> get columnTypes {
    final metadata = _streamingMetadata;
    if (metadata != null) return metadata.columnTypes;
    return _columnTypes ??= List<int>.generate(
      columnCount,
      (column) => _bindings.duckdb_column_type(_nativeHandle, column).value,
      growable: false,
    );
  }

  /// Return the database type for a given column.
  @override
  DatabaseTypeNative columnDataType(int index) {
    return DatabaseTypeNative.values[columnTypes[index]];
  }

  ResultSetImpl._(this._bindings, Pointer<duckdb_result> handle)
      : _finalizable = _FinalizableResultSet(_bindings, handle),
        _streamingResources = null,
        _streamingMetadata = null {
    _finalizer.attach(this, _finalizable!, detach: this);

    // Initialize _logicalTypes with fixed size
    _logicalTypes =
        List<LogicalType?>.filled(columnCount, null, growable: false);
  }

  ResultSetImpl._streaming(
    _StreamingResultResources resources,
    _StreamingMetadata metadata,
  )   : _bindings = resources.bindings,
        _finalizable = null,
        _streamingResources = resources,
        _streamingMetadata = metadata {
    _finalizer.attach(
      this,
      _FinalizableStreamingResult(resources),
      detach: this,
    );
    _logicalTypes =
        List<LogicalType?>.filled(columnCount, null, growable: false);
  }

  factory ResultSetImpl.withResult(Pointer<duckdb_result> result) {
    return ResultSetImpl._((duckdb as DuckDB).bindings, result);
  }

  factory ResultSetImpl._withStreaming(
    _StreamingResultResources resources,
    _StreamingMetadata metadata,
    DuckDBCancellationToken? token,
  ) {
    final result = ResultSetImpl._streaming(resources, metadata);
    if (token != null) {
      final cancellationGate = _StreamingResultCancellationGate(resources);
      unawaited(
        token.cancelled.then((_) {
          cancellationGate.cancel();
        }),
      );
    }
    return result;
  }

  void _throwIfStreaming(String operation) {
    if (isStreaming) {
      throw StateError(
        '$operation is not available on a native streaming result. '
        'Use fetchAllStream and dispose the result explicitly.',
      );
    }
  }

  /// Use a generator to mimic a row cursor.
  late final Iterator<List<Object?>> _cursor = (() sync* {
    for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      final row = List<Object?>.generate(
        columnCount,
        (columnIndex) => this[columnIndex][rowIndex],
        growable: false,
      );
      yield row;
    }
  })()
      .iterator;

  /// Fetch the next row of a query result set, returning a single sequence,
  /// or null when no more data is available.
  @override
  List<Object?>? fetchOne() {
    _throwIfStreaming('fetchOne');
    return _cursor.moveNext() ? _cursor.current : null;
  }

  @override
  List<List<Object?>> fetchAll({int? batchSize}) {
    _throwIfStreaming('fetchAll');
    final rows = <List<Object?>>[];

    // Use DuckDB's vector size as default batch size for optimal performance
    final chunkSize = batchSize ?? vectorSize;

    // Pre-fetch all column accessors
    final columns = List.generate(
      columnCount,
      (columnIndex) => this[columnIndex],
      growable: false,
    );

    // Process in batches
    for (var offset = 0; offset < rowCount; offset += chunkSize) {
      final currentBatchSize = min(chunkSize, rowCount - offset);

      for (var i = 0; i < currentBatchSize; i++) {
        final rowIndex = offset + i;
        final row = List<Object?>.filled(columnCount, null, growable: false);
        for (var colIndex = 0; colIndex < columnCount; colIndex++) {
          row[colIndex] = columns[colIndex][rowIndex];
        }
        rows.add(row);
      }
    }

    return rows;
  }

  @override
  Stream<List<Object?>> fetchAllStream({int? batchSize}) {
    if (isStreaming) {
      if (batchSize != null && batchSize <= 0) {
        throw ArgumentError.value(
          batchSize,
          'batchSize',
          'must be greater than zero for a streaming result',
        );
      }
      if (_streamSubscriptionStarted) {
        throw StateError(
          'A native streaming result can only be consumed once.',
        );
      }
      _streamSubscriptionStarted = true;
      return _fetchStreamingRows();
    }

    return _fetchMaterializedRows(batchSize);
  }

  Stream<List<Object?>> _fetchMaterializedRows(int? batchSize) async* {
    // Use DuckDB's vector size as default batch size for optimal performance
    final chunkSize = batchSize ?? vectorSize;

    // Pre-fetch all column accessors
    final columns = List.generate(
      columnCount,
      (columnIndex) => this[columnIndex],
      growable: false,
    );

    // Process in batches
    for (var offset = 0; offset < rowCount; offset += chunkSize) {
      final currentBatchSize = min(chunkSize, rowCount - offset);

      for (var i = 0; i < currentBatchSize; i++) {
        final rowIndex = offset + i;
        final row = List<Object?>.filled(columnCount, null, growable: false);
        for (var colIndex = 0; colIndex < columnCount; colIndex++) {
          row[colIndex] = columns[colIndex][rowIndex];
        }
        yield row;
      }
    }
  }

  Stream<List<Object?>> _fetchStreamingRows() async* {
    final resources = _streamingResources!;
    var reachedEof = false;

    try {
      while (true) {
        if (resources.isCancelled) {
          throw DuckDBCancelledException('Operation cancelled');
        }
        if (resources.isClosing) {
          throw StateError('Streaming result is being disposed');
        }
        if (resources.isNativeClosed) {
          throw StateError('Streaming result was closed with its connection');
        }

        final chunk = await resources.fetchChunk();
        if (resources.isCancelled) {
          throw DuckDBCancelledException('Operation cancelled');
        }
        if (resources.isClosing) {
          throw StateError('Streaming result is being disposed');
        }
        if (resources.isNativeClosed) {
          throw StateError('Streaming result was closed with its connection');
        }

        if (chunk.value.isNullPointer) {
          final error = _bindings.duckdb_result_error(resources.result);
          await resources.destroyCurrentChunk();
          if (!error.isNullPointer) {
            throw DuckDBException(error.readString());
          }

          reachedEof = true;
          resources.connection._streamingLease.markExhausted(resources);
          await resources.close();
          return;
        }

        try {
          final rowCount = _bindings.duckdb_data_chunk_get_size(chunk.value);
          for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
            if (resources.isCancelled) {
              throw DuckDBCancelledException('Operation cancelled');
            }
            if (resources.isClosing) {
              throw StateError('Streaming result is being disposed');
            }
            if (resources.isNativeClosed) {
              throw StateError(
                'Streaming result was closed with its connection',
              );
            }
            // Rows are detached one at a time. [batchSize] deliberately does
            // not control DuckDB's native chunk size and no Dart row batch is
            // buffered here.
            yield _detachStreamingRow(chunk.value, rowIndex);
          }
        } finally {
          await resources.destroyCurrentChunk();
        }
      }
    } on DuckDBCancelledException {
      await resources.close();
      rethrow;
    } catch (_) {
      await resources.close();
      rethrow;
    } finally {
      if (!reachedEof && !resources.isNativeClosed) {
        resources.connection._streamingLease.markAbandoned(resources);
        await resources.destroyCurrentChunk();
      }
    }
  }

  List<Object?> _detachStreamingRow(duckdb_data_chunk chunk, int rowIndex) {
    final metadata = _streamingMetadata!;
    final row = <Object?>[];
    for (var columnIndex = 0; columnIndex < columnCount; columnIndex++) {
      final vectorHandle =
          _bindings.duckdb_data_chunk_get_vector(chunk, columnIndex);
      final vector = Vector<Object?>(
        _bindings,
        vectorHandle,
        _bindings.duckdb_data_chunk_get_size(chunk),
        metadata.logicalTypes[columnIndex],
      );
      var value = vector.getValue(rowIndex);
      if (metadata.jsonColumns[columnIndex] && value is String) {
        try {
          value = JsonValue(jsonDecode(value));
        } catch (_) {
          value = JsonValue(value, isValid: false);
        }
      }
      row.add(_detachStreamingValue(value));
    }
    return List<Object?>.unmodifiable(row);
  }

  @override
  Future<void> dispose() async {
    final streamingResources = _streamingResources;
    if (streamingResources != null) {
      // A failed acknowledged close may leave the native cell owned by the
      // resource. Keep subsequent dispose calls as cleanup retries.
      _finalizer.detach(this);
      _isClosed = true;
      await streamingResources.close();
      return;
    }

    if (_isClosed) return;
    _finalizer.detach(this);
    _isClosed = true;
    _finalizable!.dispose();
  }

  /// Returns the logical type for a given column index.
  /// This includes information about aliases (e.g., JSON, user-defined types).
  LogicalType logicalType(int columnIndex) {
    _throwIfStreaming('logicalType');
    final type = _logicalTypes[columnIndex];
    if (type != null) {
      return type;
    }

    // Allocate the logical type pointer only if not cached
    final logicalTypePointer = allocate<duckdb_logical_type>();
    logicalTypePointer.value = Pointer.fromAddress(
      (duckdb as DuckDB)
          .bindings
          .duckdb_column_logical_type(handle, columnIndex)
          .address,
    );

    // Create the LogicalType and cache it
    return _logicalTypes[columnIndex] =
        LogicalType.withLogicalType(logicalTypePointer);
  }

  LogicalType _logicalType(int columnIndex) => logicalType(columnIndex);

  T? Function(int) transformOrNull<T>(int columnIndex) {
    return transformer<T?>(columnIndex, (Vector<T?> vector, int elementIndex) {
      return vector.getValue(elementIndex);
    });
  }

  @override
  Column<dynamic> operator [](int index) {
    _throwIfStreaming('operator []');
    if (index >= columnCount) {
      throw IndexError.withLength(index, columnCount);
    }

    // Check if this column is JSON type (based on logical type alias)
    final logicalType = _logicalType(index);
    if (logicalType.isJson) {
      // JSON types are returned as VARCHAR from the C API, but we can parse them
      return _columnCache[index] ??= ColumnImpl<dynamic>(
        this,
        index,
        (rowIndex) {
          final jsonString = transformOrNull<String>(index)(rowIndex);
          if (jsonString == null) {
            return null;
          }
          try {
            return JsonValue(jsonDecode(jsonString));
          } catch (e) {
            return JsonValue(jsonString, isValid: false);
          }
        },
      );
    }

    return _columnCache[index] ??= switch (columnDataType(index)) {
      DatabaseTypeNative.boolean =>
        ColumnImpl<bool?>(this, index, transformOrNull<bool>(index)),
      DatabaseTypeNative.tinyInt ||
      DatabaseTypeNative.smallInt ||
      DatabaseTypeNative.integer ||
      DatabaseTypeNative.uTinyInt ||
      DatabaseTypeNative.uSmallInt ||
      DatabaseTypeNative.uInteger ||
      DatabaseTypeNative.bigInt =>
        ColumnImpl<int?>(this, index, transformOrNull<int>(index)),
      DatabaseTypeNative.uBigInt ||
      DatabaseTypeNative.hugeInt ||
      DatabaseTypeNative.uHugeInt =>
        ColumnImpl<BigInt?>(this, index, transformOrNull<BigInt>(index)),
      DatabaseTypeNative.float ||
      DatabaseTypeNative.double =>
        ColumnImpl<double?>(this, index, transformOrNull<double>(index)),
      DatabaseTypeNative.varchar ||
      DatabaseTypeNative.bitString =>
        ColumnImpl<String?>(this, index, transformOrNull<String>(index)),
      DatabaseTypeNative.timestamp ||
      DatabaseTypeNative.timestampS ||
      DatabaseTypeNative.timestampMS ||
      DatabaseTypeNative.timestampNS ||
      DatabaseTypeNative.timestampTz =>
        ColumnImpl<DateTime?>(this, index, transformOrNull<DateTime>(index)),
      DatabaseTypeNative.date =>
        ColumnImpl<Date?>(this, index, transformOrNull<Date>(index)),
      DatabaseTypeNative.time =>
        ColumnImpl<Time?>(this, index, transformOrNull<Time>(index)),
      DatabaseTypeNative.timeTz => ColumnImpl<TimeWithOffset?>(
          this,
          index,
          transformOrNull<TimeWithOffset>(index),
        ),
      DatabaseTypeNative.interval =>
        ColumnImpl<Interval?>(this, index, transformOrNull<Interval>(index)),
      DatabaseTypeNative.blob =>
        ColumnImpl<Uint8List?>(this, index, transformOrNull<Uint8List>(index)),
      DatabaseTypeNative.uuid =>
        ColumnImpl<UuidValue?>(this, index, transformOrNull<UuidValue>(index)),
      DatabaseTypeNative.list => ColumnImpl<List<Object?>?>(
          this,
          index,
          transformOrNull<List<Object?>>(index),
        ),
      DatabaseTypeNative.structure => ColumnImpl<Map<String, Object?>?>(
          this,
          index,
          transformOrNull<Map<String, Object?>>(index),
        ),
      DatabaseTypeNative.map => ColumnImpl<Map<Object, Object?>?>(
          this,
          index,
          transformOrNull<Map<Object, Object?>>(index),
        ),
      DatabaseTypeNative.decimal =>
        ColumnImpl<Decimal?>(this, index, transformOrNull<Decimal>(index)),
      DatabaseTypeNative.enumeration => ColumnImpl<String?>(
          this,
          index,
          transformOrNull<String>(index),
        ),
      DatabaseTypeNative.array => ColumnImpl<List<Object?>?>(
          this,
          index,
          transformOrNull<List<Object?>>(index),
        ),
      _ => ColumnImpl<Object?>(this, index, transformOrNull<Object>(index))
    };
  }

  int get vectorSize => (duckdb.bindings! as Bindings).duckdb_vector_size();

  DataChunkImpl dataChunkByIndex(int chunkIndex) {
    _throwIfStreaming('dataChunkByIndex');
    if (_currentChunkIndex != chunkIndex) {
      _currentChunk?.dispose();
      _currentChunk = null;
      _currentChunkIndex = -1;
    }

    if (_currentChunk == null) {
      _currentChunk = DataChunkImpl.withResult(this, chunkIndex);
      _currentChunkIndex = chunkIndex;
    }

    return _currentChunk!;
  }

  TItem? Function(int) transformer<TItem>(
    int columnIndex,
    Function(Vector<TItem>, int) body,
  ) {
    return (int itemIndex) {
      final closestSmallerOffsetIndex = _findClosestSmallerOffset(itemIndex);
      var chunkIndex = closestSmallerOffsetIndex != -1
          ? _chunkOffsetToChunkIndex[_chunkOffsets[closestSmallerOffsetIndex]]!
          : 0;

      var chunkRowOffset = closestSmallerOffsetIndex != -1
          ? _chunkOffsets[closestSmallerOffsetIndex]
          : 0;

      while (chunkIndex < chunkCount) {
        final chunk = dataChunkByIndex(chunkIndex);
        final chunkSize = chunk.count;

        if (itemIndex < chunkRowOffset + chunkSize) {
          return chunk.vectorAtIndex<TItem>(
            columnIndex,
            (vector) => body(vector, itemIndex - chunkRowOffset),
            _logicalType(columnIndex),
          );
        } else {
          chunkIndex++;
          chunkRowOffset += chunkSize;

          if (!_chunkOffsetToChunkIndex.containsKey(chunkRowOffset)) {
            _chunkOffsets.add(chunkRowOffset);
            _chunkOffsetToChunkIndex[chunkRowOffset] = chunkIndex;
          }
        }
      }

      throw RangeError.range(
        itemIndex,
        0,
        chunkCount - 1,
        'index',
        'Index out of bounds',
      );
    };
  }

  var _lastFoundOffset = 0;
  int _findClosestSmallerOffset(int itemIndex) {
    // Early exit for common cases
    if (_chunkOffsets.isEmpty) return -1;
    if (itemIndex < _chunkOffsets[0]) return -1;
    if (itemIndex >= _chunkOffsets.last) return _chunkOffsets.length - 1;

    // Try last successful position first
    if (_lastFoundOffset < _chunkOffsets.length &&
        _chunkOffsets[_lastFoundOffset] <= itemIndex &&
        (_lastFoundOffset + 1 == _chunkOffsets.length ||
            _chunkOffsets[_lastFoundOffset + 1] > itemIndex)) {
      return _lastFoundOffset;
    }

    // Galloping search: Instead of checking every element or
    // doing a standard binary search, we first try to find the range where our value
    // might be by checking positions that grow exponentially (1, 2, 4, 8, 16...).
    // This is especially efficient for sequential access patterns as it quickly
    // finds the right neighborhood before switching to binary search.
    var i = 1;
    while (i < _chunkOffsets.length && _chunkOffsets[i] <= itemIndex) {
      i = i << 1;
    }

    // Binary search in the identified range
    var low = i >> 1;
    var high = min(i, _chunkOffsets.length - 1);

    while (low < high) {
      final mid = (low + high + 1) >>> 1;
      if (_chunkOffsets[mid] <= itemIndex) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }

    _lastFoundOffset = low;
    return low;
  }
}

class _StreamingMetadata {
  final int columnCount;
  final List<String> columnNames;
  final List<int> columnTypes;
  final List<bool> jsonColumns;
  final List<LogicalType> logicalTypes;
  bool _isDisposed = false;

  _StreamingMetadata({
    required this.columnCount,
    required this.columnNames,
    required this.columnTypes,
    required this.jsonColumns,
    required this.logicalTypes,
  });

  factory _StreamingMetadata.read(
    Bindings bindings,
    Pointer<duckdb_result> result,
  ) {
    final count = bindings.duckdb_column_count(result);
    final names = <String>[];
    final types = <int>[];
    final jsonColumns = <bool>[];
    final logicalTypes = <LogicalType>[];

    try {
      for (var index = 0; index < count; index++) {
        names.add(bindings.duckdb_column_name(result, index).readString());
        types.add(bindings.duckdb_column_type(result, index).value);

        final logicalTypePointer = calloc<duckdb_logical_type>();
        logicalTypePointer.value =
            bindings.duckdb_column_logical_type(result, index);
        final logicalType = LogicalType.withLogicalType(logicalTypePointer);
        logicalTypes.add(logicalType);
        jsonColumns.add(logicalType.isJson);
      }

      return _StreamingMetadata(
        columnCount: count,
        columnNames: List<String>.unmodifiable(names),
        columnTypes: List<int>.unmodifiable(types),
        jsonColumns: List<bool>.unmodifiable(jsonColumns),
        logicalTypes: List<LogicalType>.unmodifiable(logicalTypes),
      );
    } catch (_) {
      for (final logicalType in logicalTypes) {
        logicalType.dispose();
      }
      rethrow;
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    for (final logicalType in logicalTypes) {
      logicalType.dispose();
    }
  }
}

class _StreamingResultResources {
  final ConnectionImpl connection;
  final Bindings bindings;
  final Pointer<duckdb_result> result;
  final _StreamingMetadata metadata;

  Future<Pointer<duckdb_data_chunk>>? _fetchInFlight;
  Future<void>? _closeFuture;
  Pointer<duckdb_data_chunk>? _currentChunk;
  Future<void>? _chunkDestroyFuture;
  bool _closing = false;
  bool _isNativeClosed = false;
  bool _cancelled = false;

  _StreamingResultResources(
    this.connection,
    this.bindings,
    this.result,
    this.metadata,
  );

  bool get isNativeClosed => _isNativeClosed;
  bool get isCancelled => _cancelled;
  bool get isClosing => _closing;

  Future<Pointer<duckdb_data_chunk>> fetchChunk() {
    if (_closing || _isNativeClosed) {
      throw StateError('Streaming result has been disposed');
    }
    if (_fetchInFlight != null) {
      throw StateError(
        'Only one native streaming chunk fetch may run at a time',
      );
    }

    connection._streamingLease.beginFetch(this);
    final chunk = calloc<duckdb_data_chunk>();
    _adoptFetchedChunk(chunk);
    final loseAcknowledgement =
        StreamingTestHooks._takeFetchAcknowledgementLoss();

    Future<int> nativeFetch;
    try {
      nativeFetch = connection._isolate
          .execute(
            FetchStreamingChunkOperation(
              result.address,
              chunk.address,
              dropAcknowledgement: loseAcknowledgement,
            ),
          )
          .$2;
    } catch (_) {
      _currentChunk = null;
      calloc.free(chunk);
      connection._streamingLease.finishFetch(this);
      rethrow;
    }

    // The owner adopts the caller-allocated cell before dispatch. A deliberate
    // acknowledgement loss is recoverable because the settled operation has
    // already populated this stable cell.
    final fetched = nativeFetch.then(
      (_) => _runAfterFetchAdoptionHook(chunk),
      onError: (Object error, StackTrace stackTrace) async {
        if (!loseAcknowledgement) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        return _runAfterFetchAdoptionHook(chunk);
      },
    );
    final settled = fetched.whenComplete(() {
      _fetchInFlight = null;
      connection._streamingLease.finishFetch(this);
    });
    _fetchInFlight = settled;
    return settled;
  }

  Future<Pointer<duckdb_data_chunk>> _runAfterFetchAdoptionHook(
    Pointer<duckdb_data_chunk> chunk,
  ) async {
    final hook = StreamingTestHooks.afterStreamingFetchBeforeAdoption;
    if (hook != null) {
      await hook();
    }
    return chunk;
  }

  void _adoptFetchedChunk(Pointer<duckdb_data_chunk> chunk) {
    if (_currentChunk != null) {
      throw StateError('A streaming data chunk is already active');
    }
    _currentChunk = chunk;
  }

  Future<void> destroyCurrentChunk() {
    final existingDestroy = _chunkDestroyFuture;
    if (existingDestroy != null) return existingDestroy;

    final chunk = _currentChunk;
    if (chunk == null) return Future<void>.value();

    final destroy = _destroyCurrentChunk(chunk);
    _chunkDestroyFuture = destroy;
    unawaited(
      destroy.then(
        (_) {
          if (identical(_chunkDestroyFuture, destroy)) {
            _chunkDestroyFuture = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_chunkDestroyFuture, destroy)) {
            _chunkDestroyFuture = null;
          }
        },
      ),
    );
    return destroy;
  }

  Future<void> _destroyCurrentChunk(
    Pointer<duckdb_data_chunk> chunk,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < 2; attempt++) {
      if (chunk.value.isNullPointer) {
        calloc.free(chunk);
        if (identical(_currentChunk, chunk)) {
          _currentChunk = null;
        }
        return;
      }

      try {
        await connection._isolate
            .execute(
              DestroyStreamingChunkOperation(
                chunk.address,
                dropAcknowledgement:
                    StreamingTestHooks._takeDestroyAcknowledgementLoss(),
              ),
            )
            .$2;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }

      // An acknowledgement can be lost after DuckDB consumed the chunk cell.
      // Only retry while the owner can still see a live native chunk.
      if (chunk.value.isNullPointer) {
        calloc.free(chunk);
        if (identical(_currentChunk, chunk)) {
          _currentChunk = null;
        }
        return;
      }
    }

    if (lastError != null && lastStackTrace != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace);
    }
    throw StateError('Native streaming chunk destruction was not acknowledged');
  }

  Future<void> close({bool fromConnectionDispose = false}) {
    if (_isNativeClosed) return Future.value();
    return connection._closeStreamingResource(
      this,
      fromConnectionDispose: fromConnectionDispose,
    );
  }

  void cancel() {
    if (_isNativeClosed || _cancelled) return;
    _cancelled = true;
    if (!connection._isClosed) {
      bindings.duckdb_interrupt(connection._handle.value);
    }
    closeSilently();
  }

  void closeSilently() {
    unawaited(
      close().catchError((Object _) {
        // An isolate failure leaves the native cells retained by this resource
        // and its lease. Retrying without acknowledgement could double-free.
      }),
    );
  }

  void _markClosing() {
    _closing = true;
  }

  void _markNativeClosed() {
    _isNativeClosed = true;
    _markClosing();
    metadata.dispose();
  }
}

/// A token retains this gate, not the active streaming result or its
/// connection. The lease remains the intentional owner while a stream is live.
class _StreamingResultCancellationGate {
  final WeakReference<_StreamingResultResources> _resources;

  _StreamingResultCancellationGate(_StreamingResultResources resources)
      : _resources = WeakReference(resources);

  void cancel() {
    _resources.target?.cancel();
  }
}

/// Deterministic barriers used only by native lifecycle tests.
///
/// Production keeps these callbacks null, so no barrier is awaited on the
/// streaming hot path. They intentionally live under `src/` and are not part
/// of the package's public export surface.
@visibleForTesting
class StreamingTestHooks {
  @visibleForTesting
  static Future<void> Function()? beforeStreamingHandoff;

  @visibleForTesting
  static Future<void> Function()? afterStreamingFetchBeforeAdoption;

  static bool _loseNextExecuteAcknowledgement = false;
  static bool _loseNextFetchAcknowledgement = false;
  static bool _loseNextDestroyAcknowledgement = false;

  @visibleForTesting
  static void loseNextExecuteAcknowledgement() {
    _loseNextExecuteAcknowledgement = true;
  }

  @visibleForTesting
  static void loseNextFetchAcknowledgement() {
    _loseNextFetchAcknowledgement = true;
  }

  @visibleForTesting
  static void loseNextDestroyAcknowledgement() {
    _loseNextDestroyAcknowledgement = true;
  }

  static bool _takeExecuteAcknowledgementLoss() {
    final loseAcknowledgement = _loseNextExecuteAcknowledgement;
    _loseNextExecuteAcknowledgement = false;
    return loseAcknowledgement;
  }

  static bool _takeFetchAcknowledgementLoss() {
    final loseAcknowledgement = _loseNextFetchAcknowledgement;
    _loseNextFetchAcknowledgement = false;
    return loseAcknowledgement;
  }

  static bool _takeDestroyAcknowledgementLoss() {
    final loseAcknowledgement = _loseNextDestroyAcknowledgement;
    _loseNextDestroyAcknowledgement = false;
    return loseAcknowledgement;
  }

  @visibleForTesting
  static void reset() {
    beforeStreamingHandoff = null;
    afterStreamingFetchBeforeAdoption = null;
    _loseNextExecuteAcknowledgement = false;
    _loseNextFetchAcknowledgement = false;
    _loseNextDestroyAcknowledgement = false;
  }
}

Object? _detachStreamingValue(Object? value) {
  if (value is Uint8List) {
    return Uint8List.fromList(value);
  }
  if (value is JsonValue) {
    return JsonValue(
      _detachStreamingValue(value.value),
      isValid: value.isValid,
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map<Object?>((element) => _detachStreamingValue(element)),
    );
  }
  if (value is Map) {
    final detached = <Object?, Object?>{};
    for (final entry in value.entries) {
      detached[_detachStreamingValue(entry.key)] =
          _detachStreamingValue(entry.value);
    }
    return Map<Object?, Object?>.unmodifiable(detached);
  }
  return value;
}

class FetchStreamingChunkOperation extends DatabaseOperation {
  final int resultPointer;
  final int chunkCellPointer;
  final bool _dropAcknowledgement;

  const FetchStreamingChunkOperation(
    this.resultPointer,
    this.chunkCellPointer, {
    bool dropAcknowledgement = false,
  })  : _dropAcknowledgement = dropAcknowledgement,
        super(connectionPointer: 0);

  @override
  bool get dropAcknowledgementForTesting => _dropAcknowledgement;

  @override
  Future<int> execute() async {
    final bindings = (duckdb as DuckDB).bindings;
    final result = Pointer<duckdb_result>.fromAddress(resultPointer);
    final chunk = Pointer<duckdb_data_chunk>.fromAddress(chunkCellPointer);
    chunk.value = bindings.duckdb_fetch_chunk(result.ref);
    return 0;
  }
}

class DestroyStreamingChunkOperation extends DatabaseOperation {
  final int chunkCellPointer;
  final bool _dropAcknowledgement;

  const DestroyStreamingChunkOperation(
    this.chunkCellPointer, {
    bool dropAcknowledgement = false,
  })  : _dropAcknowledgement = dropAcknowledgement,
        super(connectionPointer: 0);

  @override
  bool get dropAcknowledgementForTesting => _dropAcknowledgement;

  @override
  Future<int> execute() async {
    final bindings = (duckdb as DuckDB).bindings;
    final chunk = Pointer<duckdb_data_chunk>.fromAddress(chunkCellPointer);
    if (!chunk.value.isNullPointer) {
      bindings.duckdb_destroy_data_chunk(chunk);
    }
    return 0;
  }
}

class DestroyStreamingResultOperation extends DatabaseOperation {
  final int resultPointer;
  final bool _dropAcknowledgement;

  const DestroyStreamingResultOperation(
    this.resultPointer, {
    bool dropAcknowledgement = false,
  })  : _dropAcknowledgement = dropAcknowledgement,
        super(connectionPointer: 0);

  @override
  bool get dropAcknowledgementForTesting => _dropAcknowledgement;

  @override
  Future<int> execute() async {
    final bindings = (duckdb as DuckDB).bindings;
    final result = Pointer<duckdb_result>.fromAddress(resultPointer);
    if (!_isStreamingResultCellEmpty(result)) {
      bindings.duckdb_destroy_result(result);
    }
    return 0;
  }
}
