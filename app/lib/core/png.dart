import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A PNG of [rgba] (straight alpha, [width] x [height], row 0 on top), made in
/// plain Dart so it can run in an isolate. Used to hand the heatmap picture to
/// the map as an ordinary image.
Uint8List encodePng(Uint8List rgba, int width, int height) {
  assert(rgba.length == width * height * 4);
  final stride = width * 4;
  // Each row starts with a filter byte; 0 = none.
  final raw = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    raw.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      rgba,
      y * stride,
    );
  }
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // colour type: RGBA
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  _chunk(out, 'IDAT', Uint8List.fromList(ZLibEncoder(level: 3).convert(raw)));
  _chunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  final body = Uint8List(4 + data.length)
    ..setRange(0, 4, type.codeUnits)
    ..setRange(4, 4 + data.length, data);
  out.add(body);
  final crc = ByteData(4)..setUint32(0, _crc32(body));
  out.add(crc.buffer.asUint8List());
}

final List<int> _table = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(Uint8List bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _table[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
