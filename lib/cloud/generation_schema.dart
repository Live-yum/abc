/// A runtime schema. No server-specific schema is bundled with the app.
class GenerationSchema {
  GenerationSchema(this.revision, this.root, this.types);
  factory GenerationSchema.fromJson(Map<String, dynamic> json) =>
      GenerationSchema(
        json['revision'] as String,
        Map<String, dynamic>.from(json['root'] as Map),
        Map<String, dynamic>.from(json['types'] as Map),
      );
  final String revision;
  final Map<String, dynamic> root, types;
  static const maxDepth = 12;
  static const maxItems = 256;

  Map<String, dynamic>? fields(Map<String, dynamic> field) {
    final ref = field['ref'];
    final value = ref == null ? field['fields'] : types[ref];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  List<String> validate(Map<String, dynamic> value) {
    final errors = <String>[];
    _object(root, value, 'config', 0, errors);
    return errors;
  }

  void _object(
    Map<String, dynamic> fields,
    Map value,
    String path,
    int depth,
    List<String> errors,
  ) {
    if (depth > maxDepth) {
      errors.add('$path: maximum nesting exceeded');
      return;
    }
    if (value.length > maxItems) {
      errors.add('$path: too many fields');
      return;
    }
    for (final entry in value.entries) {
      final field = fields[entry.key];
      if (field is! Map) {
        errors.add('$path.${entry.key}: unknown field');
        continue;
      }
      _value(
        Map<String, dynamic>.from(field),
        entry.value,
        '$path.${entry.key}',
        depth + 1,
        errors,
      );
    }
  }

  void _value(
    Map<String, dynamic> field,
    dynamic value,
    String path,
    int depth,
    List<String> errors,
  ) {
    if (depth > maxDepth) {
      errors.add('$path: maximum nesting exceeded');
      return;
    }
    if (field['readOnly'] == true) {
      errors.add('$path: read-only field');
      return;
    }
    if (value == null) {
      return; // omitted/default values are nullable in this contract.
    }
    bool valid;
    switch (field['kind']) {
      case 'boolean':
        valid = value is bool;
      case 'string':
        valid = value is String && value.length <= 8192;
      case 'integer':
        valid = value is int;
      case 'number':
        valid = value is num && value.isFinite;
      case 'object':
        final nested = fields(field);
        valid = value is Map && nested != null;
        if (valid) _object(nested, value, path, depth, errors);
      case 'array':
        valid =
            value is List && value.length <= maxItems && field['item'] is Map;
        if (valid) {
          for (var i = 0; i < (value).length; i++) {
            _value(
              Map<String, dynamic>.from(field['item'] as Map),
              value[i],
              '$path[$i]',
              depth + 1,
              errors,
            );
          }
        }
      case 'map':
        valid =
            value is Map && value.length <= maxItems && field['item'] is Map;
        if (valid) {
          for (final entry in (value).entries) {
            if (entry.key is! String ||
                (field['keyKind'] == 'integer' &&
                    int.tryParse(entry.key as String) == null)) {
              errors.add('$path: invalid map key');
            }
            _value(
              Map<String, dynamic>.from(field['item'] as Map),
              entry.value,
              '$path.${entry.key}',
              depth + 1,
              errors,
            );
          }
        }
      case 'any':
        valid = _boundedJson(value, depth);
      default:
        valid = false;
    }
    if (!valid) {
      errors.add('$path: invalid ${field['kind']} value or schema');
      return;
    }
    if (value is num) {
      if (field['min'] is num && value < field['min']) {
        errors.add('$path: below minimum');
      }
      if (field['max'] is num && value > field['max']) {
        errors.add('$path: above maximum');
      }
    }
    if (field['choices'] is List &&
        !(field['choices'] as List).contains(value)) {
      errors.add('$path: unsupported choice');
    }
  }

  bool _boundedJson(dynamic value, int depth) {
    if (depth > maxDepth) return false;
    if (value is Map) {
      return value.length <= maxItems &&
          value.entries.every(
            (e) => e.key is String && _boundedJson(e.value, depth + 1),
          );
    }
    if (value is List) {
      return value.length <= maxItems &&
          value.every((v) => _boundedJson(v, depth + 1));
    }
    return value == null ||
        value is bool ||
        (value is String && value.length <= 8192) ||
        (value is num && value.isFinite);
  }
}
