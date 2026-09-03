import 'dart:async';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:dart_duckdb/src/ffi/impl/implementation.dart';
import 'package:test/test.dart';

void main() {
  group('FFI dispatch/start cancellation handshake', () {
    late Database database;
    late Connection connection;

    setUp(() async {
      database = await duckdb.open(':memory:');
      connection = await duckdb.connect(database);
    });

    tearDown(() async {
      ConnectionIsolateTestHooks.reset();
      await connection.dispose();
      await database.dispose();
    });

    test(
      'cancellation between dispatch and start acknowledgement interrupts and settles',
      () async {
        final startMessageSeen = Completer<void>();
        final releaseStartAcknowledgement = Completer<void>();
        ConnectionIsolateTestHooks.beforeOperationStartAcknowledgement = (_) {
          if (!startMessageSeen.isCompleted) startMessageSeen.complete();
          return releaseStartAcknowledgement.future;
        };
        final token = DuckDBCancellationToken();
        final operation = connection.query(_longRunningQuery, token: token);

        await startMessageSeen.future.timeout(const Duration(seconds: 5));
        token.cancel();
        // Ensure cancellation observes the operation as dispatched but not yet
        // acknowledged before the test lets the acknowledgement through.
        await Future<void>.delayed(Duration.zero);
        releaseStartAcknowledgement.complete();

        await expectLater(
          operation.timeout(const Duration(seconds: 5)),
          throwsA(isA<DuckDBCancelledException>()),
        );
        final reusable = await connection.query('SELECT 42 AS answer');
        expect(reusable.fetchAll().single.single, 42);
      },
      testOn: 'vm',
    );

    test(
      'cancelling an undispatched queue entry removes only that entry',
      () async {
        final startMessageSeen = Completer<void>();
        final releaseStartAcknowledgement = Completer<void>();
        ConnectionIsolateTestHooks.beforeOperationStartAcknowledgement = (_) {
          if (!startMessageSeen.isCompleted) startMessageSeen.complete();
          return releaseStartAcknowledgement.future;
        };
        final firstToken = DuckDBCancellationToken();
        final secondToken = DuckDBCancellationToken();
        final first = connection.query(_longRunningQuery, token: firstToken);
        await startMessageSeen.future.timeout(const Duration(seconds: 5));
        final second =
            connection.query('SELECT 7 AS removed', token: secondToken);
        final third = connection.query('SELECT 43 AS reusable');
        final secondCancelled = expectLater(
          second.timeout(const Duration(seconds: 5)),
          throwsA(isA<DuckDBCancelledException>()),
        );
        final firstCancelled = expectLater(
          first.timeout(const Duration(seconds: 5)),
          throwsA(isA<DuckDBCancelledException>()),
        );

        secondToken.cancel();
        await Future<void>.delayed(Duration.zero);
        firstToken.cancel();
        releaseStartAcknowledgement.complete();

        await secondCancelled;
        await firstCancelled;
        final reusable = await third.timeout(const Duration(seconds: 5));
        expect(reusable.fetchAll().single.single, 43);
      },
      testOn: 'vm',
    );
  });
}

const _longRunningQuery = '''
  SELECT SUM(left_range.range + right_range.range)
  FROM range(10000000) AS left_range
  CROSS JOIN range(10000000) AS right_range
''';
