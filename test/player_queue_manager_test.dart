import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/player_queue_manager.dart';

Track _track(String id) => Track(
      id: id,
      bvid: id,
      cid: 1,
      title: id,
      rawTitle: id,
      uploader: 'uploader',
      coverUrl: '',
      duration: 1,
    );

void main() {
  test('shuffle chooses every queue item without reordering the queue', () {
    final queue = List<Track>.generate(6, (index) => _track('$index'));
    final manager = PlayerQueueManager(random: Random(42));
    manager.syncAfterQueueChange(queue: queue, currentIndex: 0);

    final visited = <String>[queue.first.id];
    var current = 0;
    for (var i = 0; i < queue.length - 1; i++) {
      current = manager.next(queue: queue, currentIndex: current, shuffle: true)!;
      visited.add(queue[current].id);
    }

    expect(queue.map((track) => track.id).toList(), <String>['0', '1', '2', '3', '4', '5']);
    expect(visited.toSet(), hasLength(queue.length));
  });

  test('shuffle previous follows visit history', () {
    final queue = List<Track>.generate(5, (index) => _track('$index'));
    final manager = PlayerQueueManager(random: Random(42));
    manager.syncAfterQueueChange(queue: queue, currentIndex: 0);
    manager.recordVisit(queue: queue, index: 0, shuffle: true);
    final second = manager.next(queue: queue, currentIndex: 0, shuffle: true)!;
    manager.recordVisit(queue: queue, index: second, shuffle: true);
    final third = manager.next(queue: queue, currentIndex: second, shuffle: true)!;
    manager.recordVisit(queue: queue, index: third, shuffle: true);

    expect(manager.previous(queue: queue, currentIndex: third, shuffle: true), second);
  });
}
