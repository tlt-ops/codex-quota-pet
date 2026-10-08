'use strict';
const { spawnSync } = require('node:child_process');
const { resolve } = require('node:path');
const electron = require('electron');
const output = resolve(process.argv[2] || 'artifacts/smoke');
const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const result = spawnSync(electron, ['.', `--smoke-test=${output}`], {
  cwd: resolve(__dirname, '..'), env, stdio: 'inherit', timeout: 90000,
  windowsHide: true
});
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
