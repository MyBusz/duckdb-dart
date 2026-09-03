// ignore_for_file: unintended_html_in_doc_comment

import 'dart:async';

import 'package:dart_duckdb/dart_duckdb.dart';

/// An object reperesenting a DuckDB prepared statement
///
/// A prepared statement is a parameterized query. The query is prepared with
/// question marks (`?`), dollar symbols (`$1`), or named parameers (`$VVV`)
/// where VVV is alphanumeric, indicating the parameters of the query. Values can then
/// be bound to these parameters, after which the prepared statement can be executed
/// using those parameters. A single query can be prepared once and executed many times.
/// see: https://duckdb.org/docs/api/python/dbapi#named-parameters
///
/// Prepared statements are useful to:
///
///   - Easily supply parameters to functions while avoiding string
///     concatenation/SQL injection attacks.
///   - Speed up queries that will be executed many times with different
///     parameters.
///
/// The following example creates a prepared statement that allows parameters
/// to be bound in two positions within a 'select' statement. The prepared
/// statement is finally executed by calling ``PreparedStatement/execute()``.
///
/// ```dart
///   Connection connection = ...
///   connection.execute("CREATE TABLE t1(col1 TEXT, col2 TEXT);");
///   PreparedStatement statement = PreparedStatementImpl.prepare(
///     connection,
///     "INSERT INTO t1 VALUES ($col1, $col2, $col3)",
///   );
///   statement.bindNamedParams({'col1': 'val1', 'col2': 'val2'});
///   statement.execute();
///   ResultSet result = connection.query("SELECT * FROM t1;");
/// ```
abstract class PreparedStatement {
  /// Returns the amount of parameters in this prepared statement.
  int get parameterCount;

  DatabaseType parameterType(int index);

  /// Binds a value at the specified parameter index
  ///
  /// Sets the value that will be used for the next call to ``execute()``.
  ///
  /// - Important: Prepared statement parameters use one-based indexing
  /// - Parameter value: the value to bind
  /// - Parameter index: the one-based parameter index
  /// - Throws: ``DuckDBException``
  ///   if there is a type-mismatch between the value being bound and the
  ///   underlying column type
  void bind(Object? param, int index);

  /// Binds an ordered list of values
  void bindParams(List params);

  /// Binds a named value
  void bindNamed(Object? param, String name);

  /// Binds a map of named values, where the key is the name
  void bindNamedParams(Map<String, Object?> params);

  /// Executes the prepared statement
  ///
  /// Issues the parameterized query to the database using the values previously
  /// bound via the bind methods
  Future<ResultSet> execute({DuckDBCancellationToken? token});

  /// Executes the prepared statement asynchronously, and receive progress updates
  ///
  /// Issues the parameterized query to the database using the values previously
  /// bound via the bind methods. Returns a CancelableOperation that can be used
  /// to cancel the operation if needed.
  ///
  /// Returns: A CancelableOperation<ResultSet?> that completes with the query result
  /// or null if the operation was cancelled.
  Future<ResultSet?> executePending({DuckDBCancellationToken? token});

  /// Executes the prepared statement using DuckDB's native streaming result
  /// interface.
  ///
  /// The returned [ResultSet] reports whether DuckDB actually selected a
  /// streaming result through [ResultSet.isStreaming]. A materialized fallback
  /// retains the normal result-set APIs. For a streaming result, consume the
  /// one-shot [ResultSet.fetchAllStream] and always dispose the result when
  /// leaving the stream early:
  ///
  /// ```dart
  /// final result = await statement.executeStreaming();
  /// try {
  ///   await for (final row in result.fetchAllStream()) {
  ///     // Process row.
  ///   }
  /// } finally {
  ///   await result.dispose();
  /// }
  /// ```
  ///
  /// Breaking or cancelling a streaming subscription does not release the
  /// connection lease; [ResultSet.dispose] does.
  ///
  /// When [requireNativeStreaming] is true, only a prepared `SELECT` is
  /// accepted. The call fails before execution for every other statement type.
  /// If DuckDB still returns a materialized result for an accepted `SELECT`, it
  /// is disposed and the call fails rather than exposing a non-streaming result.
  Future<ResultSet> executeStreaming({
    DuckDBCancellationToken? token,
    bool requireNativeStreaming = false,
  });

  /// Clear the params bound to the prepared statement.
  void clearBinding();

  /// Disposes this statement and releases associated memory.
  Future<void> dispose();
}
