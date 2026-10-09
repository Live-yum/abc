import 'dart:convert';

import 'package:flutter/material.dart';

import '../cloud/generation_schema.dart';

/// Primitive controls plus bounded JSON editors for lists/maps/opaque fields.
/// Only explicitly edited values are sent; server defaults are not overwritten.
class GenerationOptionsForm extends StatefulWidget {
  const GenerationOptionsForm({
    super.key,
    required this.schema,
    required this.onChanged,
    this.initialValue = const {},
    this.enabled = true,
  });
  final GenerationSchema schema;
  final Map<String, dynamic> initialValue;
  final void Function(Map<String, dynamic> value, List<String> errors)
  onChanged;
  final bool enabled;
  @override
  State<GenerationOptionsForm> createState() => _GenerationOptionsFormState();
}

class _GenerationOptionsFormState extends State<GenerationOptionsForm> {
  late Map<String, dynamic> _value;
  final Map<String, String> _parseErrors = {};
  final Set<String> _expanded = {};
  final Map<String, Map<String, dynamic>> _objectDrafts = {};
  @override
  void initState() {
    super.initState();
    _value =
        jsonDecode(jsonEncode(widget.initialValue)) as Map<String, dynamic>;
  }

  @override
  void didUpdateWidget(GenerationOptionsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.schema != widget.schema) {
      _value = {};
      _parseErrors.clear();
      _expanded.clear();
      _objectDrafts.clear();
    }
  }

  void _emit() => widget.onChanged(_value, [
    ..._parseErrors.values,
    ...widget.schema.validate(_value),
  ]);
  Widget _fields(
    Map<String, dynamic> fields,
    Map<String, dynamic> values,
    int depth,
    String path, [
    VoidCallback? commit,
  ]) {
    if (depth > GenerationSchema.maxDepth) {
      return const Text('Schema nesting limit reached.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: fields.entries.take(GenerationSchema.maxItems).map((entry) {
        if (entry.value is! Map) return const Text('Unsupported schema field');
        final field = Map<String, dynamic>.from(entry.value as Map);
        final label = field['label'] is String
            ? field['label'] as String
            : entry.key;
        final key = '$path.${entry.key}';
        final enabled = widget.enabled && field['readOnly'] != true;
        void update(dynamic value) {
          setState(() {
            if (value == null) {
              values.remove(entry.key);
            } else {
              values[entry.key] = value;
            }
            _parseErrors.remove(key);
          });
          commit?.call();
          _emit();
        }

        if (field['readOnly'] == true) {
          return ListTile(
            title: Text(label),
            subtitle: const Text('Read-only service setting'),
          );
        }
        if (field['kind'] == 'object') {
          final nested = widget.schema.fields(field);
          if (nested == null) {
            return Text('$label: unresolved schema reference');
          }
          final draft = _objectDrafts.putIfAbsent(
            key,
            () => values[entry.key] is Map<String, dynamic>
                ? values[entry.key] as Map<String, dynamic>
                : <String, dynamic>{},
          );
          return ExpansionTile(
            onExpansionChanged: (open) => setState(() {
              if (open) {
                _expanded.add(key);
              } else {
                _expanded.remove(key);
              }
            }),
            key: ValueKey(key),
            title: Text(label),
            children: [
              if (_expanded.contains(key))
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _fields(nested, draft, depth + 1, key, () {
                    values[entry.key] = draft;
                    commit?.call();
                  }),
                ),
            ],
          );
        }
        if (field['kind'] == 'boolean') {
          return CheckboxListTile(
            title: Text(label),
            subtitle: Text(
              field['help']?.toString() ?? 'Unset uses the service default',
            ),
            tristate: true,
            value: values[entry.key] as bool?,
            onChanged: enabled ? update : null,
          );
        }
        if (field['choices'] is List) {
          return DropdownButtonFormField<String>(
            key: ValueKey(key),
            initialValue: values[entry.key] as String?,
            decoration: InputDecoration(labelText: label),
            items: [
              const DropdownMenuItem(value: '', child: Text('Service default')),
              ...(field['choices'] as List).whereType<String>().map(
                (c) => DropdownMenuItem(value: c, child: Text(c)),
              ),
            ],
            onChanged: enabled ? (v) => update(v == '' ? null : v) : null,
          );
        }
        final complex = {'array', 'map', 'any'}.contains(field['kind']);
        final number = {'number', 'integer'}.contains(field['kind']);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextFormField(
            key: ValueKey('${widget.schema.revision}$key'),
            enabled: enabled,
            initialValue: values[entry.key] == null
                ? ''
                : complex
                ? jsonEncode(values[entry.key])
                : '${values[entry.key]}',
            maxLength: 8192,
            maxLines: complex ? 3 : 1,
            keyboardType: number
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            decoration: InputDecoration(
              labelText: label,
              helperText: complex
                  ? 'JSON; at most 256 items, nesting at most 12'
                  : field['help']?.toString(),
              errorText: _parseErrors[key],
            ),
            onChanged: (text) {
              if (text.isEmpty) {
                update(null);
                return;
              }
              try {
                final dynamic value = complex
                    ? jsonDecode(text)
                    : field['kind'] == 'integer'
                    ? int.parse(text)
                    : number
                    ? double.parse(text)
                    : text;
                update(value);
              } catch (_) {
                setState(() => _parseErrors[key] = '$label: invalid value');
                _emit();
              }
            },
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) =>
      _fields(widget.schema.root, _value, 0, 'config');
}
