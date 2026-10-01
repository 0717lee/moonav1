const fs = require('node:fs');
const api = require('./io-node.cjs');
(async () => {
  const module = await WebAssembly.compile(fs.readFileSync(process.argv[2]));
  const { exports } = await WebAssembly.instantiate(module, {
    moonav1_container_io: api,
    spectest: { print_char(value) {
      if (value === 10) { console.log(line); line = ''; }
      else line += String.fromCodePoint(value);
    } },
    Math,
  });
  exports._start();
})().catch(error => { console.error(error); process.exitCode = 1; });
let line = '';
