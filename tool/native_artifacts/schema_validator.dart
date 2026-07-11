import 'errors.dart';

final class JsonSchemaValidator {
  JsonSchemaValidator(this.schema);

  final Map<String, Object?> schema;

  void validate(Object? value) => _validate(value, schema, r'$');

  void _validate(Object? value, Map<String, Object?> rule, String path) {
    final reference = rule[r'$ref'];
    if (reference != null) {
      if (reference is! String || !reference.startsWith(r'#/$defs/')) {
        fail('$path uses an unsupported schema reference');
      }
      _validate(value, _resolve(reference), path);
    }

    final allOf = rule['allOf'];
    if (allOf != null) {
      if (allOf is! List<Object?>) fail('$path has an invalid allOf rule');
      for (final child in allOf) {
        _validate(value, _schemaMap(child, path), path);
      }
    }

    final type = rule['type'];
    if (type != null && !_hasType(value, type)) {
      fail('$path must be $type');
    }
    if (rule.containsKey('const') && !_jsonEquals(value, rule['const'])) {
      fail('$path has an unexpected value');
    }
    final enumValues = rule['enum'];
    if (enumValues != null) {
      if (enumValues is! List<Object?> ||
          !enumValues.any((candidate) => _jsonEquals(value, candidate))) {
        fail('$path has an unsupported value');
      }
    }

    if (value is String) _validateString(value, rule, path);
    if (value is int) _validateInteger(value, rule, path);
    if (value is List<Object?>) _validateArray(value, rule, path);
    if (value is Map<String, Object?>) _validateObject(value, rule, path);
  }

  void _validateString(
    String value,
    Map<String, Object?> rule,
    String path,
  ) {
    final pattern = rule['pattern'];
    if (pattern != null) {
      if (pattern is! String || !RegExp(pattern).hasMatch(value)) {
        fail('$path has an invalid string value');
      }
    }
  }

  void _validateInteger(
    int value,
    Map<String, Object?> rule,
    String path,
  ) {
    final minimum = rule['minimum'];
    if (minimum != null && (minimum is! num || value < minimum)) {
      fail('$path is below its minimum');
    }
  }

  void _validateArray(
    List<Object?> value,
    Map<String, Object?> rule,
    String path,
  ) {
    final minimum = rule['minItems'];
    final maximum = rule['maxItems'];
    if (minimum is int && value.length < minimum) fail('$path is too short');
    if (maximum is int && value.length > maximum) fail('$path is too long');

    final prefix = rule['prefixItems'];
    var prefixLength = 0;
    if (prefix != null) {
      if (prefix is! List<Object?>) fail('$path has invalid prefix items');
      prefixLength = prefix.length;
      for (var index = 0;
          index < value.length && index < prefix.length;
          index++) {
        _validate(
          value[index],
          _schemaMap(prefix[index], path),
          '$path[$index]',
        );
      }
    }
    final items = rule['items'];
    if (items == false && value.length > prefixLength) {
      fail('$path has unexpected items');
    } else if (items is Map<Object?, Object?>) {
      final itemRule = _schemaMap(items, path);
      for (var index = prefixLength; index < value.length; index++) {
        _validate(value[index], itemRule, '$path[$index]');
      }
    }
    if (rule['uniqueItems'] == true) {
      for (var left = 0; left < value.length; left++) {
        for (var right = left + 1; right < value.length; right++) {
          if (_jsonEquals(value[left], value[right])) {
            fail('$path contains duplicate items');
          }
        }
      }
    }
  }

  void _validateObject(
    Map<String, Object?> value,
    Map<String, Object?> rule,
    String path,
  ) {
    final required = rule['required'];
    if (required != null) {
      if (required is! List<Object?> || required.any((key) => key is! String)) {
        fail('$path has an invalid required rule');
      }
      for (final key in required.cast<String>()) {
        if (!value.containsKey(key)) fail('$path is missing $key');
      }
    }

    final properties = rule['properties'];
    if (properties != null && properties is! Map<Object?, Object?>) {
      fail('$path has invalid properties');
    }
    final propertyRules = properties == null
        ? const <String, Object?>{}
        : (properties as Map<Object?, Object?>).cast<String, Object?>();
    for (final entry in propertyRules.entries) {
      if (value.containsKey(entry.key)) {
        _validate(
          value[entry.key],
          _schemaMap(entry.value, '$path.${entry.key}'),
          '$path.${entry.key}',
        );
      }
    }

    if (rule['additionalProperties'] == false) {
      final extras = value.keys.where((key) => !propertyRules.containsKey(key));
      if (extras.isNotEmpty) fail('$path contains an unknown field');
    }
    if (rule['unevaluatedProperties'] == false) {
      final known = _collectProperties(rule);
      if (value.keys.any((key) => !known.contains(key))) {
        fail('$path contains an unknown field');
      }
    }
  }

  Set<String> _collectProperties(Map<String, Object?> rule) {
    final result = <String>{};
    final reference = rule[r'$ref'];
    if (reference is String) {
      result.addAll(_collectProperties(_resolve(reference)));
    }
    final allOf = rule['allOf'];
    if (allOf is List<Object?>) {
      for (final child in allOf) {
        result.addAll(_collectProperties(_schemaMap(child, r'$')));
      }
    }
    final properties = rule['properties'];
    if (properties is Map<Object?, Object?>) {
      result.addAll(properties.keys.cast<String>());
    }
    return result;
  }

  Map<String, Object?> _resolve(String reference) {
    Object? current = schema;
    for (final encoded in reference.substring(2).split('/')) {
      final key = encoded.replaceAll('~1', '/').replaceAll('~0', '~');
      if (current is! Map<String, Object?> || !current.containsKey(key)) {
        fail('The native artifact schema contains an invalid reference');
      }
      current = current[key];
    }
    return _schemaMap(current, r'$');
  }

  static Map<String, Object?> _schemaMap(Object? value, String path) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      fail('$path has an invalid schema rule');
    }
    return value.cast<String, Object?>();
  }

  static bool _hasType(Object? value, Object? type) => switch (type) {
        'object' => value is Map<String, Object?>,
        'array' => value is List<Object?>,
        'string' => value is String,
        'integer' => value is int,
        'boolean' => value is bool,
        _ => false,
      };

  static bool _jsonEquals(Object? left, Object? right) {
    if (left is List<Object?> && right is List<Object?>) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_jsonEquals(left[index], right[index])) return false;
      }
      return true;
    }
    if (left is Map<Object?, Object?> && right is Map<Object?, Object?>) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_jsonEquals(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    return left == right;
  }
}
