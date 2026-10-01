// Test-only buffered file reader. The decoder remains entirely in MoonBit.
const fs = require('node:fs');

const files = new Array(4);
const paths = [
  process.env.MOONAV1_CONTAINER_INPUT,
  process.env.MOONAV1_CONTAINER_REFERENCE,
  process.env.MOONAV1_CONTAINER_EXPECTATION,
  process.env.MOONAV1_CONTAINER_REJECTED,
];
const values = (process.env.MOONAV1_CONTAINER_CONFIG || '').split(',').map(Number);
const api = {
  config(index) {
    const value = values[index];
    return Number.isInteger(value) && value >= 0 && value <= 0x7fffffff ? value : -1;
  },
  open(kind) {
    if (!paths[kind] || files[kind]) return -1;
    const fd = fs.openSync(paths[kind], 'r');
    files[kind] = { fd, buffer: Buffer.allocUnsafe(65536), cursor: 0, available: 0, position: 0 };
    return kind;
  },
  read(kind) {
    const file = files[kind];
    if (!file) return -2;
    if (file.cursor === file.available) {
      file.available = fs.readSync(file.fd, file.buffer, 0, file.buffer.length, file.position);
      file.position += file.available;
      file.cursor = 0;
      if (!file.available) return -1;
    }
    return file.buffer[file.cursor++];
  },
  seek(kind, offset) {
    const file = files[kind];
    if (typeof offset === 'bigint') offset = Number(offset);
    if (!file || !Number.isSafeInteger(offset) || offset < 0) return -1;
    file.cursor = file.available = 0;
    file.position = offset;
    return 0;
  },
  close(kind) {
    if (files[kind]) fs.closeSync(files[kind].fd);
    files[kind] = undefined;
  },
};
globalThis.__moonav1_container = api;
module.exports = api;
