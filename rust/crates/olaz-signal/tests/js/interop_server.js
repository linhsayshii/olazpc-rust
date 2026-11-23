// Line-delimited JSON RPC over stdin/stdout around the REAL bundled JS Signal glue
// (`ZaloE2EE.pc`). The Rust interop tests drive it to prove Rust output decrypts in JS and that
// JS reads/continues records Rust wrote. Test keys only.
'use strict';
const readline = require('readline');
const { load } = require('./harness');

const E = load().pc;

const handlers = {
  init: async ({ uid, saved }) => {
    const r = await E.initOrRestore(uid, saved || '');
    return { restored: r.restored, registrationId: r.registrationId, bundlePayload: r.bundlePayload, storeJSON: r.storeJSON };
  },
  export: async ({ uid }) => ({ storeJSON: E.exportStore(uid) }),
  processBundle: async ({ uid, remote, device, bundle }) => E.processPreKeyBundle(uid, remote, device, bundle),
  encrypt: async ({ uid, remote, device, text }) => E.encryptCipher(uid, remote, device, text, 'string'),
  decrypt: async ({ uid, remote, device, cipher }) => E.decryptCipher(uid, remote, device, cipher, 'string'),
  hasSession: async ({ uid, remote, device }) => ({ ok: await E.hasSession(uid, remote, device) }),
};

const rl = readline.createInterface({ input: process.stdin });
let chain = Promise.resolve();
rl.on('line', (line) => {
  chain = chain.then(async () => {
    let out;
    try {
      const req = JSON.parse(line);
      const h = handlers[req.cmd];
      if (!h) throw new Error('unknown cmd ' + req.cmd);
      out = await h(req);
    } catch (e) {
      out = { ok: false, error: String(e && e.message ? e.message : e) };
    }
    process.stdout.write(JSON.stringify(out) + '\n');
  });
});
rl.on('close', () => { chain.then(() => process.exit(0)); });
