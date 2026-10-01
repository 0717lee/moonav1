const fs = require('node:fs');
const api = require('./io-node.cjs');
(async () => {
  const module = await WebAssembly.compile(fs.readFileSync(process.argv[2]));
  let line = '';
  const { exports } = await WebAssembly.instantiate(module, {
    moonav1_fixture: api,
    spectest: { print_char(value) {
      if (value === 10) { console.log(line); line = ''; }
      else line += String.fromCodePoint(value);
    } },
    Math,
  });
  exports._start();
})().catch(error => { console.error(error); process.exitCode = 1; });
