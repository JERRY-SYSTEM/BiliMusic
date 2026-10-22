import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Encodes anonymous NetEase EAPI requests. AES-128 ECB with PKCS#7 padding;
/// the signature and fixed key are public protocol constants, not credentials.
class NetEaseEapi {
  static String encode(String path, Map<String, dynamic> params) {
    final json = jsonEncode(params);
    final digest = md5.convert(utf8.encode('nobody${path}use${json}md5forencrypt'));
    final data = List<int>.from(utf8.encode('$path-36cd479b6b5-$json-36cd479b6b5-$digest'));
    final padding = 16 - data.length % 16;
    data.addAll(List.filled(padding, padding));
    final keys = _roundKeys;
    final encrypted = <int>[];
    for (var i = 0; i < data.length; i += 16) {
      final state = data.sublist(i, i + 16);
      _addKey(state, keys, 0);
      for (var round = 1; round <= 10; round++) {
        for (var j = 0; j < 16; j++) { state[j] = _s[state[j]]; }
        final shifted = List<int>.generate(16,
          (j) => state[((j ~/ 4 + j % 4) % 4) * 4 + j % 4]);
        state.setAll(0, shifted);
        if (round < 10) {
          for (var col = 0; col < 16; col += 4) {
            final a = state.sublist(col, col + 4);
            for (var row = 0; row < 4; row++) {
              state[col + row] = _multiply(a[row], 2) ^ _multiply(a[(row + 1) % 4], 3) ^
                  a[(row + 2) % 4] ^ a[(row + 3) % 4];
            }
          }
        }
        _addKey(state, keys, round);
      }
      encrypted.addAll(state);
    }
    return encrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  /// EAPI normally returns AES-encrypted JSON when e_r is true, but errors
  /// from the gateway may still be plain JSON. Preserve their API codes.
  static Map<String, dynamic> decodeResponse(List<int> bytes) {
    final first = bytes.indexWhere((byte) => byte != 32 && byte != 9 && byte != 10 && byte != 13);
    if (first >= 0 && bytes[first] == 0x7b) {
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map) {
          return Map<String, dynamic>.from(value);
        }
      } on FormatException {
        // An encrypted response can also start with the byte for '{'.
      }
    }
    if (bytes.isEmpty || bytes.length % 16 != 0) {
      throw const FormatException('Invalid encrypted EAPI response length');
    }
    final decrypted = <int>[];
    for (var offset = 0; offset < bytes.length; offset += 16) {
      final state = bytes.sublist(offset, offset + 16);
      _addKey(state, _roundKeys, 10);
      for (var round = 9; round >= 0; round--) {
        final shifted = List<int>.generate(16,
          (i) => state[((i ~/ 4 - i % 4 + 4) % 4) * 4 + i % 4]);
        for (var i = 0; i < 16; i++) {
          state[i] = _inverseS[shifted[i]];
        }
        _addKey(state, _roundKeys, round);
        if (round > 0) {
          for (var col = 0; col < 16; col += 4) {
            final a = state.sublist(col, col + 4);
            for (var row = 0; row < 4; row++) {
              state[col + row] = _multiply(a[row], 14) ^
                  _multiply(a[(row + 1) % 4], 11) ^
                  _multiply(a[(row + 2) % 4], 13) ^
                  _multiply(a[(row + 3) % 4], 9);
            }
          }
        }
      }
      decrypted.addAll(state);
    }
    final padding = decrypted.last;
    if (padding < 1 || padding > 16 ||
        decrypted.skip(decrypted.length - padding).any((byte) => byte != padding)) {
      throw const FormatException('Invalid EAPI response padding');
    }
    final plain = decrypted.sublist(0, decrypted.length - padding);
    final value = jsonDecode(utf8.decode(plain));
    if (value is! Map) {
      throw const FormatException('EAPI response is not an object');
    }
    return Map<String, dynamic>.from(value);
  }

  static final _roundKeys = _expand(ascii.encode('e82ckenh8dichen8'));
  static final _inverseS = () {
    final inverse = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      inverse[_s[i]] = i;
    }
    return inverse;
  }();

  static void _addKey(List<int> state, List<int> keys, int round) {
    for (var i = 0; i < 16; i++) { state[i] ^= keys[round * 16 + i]; }
  }

  static List<int> _expand(List<int> key) {
    final result = List<int>.from(key);
    var rcon = 1;
    while (result.length < 176) {
      var word = result.sublist(result.length - 4);
      if (result.length % 16 == 0) {
        word = [for (var i = 0; i < 4; i++) _s[word[(i + 1) % 4]]];
        word[0] ^= rcon;
        rcon = _multiply(rcon, 2);
      }
      for (final value in word) { result.add(result[result.length - 16] ^ value); }
    }
    return result;
  }

  static int _multiply(int a, int b) {
    var value = 0;
    while (b != 0) {
      if ((b & 1) != 0) value ^= a;
      a = ((a << 1) ^ ((a & 128) != 0 ? 0x11b : 0)) & 255;
      b >>= 1;
    }
    return value;
  }

  // Derive the standard Rijndael S-box from the GF(2^8) inverse and affine
  // transform rather than embedding a second set of substitution tables.
  static final _s = List<int>.generate(256, (value) {
    var inverse = value == 0 ? 0 : 1;
    for (var i = 0; i < 254 && value != 0; i++) { inverse = _multiply(inverse, value); }
    var result = inverse ^ 0x63;
    for (var rotation = 1; rotation <= 4; rotation++) {
      result ^= ((inverse << rotation) | (inverse >> (8 - rotation))) & 255;
    }
    return result;
  });
}
