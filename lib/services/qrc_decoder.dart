import 'dart:convert';
import 'dart:io';

/// Cloud QRC: hexadecimal, three DES stages, then a zlib stream. QRC uses
/// little-endian 32-bit words, modified S2/S4 and a shifted right key half,
/// so platform DES is unsuitable.
/// This table-driven implementation uses the DES bit-numbering convention.
class QrcDecoder {
  static String decode(String hex) {
    hex = hex.trim();
    if (hex.isEmpty || hex.length % 16 != 0 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      throw const FormatException('Invalid cloud QRC ciphertext');
    }
    final input = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    final output = <int>[];
    for (var i = 0; i < input.length; i += 8) {
      var block = _read(input, i);
      for (final keys in _keys) {
        block = _des(block, keys);
      }
      final bytes = List<int>.generate(8, (j) => (block >>> (56 - 8 * j)) & 255);
      output.addAll([bytes[3], bytes[2], bytes[1], bytes[0], bytes[7], bytes[6], bytes[5], bytes[4]]);
    }
    return utf8.decode(zlib.decode(output));
  }

  static int _read(List<int> bytes, int offset) {
    var value = 0;
    for (final j in [3, 2, 1, 0, 7, 6, 5, 4]) {
      value = (value << 8) | bytes[offset + j];
    }
    return value;
  }

  static int _permute(int value, int width, List<int> table) {
    var result = 0;
    for (final bit in table) {
      result = (result << 1) | ((value >>> (width - bit)) & 1);
    }
    return result;
  }

  static final _keys = _makeKeys();
  static List<List<int>> _makeKeys() {
    final key = ascii.encode('!@#)(*\$%123ZXC!@!@#)(NHL');
    final stages = <List<int>>[];
    for (final offset in [16, 8, 0]) {
      final selected = _permute(_read(key, offset), 64, _pc1);
      var c = selected >>> 28;
      var d = selected & 0xfffffff;
      final rounds = <int>[];
      for (final shift in [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]) {
        c = ((c << shift) | (c >>> (28 - shift))) & 0xfffffff;
        d = ((d << shift) | (d >>> (28 - shift))) & 0xfffffff;
        // QRC addresses the right half one bit later than standard PC-2.
        // Keep the rotation itself at 28 bits; the extra shift is only for
        // subkey selection, with a zero entering the least significant bit.
        final selectedD = (d << 1) & 0xfffffff;
        rounds.add(_permute((c << 28) | selectedD, 56, _pc2));
      }
      stages.add(offset == 8 ? rounds : rounds.reversed.toList());
    }
    return stages;
  }

  static int _des(int block, List<int> keys) {
    final initial = _permute(block, 64, _ip);
    var left = initial >>> 32;
    var right = initial & 0xffffffff;
    for (final key in keys) {
      final expanded = _permute(right, 32, _expansion) ^ key;
      var substituted = 0;
      for (var box = 0; box < 8; box++) {
        final value = (expanded >>> (42 - box * 6)) & 63;
        final row = ((value & 32) >>> 4) | (value & 1);
        final column = (value >>> 1) & 15;
        // Protocol deviations from the standard DES substitution tables.
        final s = box == 3 && row == 3 && column == 5 ? 10
            : box == 1 && row == 1 && column == 7 ? 15
            : _s[box][row * 16 + column];
        substituted = (substituted << 4) | s;
      }
      final next = left ^ _permute(substituted, 32, _p);
      left = right;
      right = next;
    }
    return _permute((right << 32) | left, 64, _fp);
  }

  static const _ip = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
  static const _fp = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25];
  static const _pc1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
  static const _pc2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
  static const _expansion = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
  static const _p = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
  static const _s = [
    [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
    [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
    [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
    [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
    [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
    [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
    [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
    [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
  ];
}
