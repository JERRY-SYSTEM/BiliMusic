import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/models/track.dart';

void main() {
  test('rawTitle survives serialization round-trip', () {
    const t = Track(
      id: 'BV1QYBeBGEcU_p1',
      bvid: 'BV1QYBeBGEcU',
      cid: 1,
      title: '音乐缘计划',
      rawTitle: '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      uploader: '周深工作室',
      coverUrl: '',
      duration: 300,
    );
    final rt = Track.fromMap(t.toMap());
    expect(rt.rawTitle, t.rawTitle);
    expect(rt.title, t.title);
  });

  test('metadata edit keeps rawTitle, overwrites display title', () {
    const t = Track(
      id: 'x',
      bvid: 'BV1QYBeBGEcU',
      cid: 1,
      title: '音乐缘计划',
      rawTitle: '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      uploader: '周深工作室',
      coverUrl: '',
      duration: 300,
    );
    final edited = t.copyWith(title: '全世界下雨', uploader: '周深');
    expect(edited.title, '全世界下雨');
    expect(edited.rawTitle, t.rawTitle);
  });

  test('legacy track without rawTitle falls back to title', () {
    final t = Track.fromMap({
      'id': 'x',
      'bvid': 'BV1QYBeBGEcU',
      'cid': 1,
      'title': '音乐缘计划',
      'uploader': '周深工作室',
      'coverUrl': '',
      'duration': 300,
    });
    expect(t.rawTitle, '音乐缘计划');
  });
}
