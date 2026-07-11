#!/usr/bin/env node
// Build the two data files loader/test-pandas.html loads:
//   build/pandas_vfs.js            — pandas' pure-Python layer + runtime deps
//                                    (six, dateutil, pytz, and the browser
//                                    stubs mmap/ctypes) as a Brython VFS.
//   build/dateutil_zoneinfo_data.js — dateutil's zoneinfo tarball, base64
//                                    (the VFS has no pkgutil.get_data; the
//                                    page's prologue patches it to read
//                                    window.DATEUTIL_ZONEINFO_B64).
//
// Usage: gen_pandas_vfs.mjs <pandas-2.2.3-src> <deps-dir> [--tests]
//   <deps-dir> holds the unpacked runtime deps: dateutil/ pytz/ six.py
//   (unzip the python-dateutil, pytz and six wheels there).
//   --tests keeps pandas/tests in the VFS (15 of 26 MB — off by default).
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const PD = process.argv[2], DEPS = process.argv[3];
if (!PD || !DEPS) { console.error('usage: gen_pandas_vfs.mjs <pandas-src> <deps-dir> [--tests]'); process.exit(1); }
const OUT = path.join(ROOT, 'build', 'pandas_vfs.js');

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;
const KEEP_TESTS = process.argv.includes('--tests');
function walk(dir, rootParent) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (!KEEP_TESTS && e.name === 'tests') continue;   // pandas/tests = 15 of 26 MB
      walk(full, rootParent); continue;
    }
    if (!e.name.endsWith('.py')) continue;
    const rel = path.relative(rootParent, full);
    const isInit = e.name === '__init__.py';
    let mod = rel.replace(/\.py$/, '').replace(/[\/]/g, '.');
    if (isInit) mod = mod.replace(/\.__init__$/, '');
    const src = fs.readFileSync(full, 'utf8');
    scripts[mod] = ['.py', src, [], isInit];
    n++; bytes += src.length;
  }
}
walk(path.join(PD, 'pandas'), PD);
for (const pkg of ['dateutil', 'pytz']) walk(path.join(DEPS, pkg), DEPS);
scripts['six'] = ['.py', fs.readFileSync(path.join(DEPS, 'six.py'), 'utf8'), [], false];
n++;
// browser stubs shipped with the repo (pandas imports them at module level
// but never exercises them in the browser)
for (const m of ['mmap', 'ctypes']) {
  scripts[m] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', m + '.py'), 'utf8'), [], false];
  n++;
}
// meson-generated version module (absent from a git-tag tree; the versioneer
// fallback shells out to git -> posix.pipe, unavailable in the browser)
scripts['pandas._version_meson'] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', '_version_meson.py'), 'utf8'), [], false];
n++;
// hypothesis stub (package + the two extra.* submodules
// pandas._testing._hypothesis imports): @given tests -> skips.
scripts['hypothesis'] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', 'hypothesis.py'), 'utf8'), [], true];
scripts['hypothesis.extra'] = ['.py', '', [], true];
for (const m of ['dateutil', 'pytz']) {
  scripts['hypothesis.extra.' + m] =
    ['.py', 'from hypothesis import _S\ndef timezones(*a, **k):\n    return _S()\n', [], false];
}
n += 4;
const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('pandas VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);

const tarball = path.join(DEPS, 'dateutil', 'zoneinfo', 'dateutil-zoneinfo.tar.gz');
const ZOUT = path.join(ROOT, 'build', 'dateutil_zoneinfo_data.js');
const b64 = fs.readFileSync(tarball).toString('base64');
fs.writeFileSync(ZOUT, 'window.DATEUTIL_ZONEINFO_B64="' + b64 + '"\n');
console.log('zoneinfo data: ' + (b64.length / 1024).toFixed(0) + ' KB b64 -> ' + ZOUT);
