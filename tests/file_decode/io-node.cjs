// Test-only buffered file IO shared by Node JS and the Wasm GC host.
const fs = require('node:fs');
const files = new Array(6);
const suffixes = ['.obu', '.reference.yuv', '.avif', '.alpha.yuv', '.icc-input.rgba16', '.icc-output.rgba16'];
const values = (process.env.MOONAV1_FIXTURE_CONFIG || '').split(',').map(Number);
const api = {
  config(index) {
    const value = values[index];
    return Number.isInteger(value) && value >= 0 && value <= 0x7fffffff ? value : -1;
  },
  open(kind) {
    if (!suffixes[kind] || files[kind]) return -1;
    const fd = fs.openSync(process.env.MOONAV1_FIXTURE_PREFIX + suffixes[kind], 'r');
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
  rewind(kind) {
    const file = files[kind];
    if (!file) return -1;
    file.cursor = file.available = file.position = 0;
    return 0;
  },
  close(kind) {
    if (files[kind]) fs.closeSync(files[kind].fd);
    files[kind] = undefined;
  },
};
globalThis.__moonav1_fixture = api;
module.exports = api;
