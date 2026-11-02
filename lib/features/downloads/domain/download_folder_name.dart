/// Storage-safe, human-readable folder name for one downloaded part.
///
/// The name is cosmetic: a task's identity is the `id` inside `manifest.json`,
/// and the platform layer re-checks uniqueness against the real store before
/// creating the folder. Keeping the rule here lets both the retry path and the
/// later directory scan derive the same name from the same item.
library;

/// Reserved so a collision suffix (`-2`, `-3`, …) still fits the tightest
/// provider limit we publish to.
const int _nameBudget = 160;

const int _suffixBudget = 8;

/// MediaStore, SAF and `file:` all reject or mangle these; Windows reserves
/// them too, which keeps a copied folder tree usable on a PC.
final RegExp _forbidden = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]+');

final RegExp _spaces = RegExp(r'\s+');

/// Builds `BV1xx4y1z7qA-P3 title…`, truncated to [_nameBudget] bytes.
///
/// [videoId] is a `VideoId.value`, which already carries the `BV` prefix.
/// Truncation stops between code points, so a multi-byte title never becomes
/// invalid UTF-8; an emoji ZWJ sequence can still be cut after its first
/// glyph, which renders as a plain emoji rather than as mojibake.
String downloadFolderName({
  required String videoId,
  required int page,
  required String title,
}) {
  final prefix = '$videoId-P$page';
  final cleaned = title
      .replaceAll(_forbidden, ' ')
      .replaceAll(_spaces, ' ')
      .trim();
  if (cleaned.isEmpty) return prefix;
  final room = _nameBudget - _suffixBudget - _utf8Length(prefix) - 1;
  return '$prefix ${_truncateToBytes(cleaned, room)}';
}

String _truncateToBytes(String value, int budget) {
  if (budget <= 0) return '';
  var bytes = 0;
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final width = _runeUtf8Length(rune);
    if (bytes + width > budget) break;
    bytes += width;
    buffer.writeCharCode(rune);
  }
  var result = buffer.toString().replaceAll(_spaces, ' ').trim();
  // A trailing dot or space is dropped by several providers and silently
  // changes the name, so cut it here instead.
  while (result.endsWith('.') || result.endsWith(' ')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

int _utf8Length(String value) {
  var total = 0;
  for (final rune in value.runes) {
    total += _runeUtf8Length(rune);
  }
  return total;
}

int _runeUtf8Length(int rune) => rune < 0x80
    ? 1
    : rune < 0x800
    ? 2
    : rune < 0x10000
    ? 3
    : 4;
