import 'dart:typed_data';

/// Shared bounded LRU for file and person previews.
class PreviewMemory {
  PreviewMemory({required this.byteBudget, this.entryLimit = 4000});

  final int byteBudget;
  final int entryLimit;
  final Map<String, ({Uint8List bytes, String version})> _entries = {};
  int _bytes = 0;

  ({Uint8List bytes, String version})? peek(String? key) =>
      key == null ? null : _entries[key];

  ({Uint8List bytes, String version})? get(String? key) {
    if (key == null) return null;
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  void remove(String key) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.bytes.length;
  }

  void put(String key, Uint8List bytes, String version) {
    remove(key);
    _entries[key] = (bytes: bytes, version: version);
    _bytes += bytes.length;
    while ((_bytes > byteBudget || _entries.length > entryLimit) &&
        _entries.length > 1) {
      remove(_entries.keys.first);
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
