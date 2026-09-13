// One-off generator for the tray/app icon PNGs, run manually with:
//   node scripts/make-icon.mjs
// Draws a simple rounded gamepad-blue square with a white cursor arrow,
// hand-encoded as PNG so the project needs no image-processing dependency.
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([typeBuf, data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

// Renders an RGBA icon: rounded blue square with a white cursor-arrow glyph.
function renderIcon(size) {
  const px = new Uint8ClampedArray(size * size * 4);
  const bg = [0x4f, 0x6d, 0xf5]; // indigo-blue
  const corner = size * 0.18;

  const inRoundedSquare = (x, y) => {
    const cx = Math.min(x, size - 1 - x);
    const cy = Math.min(y, size - 1 - y);
    if (cx >= corner || cy >= corner) return true;
    const dx = corner - cx, dy = corner - cy;
    return dx * dx + dy * dy <= corner * corner;
  };

  // Cursor arrow polygon, in unit coordinates (0..1 of icon size).
  const arrow = [
    [0.30, 0.20], [0.30, 0.78], [0.46, 0.63],
    [0.56, 0.84], [0.66, 0.79], [0.56, 0.58], [0.76, 0.58],
  ];
  const inArrow = (x, y) => {
    const px_ = x / size, py_ = y / size;
    let inside = false;
    for (let i = 0, j = arrow.length - 1; i < arrow.length; j = i++) {
      const [xi, yi] = arrow[i], [xj, yj] = arrow[j];
      const intersect = (yi > py_) !== (yj > py_) &&
        px_ < ((xj - xi) * (py_ - yi)) / (yj - yi) + xi;
      if (intersect) inside = !inside;
    }
    return inside;
  };

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      if (!inRoundedSquare(x, y)) {
        px[i + 3] = 0;
        continue;
      }
      if (inArrow(x, y)) {
        px[i] = 0xff; px[i + 1] = 0xff; px[i + 2] = 0xff; px[i + 3] = 0xff;
      } else {
        px[i] = bg[0]; px[i + 1] = bg[1]; px[i + 2] = bg[2]; px[i + 3] = 0xff;
      }
    }
  }
  return px;
}

function encodePNG(size) {
  const px = renderIcon(size);
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter type: none
    Buffer.from(px.buffer, y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  const idat = deflateSync(raw);

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // color type: RGBA
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

writeFileSync(new URL('../assets/tray.png', import.meta.url), encodePNG(32));
writeFileSync(new URL('../assets/icon.png', import.meta.url), encodePNG(256));
console.log('Wrote assets/tray.png and assets/icon.png');
