#!/usr/bin/env node
// Build the data file loader/test-matplotlib.html loads:
//   build/mpl_vfs.js — matplotlib's pure-Python layer + runtime deps
//                      (cycler, pyparsing, packaging, dateutil, six,
//                      kiwisolver's py wrapper, the PIL/plistlib stubs)
//                      as a Brython VFS, plus window.MPL_DATA (matplotlibrc
//                      and the DejaVu fonts, base64) served through the
//                      page's open() override — FT2Font opens font files
//                      through Python open(), so no wasm FS is involved.
//
// The matplotlib tree must have src/cython-support/mpl-vfs.patch applied
// (Brython/browser fixes: \N{...} escapes resolved, pickle_super-safe
// __deepcopy__/__copy__, MPLCONFIGDIR trusted, lazy importlib.resources…)
// and the pyparsing tree pyparsing-vfs.patch (PEP-649 lazy annotations).
//
// Usage: gen_mpl_vfs.mjs <mpl-lib-dir> <kiwi-py-dir> <mpldeps-dir> <pdeps-dir>
//   <mpl-lib-dir>  matplotlib-src/lib   (patched)
//   <kiwi-py-dir>  kiwisolver-src/py    (kiwisolver/ package)
//   <mpldeps-dir>  unpacked cycler/ pyparsing/ packaging/ wheels (patched)
//   <pdeps-dir>    the pandas deps dir (dateutil/ six.py)
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const fs = require('fs'), path = require('path');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const [MPLLIB, KIWIPY, MPLDEPS, PDEPS] = process.argv.slice(2);
if (!MPLLIB || !KIWIPY || !MPLDEPS || !PDEPS) {
  console.error('usage: gen_mpl_vfs.mjs <mpl-lib-dir> <kiwi-py-dir> <mpldeps-dir> <pdeps-dir>');
  process.exit(1);
}
const OUT = path.join(ROOT, 'build', 'mpl_vfs.js');

const scripts = { $timestamp: Date.now() };
let n = 0, bytes = 0;
function walk(dir, rootParent, skip) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (skip && skip.includes(e.name)) continue;
      walk(full, rootParent, skip); continue;
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
// tests excluded (size); mpl-data walked separately below for the assets
walk(path.join(MPLLIB, 'matplotlib'), MPLLIB, ['tests', 'mpl-data']);
// data path: VFS modules have no real __file__ — serve the assets under the
// literal 'mpl-data/…' keys of window.MPL_DATA through the page's open().
{
  let ini = scripts['matplotlib'][1];
  const old = 'return str(Path(__file__).with_name("mpl-data"))';
  if (!ini.includes(old)) throw new Error('get_data_path anchor not found');
  scripts['matplotlib'][1] = ini.replace(old,
    'return "mpl-data"  # wasthon: window.MPL_DATA key prefix')
    // __version__ is served by a PEP 562 module __getattr__ upstream, which
    // Brython does not fire on VFS modules — set it eagerly.
    + '\nfrom matplotlib._version import version as __version__\n';
}
// mpl_toolkits excluded entirely: axes3d.py trips the Brython parser
// (f-string spec) and nothing in the Agg flow needs it
walk(path.join(KIWIPY, 'kiwisolver'), KIWIPY);
for (const pkg of ['cycler', 'pyparsing', 'packaging']) walk(path.join(MPLDEPS, pkg), MPLDEPS);
walk(path.join(PDEPS, 'dateutil'), PDEPS);
scripts['six'] = ['.py', fs.readFileSync(path.join(PDEPS, 'six.py'), 'utf8'), [], false];
n++;
// meson-generated version module (absent from a git-tag tree)
scripts['matplotlib._version'] =
  ['.py', 'version = "3.9.2"\n__version__ = "3.9.2"\nversion_tuple = (3, 9, 2)\n', [], false];
n++;
// browser stubs shipped with the repo: PIL (matplotlib imports it top-level
// in colors/image but Agg->canvas never calls it) and plistlib
for (const [mod, file, isPkg] of [
  ['PIL', 'PIL/__init__.py', true],
  ['PIL.Image', 'PIL/Image.py', false],
  ['PIL.PngImagePlugin', 'PIL/PngImagePlugin.py', false],
  ['plistlib', 'plistlib.py', false],
]) {
  scripts[mod] = ['.py', fs.readFileSync(path.join(HERE, 'mpl-stubs', file), 'utf8'), [], isPkg];
  n++;
}
// matplotlib._image: the C module's PyInit aborts under the bridge — a
// Python stub with the resample constants keeps `import matplotlib.image`
// alive (Agg never resamples in the smoke).
scripts['matplotlib._image'] =
  ['.py', fs.readFileSync(path.join(HERE, 'mpl-stubs', '_image.py'), 'utf8'), [], false];
n++;

// mpl-data assets, served through the page's open() override: matplotlibrc
// + the DejaVu fonts (base64 — FT2Font reads them through Python open()).
const DATA = {};
const mplData = path.join(MPLLIB, 'matplotlib', 'mpl-data');
DATA['matplotlibrc'] = fs.readFileSync(path.join(mplData, 'matplotlibrc')).toString('base64');
const FONTS = [];
for (const f of ['DejaVuSans.ttf', 'DejaVuSans-Bold.ttf', 'DejaVuSans-Oblique.ttf']) {
  DATA['fonts/ttf/' + f] = fs.readFileSync(path.join(mplData, 'fonts', 'ttf', f)).toString('base64');
  FONTS.push(f);
}

const blob = ';(function(){\nif(typeof __BRYTHON__==="undefined"){throw new Error("load brython.js first")}\n__BRYTHON__.update_VFS(' + JSON.stringify(scripts) + ');\nwindow.MPL_DATA=' + JSON.stringify(DATA) + ';\nwindow.MPL_FONTS=' + JSON.stringify(FONTS) + ';\n})();\n';
fs.writeFileSync(OUT, blob);
console.log('mpl VFS: ' + n + ' modules, ' + (bytes / 1048576).toFixed(1) + ' MB src, blob ' + (blob.length / 1048576).toFixed(1) + ' MB -> ' + OUT);
