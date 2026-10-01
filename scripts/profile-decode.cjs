// Sample a local compiled JS consumer, even while synchronous decoding is busy.
// Usage: node scripts/profile-decode.cjs artifact.js output.cpuprofile [seconds] [fixture]
const fs = require('node:fs');
const {spawn} = require('node:child_process');
const [artifact, output, seconds = '10', fixture = 'video_10bit_640x360'] = process.argv.slice(2);
if (!artifact || !output || !(Number(seconds) > 0)) {
  throw new Error('Expected artifact.js output.cpuprofile [positive seconds] [fixture]');
}
const child = spawn(process.execPath,
  ['--inspect-brk=127.0.0.1:0', artifact, '--verify-only', fixture],
  {windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']});
let socket;
let nextId = 0;
const pending = new Map();
let connected = false;
function post(method) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method}));
  });
}
child.stdout.on('data', data => process.stdout.write(data));
child.stderr.on('data', async data => {
  const match = String(data).match(/ws:\/\/127\.0\.0\.1:[^\s]+/);
  if (!match || connected) return;
  connected = true;
  try {
    socket = new WebSocket(match[0]);
    socket.addEventListener('message', event => {
      const message = JSON.parse(String(event.data));
      if (!pending.has(message.id)) return;
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    });
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', reject, {once: true});
    });
    await post('Profiler.enable');
    await post('Profiler.start');
    await post('Runtime.runIfWaitingForDebugger');
    await new Promise(resolve => setTimeout(resolve, Number(seconds) * 1000));
    const {profile} = await post('Profiler.stop');
    fs.writeFileSync(output, JSON.stringify(profile));
    const totals = new Map();
    for (const node of profile.nodes) {
      const name = node.callFrame.functionName || '(anonymous)';
      totals.set(name, (totals.get(name) || 0) + (node.hitCount || 0));
    }
    console.log('CPU samples (self), not an end-to-end latency measurement:');
    console.log([...totals].sort((a,b) => b[1]-a[1]).slice(0,12)
      .map(([name,hits]) => `${hits} ${name}`).join('\n'));
    console.log(`Saved ${output}; stopping this diagnostic process`);
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    if (socket) socket.close();
    child.kill();
  }
});
child.on('error', error => { console.error(error); process.exitCode = 1; });
child.on('exit', (code) => {
  if (!connected) { console.error(`Diagnostic exited before inspector connection: ${code}`); process.exitCode = 1; }
});
