import 'dart:math';

import '../models/track.dart';

/// Chooses tracks randomly without changing the order shown in the queue.
/// The generated order is kept separately from the visible queue so a round
/// does not repeat tracks and previous can follow the actual visit history.
class PlayerQueueManager {
  PlayerQueueManager({Random? random}) : _random = random ?? Random();

  final Random _random;
  final List<String> _order = <String>[];
  final List<String> _history = <String>[];
  int? _cursor;

  void reset() {
    _order.clear();
    _history.clear();
    _cursor = null;
  }

  void recordVisit({required List<Track> queue, required int index, required bool shuffle}) {
    if (!shuffle || index < 0 || index >= queue.length) return;
    _sync(queue, index);
    if (_history.isEmpty || _history.last != queue[index].id) {
      _history.add(queue[index].id);
    }
  }

  int? next({required List<Track> queue, required int currentIndex, required bool shuffle}) {
    if (queue.isEmpty || currentIndex < 0 || currentIndex >= queue.length) return null;
    if (!shuffle) return (currentIndex + 1) % queue.length;
    if (queue.length == 1) return currentIndex;
    _sync(queue, currentIndex);
    final cursor = _cursor ?? 0;
    if (cursor + 1 >= _order.length) {
      final ids = queue.map((t) => t.id).toList()..shuffle(_random);
      final currentId = queue[currentIndex].id;
      if (ids.first == currentId) {
        final swap = 1 + _random.nextInt(ids.length - 1);
        final first = ids[0];
        ids[0] = ids[swap];
        ids[swap] = first;
      }
      _order..clear()..addAll(ids);
      _cursor = 0;
    } else {
      _cursor = cursor + 1;
    }
    return _indexOf(queue, _order[_cursor!]) ?? currentIndex;
  }

  int? previous({required List<Track> queue, required int currentIndex, required bool shuffle}) {
    if (queue.isEmpty || currentIndex < 0 || currentIndex >= queue.length) return null;
    if (!shuffle) return (currentIndex - 1 + queue.length) % queue.length;
    _sync(queue, currentIndex);
    if (_history.isNotEmpty && _history.last == queue[currentIndex].id) _history.removeLast();
    while (_history.isNotEmpty) {
      final id = _history.removeLast();
      final index = _indexOf(queue, id);
      if (index != null && index != currentIndex) {
        _sync(queue, index);
        return index;
      }
    }
    final cursor = _cursor;
    if (cursor != null && cursor > 0) {
      _cursor = cursor - 1;
      return _indexOf(queue, _order[_cursor!]);
    }
    return (currentIndex - 1 + queue.length) % queue.length;
  }

  int? nextAvailable({required List<Track> queue, required int failedIndex, required bool shuffle, required Set<String> skippedIds}) {
    if (queue.isEmpty) return null;
    var candidate = failedIndex;
    for (var i = 0; i < queue.length; i++) {
      candidate = next(queue: queue, currentIndex: candidate, shuffle: shuffle)!;
      if (!skippedIds.contains(queue[candidate].id)) return candidate;
    }
    return null;
  }

  void remove(String id) {
    _order.remove(id);
    _history.removeWhere((item) => item == id);
    if (_order.isEmpty) _cursor = null;
    else if (_cursor != null && _cursor! >= _order.length) _cursor = _order.length - 1;
  }

  void prioritizeNext({
    required List<Track> queue,
    required int currentIndex,
    required String trackId,
    required bool shuffle,
  }) {
    if (!shuffle || currentIndex < 0 || currentIndex >= queue.length) return;
    _sync(queue, currentIndex);
    _order.remove(trackId);
    final position = ((_cursor ?? 0) + 1).clamp(0, _order.length).toInt();
    _order.insert(position, trackId);
  }

  void syncAfterQueueChange({required List<Track> queue, required int currentIndex}) {
    if (queue.isEmpty || currentIndex < 0 || currentIndex >= queue.length) {
      reset();
      return;
    }
    _sync(queue, currentIndex);
  }

  void _sync(List<Track> queue, int currentIndex) {
    final ids = queue.map((t) => t.id).toSet();
    _order.removeWhere((id) => !ids.contains(id));
    final known = _order.toSet();
    final missing = queue.map((t) => t.id).where((id) => !known.contains(id)).toList()..shuffle(_random);
    if (_order.isEmpty) {
      final currentId = queue[currentIndex].id;
      missing.remove(currentId);
      _order
        ..add(currentId)
        ..addAll(missing);
      _cursor = 0;
      return;
    }
    _order.addAll(missing);
    final currentId = queue[currentIndex].id;
    if (_order.isEmpty) {
      _order.add(currentId);
      _cursor = 0;
    } else {
      _cursor = _order.indexOf(currentId);
      if (_cursor! < 0) {
        _order.insert(0, currentId);
        _cursor = 0;
      }
    }
  }

  int? _indexOf(List<Track> queue, String id) {
    final index = queue.indexWhere((t) => t.id == id);
    return index < 0 ? null : index;
  }
}
