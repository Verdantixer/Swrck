import 'dart:convert';

/// Parses Xray's JSON-with-comments format without changing quoted strings.
Map<String, dynamic> parseXrayJson(String input) {
  var decoded = jsonDecode(normalizeXrayJson(input));
  // Some clipboard/export tools wrap the complete object as a JSON string.
  if (decoded is String) {
    decoded = jsonDecode(normalizeXrayJson(decoded));
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Xray configuration must be a JSON object.');
  }
  return decoded;
}

/// Selects a server-facing outbound for profile labels and standard editor fields.
/// The complete JSON remains the source of truth for running the profile.
Map<String, dynamic>? primaryXrayOutbound(Map<String, dynamic> config) {
  final values = config['outbounds'];
  if (values is! List) return null;
  final outbounds = values
      .whereType<Map>()
      .map((value) => Map<String, dynamic>.from(value))
      .toList();
  if (outbounds.isEmpty) return null;
  const nonProxy = {'freedom', 'blackhole', 'dns', 'loopback'};
  for (final outbound in outbounds) {
    final protocol = (outbound['protocol'] as String? ?? '').toLowerCase();
    if (!nonProxy.contains(protocol)) return outbound;
  }
  return outbounds.first;
}

bool isSingboxJson(Map<String, dynamic> config) {
  final outbounds = config['outbounds'];
  return outbounds is List &&
      outbounds.whereType<Map>().any(
            (outbound) => outbound['type'] is String,
          );
}

String normalizeXrayJson(String input) {
  var source = input.startsWith('\uFEFF') ? input.substring(1) : input;
  final fenced = RegExp(
    r'^\s*```(?:jsonc?|javascript)?\s*([\s\S]*?)\s*```\s*$',
    caseSensitive: false,
  ).firstMatch(source);
  if (fenced != null) source = fenced.group(1)!;
  source = _normalizeCopiedEntities(source);
  final withoutComments = StringBuffer();
  var quoted = false;
  var escaped = false;
  var index = 0;
  while (index < source.length) {
    final char = source[index];
    if (quoted) {
      withoutComments.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      index++;
      continue;
    }
    if (char == '"') {
      quoted = true;
      withoutComments.write(char);
      index++;
      continue;
    }
    if (char == '/' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == '/') {
        index += 2;
        while (index < source.length && source[index] != '\n') {
          index++;
        }
        continue;
      }
      if (next == '*') {
        index += 2;
        while (index + 1 < source.length &&
            !(source[index] == '*' && source[index + 1] == '/')) {
          if (source[index] == '\n') withoutComments.write('\n');
          index++;
        }
        if (index + 1 >= source.length) {
          throw const FormatException('Unterminated Xray JSON comment.');
        }
        index += 2;
        continue;
      }
    }
    withoutComments.write(char);
    index++;
  }

  final commentsRemoved = withoutComments.toString();
  final normalized = StringBuffer();
  quoted = false;
  escaped = false;
  for (index = 0; index < commentsRemoved.length; index++) {
    final char = commentsRemoved[index];
    if (quoted) {
      normalized.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      continue;
    }
    if (char == '"') {
      quoted = true;
      normalized.write(char);
      continue;
    }
    if (char == ',') {
      var lookahead = index + 1;
      while (lookahead < commentsRemoved.length &&
          commentsRemoved[lookahead].trim().isEmpty) {
        lookahead++;
      }
      if (lookahead < commentsRemoved.length &&
          (commentsRemoved[lookahead] == '}' ||
              commentsRemoved[lookahead] == ']')) {
        continue;
      }
    }
    normalized.write(char);
  }
  return normalized.toString();
}

String _normalizeCopiedEntities(String source) {
  final result = StringBuffer();
  final escapedObject = RegExp(r'^\s*\{\\"').hasMatch(source);
  var quoted = false;
  var escaped = false;
  var index = 0;
  while (index < source.length) {
    final char = source[index];
    if (char == '&') {
      final quoteEntity = RegExp(
        r'^(?:&quot;|&#x22;|&#34;)',
        caseSensitive: false,
      ).firstMatch(source.substring(index));
      if (quoteEntity != null) {
        final afterEntity = index + quoteEntity.group(0)!.length;
        var lookahead = afterEntity;
        while (lookahead < source.length && source[lookahead].trim().isEmpty) {
          lookahead++;
        }
        final next = lookahead < source.length ? source[lookahead] : '';
        final isClosingQuote = quoted &&
            (next.isEmpty ||
                next == ':' ||
                next == ',' ||
                next == '}' ||
                next == ']');
        if (isClosingQuote) {
          result.write('"');
          quoted = false;
        } else if (quoted) {
          result.write(r'\"');
        } else {
          result.write('"');
          quoted = true;
        }
        index = afterEntity;
        continue;
      }
    }
    if (quoted &&
        escapedObject &&
        char == r'\' &&
        index + 1 < source.length &&
        source[index + 1] == '"') {
      var lookahead = index + 2;
      while (lookahead < source.length && source[lookahead].trim().isEmpty) {
        lookahead++;
      }
      final next = lookahead < source.length ? source[lookahead] : '';
      if (next.isEmpty ||
          next == ':' ||
          next == ',' ||
          next == '}' ||
          next == ']') {
        result.write('"');
        quoted = false;
      } else {
        result.write(r'\"');
      }
      index += 2;
      continue;
    }
    if (quoted) {
      result.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      index++;
      continue;
    }

    if (char == '&') {
      final entity = RegExp(
        r'^(?:&#x20;|&#32;|&nbsp;|&#x09;|&#9;|&#x0a;|&#10;|&#x0d;|&#13;|&#x7b;|&#123;|&#x7d;|&#125;|&#x5b;|&#91;|&#x5d;|&#93;|&quot;|&#x22;|&#34;)',
        caseSensitive: false,
      ).firstMatch(source.substring(index));
      if (entity != null) {
        final value = entity.group(0)!.toLowerCase();
        final decoded = switch (value) {
          '&#x20;' || '&#32;' || '&nbsp;' => ' ',
          '&#x09;' || '&#9;' => '\t',
          '&#x0a;' || '&#10;' => '\n',
          '&#x0d;' || '&#13;' => '\r',
          '&#x7b;' || '&#123;' => '{',
          '&#x7d;' || '&#125;' => '}',
          '&#x5b;' || '&#91;' => '[',
          '&#x5d;' || '&#93;' => ']',
          _ => ' ',
        };
        result.write(decoded);
        index += entity.group(0)!.length;
        continue;
      }
    }

    // Remove JavaScript-style line-continuation slashes from copied JSON and
    // unescape structural quotes from a JSON object copied as a string.
    if (char == r'\' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == '"') {
        result.write('"');
        quoted = true;
        index += 2;
        continue;
      }
      if (next == '\n') {
        index += 2;
        continue;
      }
      if (next == '\r') {
        index += index + 2 < source.length && source[index + 2] == '\n' ? 3 : 2;
        continue;
      }
    }

    result.write(char);
    if (char == '"') quoted = true;
    index++;
  }
  return result.toString();
}
