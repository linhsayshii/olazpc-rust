// Loads the REAL bundled Zalo libsignal build + Olaz glue (Sources/Olaz/JSModules) into node.
// Test keys only: everything here is generated fresh in memory.
'use strict';
const fs = require('fs');
const path = require('path');

const MODULES = path.resolve(__dirname, '../../../../../Sources/Olaz/JSModules');

function load() {
  globalThis.window = globalThis;
  (0, eval)(fs.readFileSync(path.join(MODULES, 'vendor/libsignal-protocol.js'), 'utf8'));
  (0, eval)(fs.readFileSync(path.join(MODULES, 'zalo-e2ee.js'), 'utf8'));
  return globalThis.ZaloE2EE;
}

module.exports = { load, MODULES };
