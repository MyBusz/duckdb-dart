// ignore: library_annotations
@TestOn('vm')

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:dart_duckdb/src/ffi/impl/implementation.dart';
import 'package:test/test.dart';

void main() {
  late Database database;
  late Connection connection;

  setUp(() async {
    StreamingTestHooks.reset();
    database = await duckdb.open(':memory:');
    connection = await duckdb.connect(database);
  });

  tearDown(() async {
    StreamingTestHooks.reset();
    await connection.dispose();
    await database.dispose();
  });

  Future<ResultSet> stream(
    String sql, {
    DuckDBCancellationToken? token,
    bool requireNativeStreaming = false,
  }) async {
    final statement = await connection.prepare(sql);
    return statement.executeStreaming(
      token: token,
      requireNativeStreaming: requireNativeStreaming,
    );
  }

  int countValue(Object value) => switch (value) {
        final int value => value,
        final BigInt value => value.toInt(),
        _ => throw StateError('Unexpected COUNT(*) value: $value'),
      };

  Future<int> countRows(String tableName) async {
    final result = await connection.query('SELECT COUNT(*) FROM $tableName');
    try {
      return countValue(result.fetchOne()!.single!);
    } finally {
      await result.dispose();
    }
  }

  Future<int> countTables(String tableName) async {
    final result = await connection.query('''
      SELECT COUNT(*)
      FROM information_schema.tables
      WHERE table_name = '$tableName'
    ''');
    try {
      return countValue(result.fetchOne()!.single!);
    } finally {
      await result.dispose();
    }
  }

  test('streams 100k rows in order, caches metadata, and releases at EOF',
      () async {
    final result = await stream(
      'SELECT range AS id, range::VARCHAR AS label FROM range(100000)',
    );
    expect(result.isStreaming, isTrue);
    expect(result.columnCount, 2);
    expect(result.columnNames, ['id', 'label']);
    expect(result.columnTypes, hasLength(2));
    expect(() => result.rowCount, throwsStateError);
    expect(() => result.fetchOne(), throwsStateError);
    expect(() => result.fetchAll(), throwsStateError);
    expect(() => result[0], throwsStateError);
    expect(() => (result as ResultSetImpl).chunkCount, throwsStateError);
    expect(() => result.handle, throwsStateError);

    var rowCount = 0;
    await for (final row in result.fetchAllStream(batchSize: 1)) {
      expect(row, [rowCount, '$rowCount']);
      rowCount++;
    }

    expect(rowCount, 100000);
    expect((await connection.query('SELECT 42')).fetchOne(), [42]);
    await result.dispose();
  });

  test(
      'materialized fallback retains normal result APIs when DuckDB chooses it',
      () async {
    final result = await stream(
      'CREATE TABLE fallback_table (id INTEGER)',
      requireNativeStreaming: false,
    );

    expect(result.isStreaming, isFalse);
    expect(result.rowCount, isA<int>());
    expect(result.fetchAll(), isA<List<List<Object?>>>());
    await result.dispose();
  });

  test('required native streaming accepts SELECT results', () async {
    final result = await stream(
      'SELECT range FROM range(3)',
      requireNativeStreaming: true,
    );

    expect(result.isStreaming, isTrue);
    expect(
      await result.fetchAllStream().map((row) => row.single).toList(),
      [0, 1, 2],
    );
  });

  test('required native streaming rejects mutations before side effects',
      () async {
    final create = await connection.prepare(
      'CREATE TABLE required_stream_create (id INTEGER)',
    );
    expect(
      () => create.executeStreaming(requireNativeStreaming: true),
      throwsStateError,
    );
    expect(await countTables('required_stream_create'), 0);
    await create.dispose();

    await connection.execute(
      'CREATE TABLE required_stream_data (id INTEGER)',
    );
    await connection.execute('INSERT INTO required_stream_data VALUES (1)');

    final insert = await connection.prepare(
      'INSERT INTO required_stream_data VALUES (2) RETURNING id',
    );
    expect(
      () => insert.executeStreaming(requireNativeStreaming: true),
      throwsStateError,
    );
    expect(await countRows('required_stream_data'), 1);
    await insert.dispose();

    final delete = await connection.prepare(
      'DELETE FROM required_stream_data WHERE id = 1 RETURNING id',
    );
    expect(
      () => delete.executeStreaming(requireNativeStreaming: true),
      throwsStateError,
    );
    expect(await countRows('required_stream_data'), 1);
    await delete.dispose();

    expect((await connection.query('SELECT 101')).fetchOne(), [101]);
  });

  test('multi-statement preparation rejects before a required stream executes',
      () async {
    await expectLater(
      () async {
        final statement = await connection.prepare('''
          SELECT 1;
          CREATE TABLE required_stream_multi (id INTEGER)
        ''');
        try {
          await statement.executeStreaming(requireNativeStreaming: true);
        } finally {
          await statement.dispose();
        }
      }(),
      throwsA(isA<DuckDBException>()),
    );

    expect(await countTables('required_stream_multi'), 0);
    expect((await connection.query('SELECT 102')).fetchOne(), [102]);
  });

  test('statement may be disposed after handoff while its stream is consumed',
      () async {
    final statement = await connection.prepare('SELECT range FROM range(10)');
    final result = await statement.executeStreaming();
    expect(result.isStreaming, isTrue);

    await statement.dispose();
    expect(
      await result.fetchAllStream().map((row) => row.single).toList(),
      List.generate(10, (index) => index),
    );
  });

  test('detaches direct and nested blobs across chunks and result disposal',
      () async {
    final result = await stream('''
      SELECT
        range AS id,
        '\\x01\\x02\\x03'::BLOB AS direct_blob,
        ['\\x04\\x05'::BLOB] AS list_blob,
        {'bytes': '\\x06\\x07'::BLOB} AS struct_blob,
        MAP {'bytes': '\\x08\\x09'::BLOB} AS map_blob
      FROM range(5000)
    ''');
    expect(result.isStreaming, isTrue);

    List<Object?>? first;
    await for (final row in result.fetchAllStream()) {
      first ??= row;
    }
    await result.dispose();

    expect(first![1], Uint8List.fromList([1, 2, 3]));
    expect((first[2]! as List).single, Uint8List.fromList([4, 5]));
    expect((first[3]! as Map)['bytes'], Uint8List.fromList([6, 7]));
    expect((first[4]! as Map)['bytes'], Uint8List.fromList([8, 9]));
  });

  test('preserves scalar, nested, union, and JSON values', () async {
    final result = await stream('''
      SELECT
        NULL::INTEGER AS nil,
        'duck' AS text_value,
        12.34::DECIMAL(4, 2) AS decimal_value,
        [1, 2] AS list_value,
        [3, 4]::INTEGER[2] AS array_value,
        {'answer': 5} AS struct_value,
        MAP {'answer': 6} AS map_value,
        union_value(text := 'union')::UNION(number INTEGER, text VARCHAR)
          AS union_value,
        '{"ready": true}'::JSON AS json_value,
        ['{"list": true}'::JSON] AS json_list,
        {'nested': '{"struct": true}'::JSON} AS json_struct,
        MAP {'nested': '{"map": true}'::JSON} AS json_map,
        union_value(json := '{"union": true}'::JSON)
          ::UNION(json JSON, text VARCHAR) AS json_union
    ''');
    final row = await result.fetchAllStream().single;

    expect(row[0], isNull);
    expect(row[1], 'duck');
    expect(row[2], Decimal.parse('12.34'));
    expect(row[3], [1, 2]);
    expect(row[4], [3, 4]);
    expect(row[5], {'answer': 5});
    expect(row[6], {'answer': 6});
    expect(row[7], 'union');
    expect(row[8], isA<JsonValue>());
    expect((row[8]! as JsonValue).value, {'ready': true});
    expect((row[9]! as List).single, isA<JsonValue>());
    expect(((row[9]! as List).single! as JsonValue).value, {'list': true});
    expect((row[10]! as Map)['nested'], isA<JsonValue>());
    expect(
      ((row[10]! as Map)['nested']! as JsonValue).value,
      {'struct': true},
    );
    expect((row[11]! as Map)['nested'], isA<JsonValue>());
    expect(
      ((row[11]! as Map)['nested']! as JsonValue).value,
      {'map': true},
    );
    expect(row[12], isA<JsonValue>());
    expect((row[12]! as JsonValue).value, {'union': true});
  });

  test('blocks every competing connection and prepared operation', () async {
    final streaming = await connection.prepare('SELECT range FROM range(10)');
    final other = await connection.prepare('SELECT ?');
    other.bind(1, 1);
    final result = await streaming.executeStreaming();

    await expectLater(connection.query('SELECT 1'), throwsStateError);
    await expectLater(connection.execute('SELECT 1'), throwsStateError);
    await expectLater(connection.prepare('SELECT 1'), throwsStateError);
    await expectLater(
      connection.append('missing_table', null),
      throwsStateError,
    );
    await expectLater(
      connection.getColumnOrder('missing_table'),
      throwsStateError,
    );
    await expectLater(other.execute(), throwsStateError);
    await expectLater(other.executePending(), throwsStateError);
    expect(() => other.executeStreaming(), throwsStateError);
    expect(() => other.parameterCount, throwsStateError);
    expect(() => other.parameterType(1), throwsStateError);
    expect(() => other.bind(2, 1), throwsStateError);
    expect(() => other.bindParams([]), throwsStateError);
    expect(() => other.bindNamed(2, 'missing'), throwsStateError);
    expect(() => other.bindNamedParams({}), throwsStateError);
    expect(() => other.clearBinding(), throwsStateError);
    expect(() => streaming.parameterCount, throwsStateError);
    expect(() => streaming.bind(1, 1), throwsStateError);
    expect(() => streaming.bindParams([]), throwsStateError);
    expect(() => streaming.clearBinding(), throwsStateError);

    await result.dispose();
    expect((await other.execute()).fetchOne(), [BigInt.one]);
    await other.dispose();
    await streaming.dispose();
  });

  test('blocks statement mutation while a streaming handoff is in flight',
      () async {
    final statement = await connection.prepare('SELECT ?');
    statement.bind(1, 1);
    final execution = statement.executeStreaming();

    expect(() => statement.parameterCount, throwsStateError);
    expect(() => statement.parameterType(1), throwsStateError);
    expect(() => statement.bind(2, 1), throwsStateError);
    expect(() => statement.bindParams([]), throwsStateError);
    expect(() => statement.bindNamed(2, 'missing'), throwsStateError);
    expect(() => statement.bindNamedParams({}), throwsStateError);
    expect(() => statement.clearBinding(), throwsStateError);
    await expectLater(statement.execute(), throwsStateError);
    await expectLater(statement.executePending(), throwsStateError);
    expect(() => statement.executeStreaming(), throwsStateError);

    final result = await execution;
    await result.dispose();
    await statement.dispose();
  });

  test('appender and stream conflict in both directions', () async {
    await connection.execute('CREATE TABLE values_table (id INTEGER)');
    final appender = await connection.append('values_table', null);
    final statement = await connection.prepare('SELECT range FROM range(2)');
    expect(() => statement.executeStreaming(), throwsStateError);
    appender.dispose();

    final result = await statement.executeStreaming();
    await expectLater(
      connection.append('values_table', null),
      throwsStateError,
    );
    await result.dispose();
    await statement.dispose();
  });

  test('failed appender creation releases registration for streaming',
      () async {
    await expectLater(
      connection.append('missing_table', null),
      throwsA(isA<DuckDBException>()),
    );

    final statement = await connection.prepare('SELECT range FROM range(2)');
    final result = await statement.executeStreaming();
    expect(result.isStreaming, isTrue);
    expect(await result.fetchAllStream().length, 2);
    await statement.dispose();
  });

  test('unconsumed results support idempotent dispose and connection reuse',
      () async {
    final result = await stream('SELECT range FROM range(100)');
    await result.dispose();
    await result.dispose();

    expect((await connection.query('SELECT 7')).fetchOne(), [7]);
  });

  test('early break keeps the connection leased until explicit disposal',
      () async {
    final result = await stream('SELECT range FROM range(10000)');
    var rows = 0;
    await for (final _ in result.fetchAllStream()) {
      rows++;
      break;
    }

    expect(rows, 1);
    await expectLater(connection.query('SELECT 1'), throwsStateError);
    await result.dispose();
    expect((await connection.query('SELECT 1')).fetchOne(), [1]);
  });

  test('cancellation closes the stream and permits reuse', () async {
    final token = DuckDBCancellationToken();
    final result = await stream(
      'SELECT range FROM range(10000)',
      token: token,
    );
    var rows = 0;

    await expectLater(
      () async {
        await for (final _ in result.fetchAllStream()) {
          rows++;
          if (rows == 2048) {
            token.cancel();
          }
        }
      }(),
      throwsA(isA<DuckDBCancelledException>()),
    );

    expect(rows, 2048);
    expect((await connection.query('SELECT 3')).fetchOne(), [3]);
  });

  test('execute-time failure releases the connection lease', () async {
    final statement = await connection.prepare('SELECT CAST(? AS INTEGER)');
    statement.bind('not an integer', 1);

    await expectLater(
      statement.executeStreaming(),
      throwsA(isA<DuckDBException>()),
    );
    expect((await connection.query('SELECT 11')).fetchOne(), [11]);
    await statement.dispose();
  });

  test('connection disposal during an active stream ends iteration cleanly',
      () async {
    final result = await stream('SELECT range FROM range(10000)');
    final iterator = StreamIterator(result.fetchAllStream());
    expect(await iterator.moveNext(), isTrue);

    await connection.dispose();
    await expectLater(iterator.moveNext(), throwsA(isA<StateError>()));
    await connection.dispose();
    await iterator.cancel();
  });

  test('cancellation after fetch returns waits for owned chunk adoption',
      () async {
    final token = DuckDBCancellationToken();
    final reachedBarrier = Completer<void>();
    final releaseBarrier = Completer<void>();
    StreamingTestHooks.afterStreamingFetchBeforeAdoption = () {
      reachedBarrier.complete();
      return releaseBarrier.future;
    };

    final result = await stream('SELECT range FROM range(10)', token: token);
    final iterator = StreamIterator(result.fetchAllStream());
    final next = iterator.moveNext();
    await reachedBarrier.future;

    token.cancel();
    releaseBarrier.complete();
    await expectLater(next, throwsA(isA<DuckDBCancelledException>()));
    await iterator.cancel();
    expect((await connection.query('SELECT 5')).fetchOne(), [5]);
  });

  test('result disposal after fetch returns waits for owned chunk adoption',
      () async {
    final reachedBarrier = Completer<void>();
    final releaseBarrier = Completer<void>();
    StreamingTestHooks.afterStreamingFetchBeforeAdoption = () {
      reachedBarrier.complete();
      return releaseBarrier.future;
    };

    final result = await stream('SELECT range FROM range(10)');
    final iterator = StreamIterator(result.fetchAllStream());
    final next = iterator.moveNext();
    await reachedBarrier.future;

    final dispose = result.dispose();
    releaseBarrier.complete();
    await dispose;
    await expectLater(next, throwsA(isA<StateError>()));
    await iterator.cancel();
    expect((await connection.query('SELECT 6')).fetchOne(), [6]);
  });

  test('connection disposal after fetch returns waits for owned chunk adoption',
      () async {
    final reachedBarrier = Completer<void>();
    final releaseBarrier = Completer<void>();
    StreamingTestHooks.afterStreamingFetchBeforeAdoption = () {
      reachedBarrier.complete();
      return releaseBarrier.future;
    };

    final result = await stream('SELECT range FROM range(10)');
    final iterator = StreamIterator(result.fetchAllStream());
    final next = iterator.moveNext();
    await reachedBarrier.future;

    final dispose = connection.dispose();
    final nextExpectation = expectLater(next, throwsA(isA<StateError>()));
    releaseBarrier.complete();
    await dispose;
    await nextExpectation;
    await iterator.cancel();
  });

  test('connection disposal during execution handoff destroys before teardown',
      () async {
    final reachedBarrier = Completer<void>();
    final releaseBarrier = Completer<void>();
    StreamingTestHooks.beforeStreamingHandoff = () {
      reachedBarrier.complete();
      return releaseBarrier.future;
    };

    final statement = await connection.prepare('SELECT range FROM range(10)');
    final execution = statement.executeStreaming();
    await reachedBarrier.future;

    final dispose = connection.dispose();
    releaseBarrier.complete();
    await expectLater(execution, throwsA(isA<StateError>()));
    await dispose;
  });

  test('streaming batchSize must be positive and EOF is reusable', () async {
    final invalidZero = await stream('SELECT range FROM range(1)');
    expect(() => invalidZero.fetchAllStream(batchSize: 0), throwsArgumentError);
    await invalidZero.dispose();

    final invalidNegative = await stream('SELECT range FROM range(1)');
    expect(
      () => invalidNegative.fetchAllStream(batchSize: -1),
      throwsArgumentError,
    );
    await invalidNegative.dispose();

    final empty = await stream('SELECT range FROM range(0)');
    expect(await empty.fetchAllStream().toList(), isEmpty);
    expect((await connection.query('SELECT 99')).fetchOne(), [99]);
  });

  test('lost execute acknowledgement preserves ownership and connection reuse',
      () async {
    final statement = await connection.prepare('SELECT range FROM range(3)');
    StreamingTestHooks.loseNextExecuteAcknowledgement();

    final result = await statement.executeStreaming();
    expect(
      await result.fetchAllStream().map((row) => row.single).toList(),
      [0, 1, 2],
    );
    await result.dispose();

    expect((await connection.query('SELECT 71')).fetchOne(), [71]);
    await statement.dispose();
  });

  test('lost fetch acknowledgement adopts and cleans the fetched chunk',
      () async {
    final result = await stream('SELECT range FROM range(3)');
    StreamingTestHooks.loseNextFetchAcknowledgement();

    expect(
      await result.fetchAllStream().map((row) => row.single).toList(),
      [0, 1, 2],
    );
    await result.dispose();

    expect((await connection.query('SELECT 72')).fetchOne(), [72]);
  });

  test('lost destroy acknowledgement cleans the result and permits reuse',
      () async {
    final result = await stream('SELECT range FROM range(3)');
    StreamingTestHooks.loseNextDestroyAcknowledgement();

    await result.dispose();
    expect((await connection.query('SELECT 73')).fetchOne(), [73]);
  });

  test('result disposal is idempotent after a lost destroy acknowledgement',
      () async {
    final result = await stream('SELECT range FROM range(3)');
    StreamingTestHooks.loseNextDestroyAcknowledgement();

    await result.dispose();
    await result.dispose();

    expect((await connection.query('SELECT 74')).fetchOne(), [74]);
  });

  test('connection disposal is idempotent after a lost destroy acknowledgement',
      () async {
    final result = await stream('SELECT range FROM range(3)');
    StreamingTestHooks.loseNextDestroyAcknowledgement();

    await connection.dispose();
    await result.dispose();
    await connection.dispose();
  });
}
