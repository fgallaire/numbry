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
const fs = require('fs'), path = require('path'), zlib = require('zlib');
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
for (const m of ['mmap', 'ctypes', 'tracemalloc', 'zoneinfo']) {
  scripts[m] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', m + '.py'), 'utf8'), [], false];
  n++;
}
// meson-generated version module (absent from a git-tag tree; the versioneer
// fallback shells out to git -> posix.pipe, unavailable in the browser)
scripts['pandas._version_meson'] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', '_version_meson.py'), 'utf8'), [], false];
n++;
// dateutil.zoneinfo override: lazy zones from the build-extracted JS dict
// instead of the 2-minute pure-Python tarfile walk (see untar below)
scripts['dateutil.zoneinfo'] = ['.py', fs.readFileSync(path.join(HERE, 'pandas-stubs', 'dateutil_zoneinfo_init.py'), 'utf8'), [], true];
// pytz: its Lazy* list/set wrappers (methods re-bound via setattr on the
// class) come out EMPTY under Brython — `'US/Eastern' in all_timezones_set`
// was False -> UnknownTimeZoneError — and its zoneinfo dir (binary TZif) is
// not in the VFS anyway. Make every Lazy* call site eager and serve the data
// from the same build-extracted zoneinfo dict as dateutil (identical IANA
// TZif); resource_exists is a key test (no decode), the original construction
// order then runs unchanged.
{
  const tzOverride = `# wasthon: zoneinfo from the page's build-extracted dict
def open_resource(name):
    import base64
    from io import BytesIO
    from browser import window
    try:
        return BytesIO(base64.b64decode(window.DATEUTIL_ZONEINFO[name]))
    except Exception:
        raise UnknownTimeZoneError(name)

def resource_exists(name):
    try:
        from browser import window
        return bool(window.DATEUTIL_ZONEINFO.hasOwnProperty(name))
    except Exception:
        return False

`;
  let ptz = scripts['pytz'][1];
  ptz = ptz.replace('all_timezones = LazyList(', tzOverride + 'all_timezones = LazyList(');
  ptz = ptz.split('LazyList(').join('list(').split('LazySet(').join('set(');
  scripts['pytz'][1] = ptz;
}
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

// dateutil's zoneinfo, EXTRACTED at build time: at runtime, upstream
// ZoneInfoFile tarfile-walks the 619-member tarball and parses every tzfile
// under pure-Python tarfile — 2 minutes of Brython at `import pandas`. Ship
// {zone: base64(tzif)} instead; the dateutil.zoneinfo override in the VFS
// (pandas-stubs/dateutil_zoneinfo_init.py) reads it and parses zones lazily.
function untar(buf) {
  const out = {}, links = {};
  let off = 0;
  while (off + 512 <= buf.length) {
    const name = buf.toString('utf8', off, off + 100).replace(/\0.*$/s, '');
    if (!name) break;
    const size = parseInt(buf.toString('utf8', off + 124, off + 136).trim() || '0', 8);
    const type = String.fromCharCode(buf[off + 156]);
    const linkname = buf.toString('utf8', off + 157, off + 257).replace(/\0.*$/s, '');
    if (type === '0' || type === '\0') out[name] = buf.subarray(off + 512, off + 512 + size).toString('base64');
    else if (type === '1' || type === '2') links[name] = linkname;
    off += 512 + Math.ceil(size / 512) * 512;
  }
  for (const [n, t] of Object.entries(links)) if (out[t] !== undefined) out[n] = out[t];
  return out;
}
const tarball = path.join(DEPS, 'dateutil', 'zoneinfo', 'dateutil-zoneinfo.tar.gz');
const ZOUT = path.join(ROOT, 'build', 'dateutil_zoneinfo_data.js');
const zones = untar(zlib.gunzipSync(fs.readFileSync(tarball)));
fs.writeFileSync(ZOUT, 'window.DATEUTIL_ZONEINFO=' + JSON.stringify(zones) + '\n');
console.log('zoneinfo data: ' + Object.keys(zones).length + ' zones extracted -> ' + ZOUT);
