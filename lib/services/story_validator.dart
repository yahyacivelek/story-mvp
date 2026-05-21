import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:json_schema/json_schema.dart';

/// Thrown when story JSON fails schema validation.
class StoryValidationException implements Exception {
  final List<String> errors;

  const StoryValidationException(this.errors);

  @override
  String toString() {
    final lines = errors.map((e) => '  • $e').join('\n');
    return 'Story JSON validation failed:\n$lines';
  }
}

/// Validates story JSON against [assets/schemas/story_schema.json].
class StoryValidator {
  StoryValidator._();

  static JsonSchema? _schema;

  /// Loads the bundled JSON Schema. Safe to call multiple times.
  static Future<void> init({String? schemaAssetPath}) async {
    if (_schema != null) return;
    final path = schemaAssetPath ?? 'assets/schemas/story_schema.json';
    final raw = await rootBundle.loadString(path);
    _schema = JsonSchema.create(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Loads schema from a JSON string (for unit tests).
  static void initFromSchemaString(String schemaJson) {
    _schema = JsonSchema.create(jsonDecode(schemaJson) as Map<String, dynamic>);
  }

  /// Validates [json] and throws [StoryValidationException] on failure.
  static void validate(Map<String, dynamic> json) {
    final schema = _schema;
    if (schema == null) {
      throw StateError(
        'StoryValidator.init() must be called before validating story JSON',
      );
    }

    final result = schema.validate(json);
    if (result.isValid) return;

    throw StoryValidationException(_formatErrors(result));
  }

  /// Decodes [source], validates, and returns the parsed map.
  static Map<String, dynamic> decodeAndValidate(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) {
      throw const StoryValidationException([
        'Root value must be a JSON object',
      ]);
    }
    validate(json);
    return json;
  }

  static List<String> _formatErrors(ValidationResults result) {
    if (result.errors.isEmpty) {
      return ['Unknown validation error'];
    }
    return result.errors.map((e) => '${e.instancePath}: ${e.message}').toList();
  }
}
