#!/usr/bin/env node
// MCP icon generator — brand SVG glyph in, MCP-themed icon set out.
//
//   ./generate.mjs ../../services/mail/logo.svg --out ./icons --color '#4ea0f5'
//   ./generate.mjs ../../services/*/logo.svg --out ./icons --ico
//
// Invoked by `make icons`, which runs it in the tools/icon image (see the
// Dockerfile) so no local Node toolchain is needed. Needs a rasteriser for the
// PNG ladder — @resvg/resvg-js (pinned in package.json) or sharp. SVG-only
// output (--no-png) runs with zero dependencies.
//
// Provenance: consolidated from the Claude Design session's mcp-icon.mjs +
// mcp-icon-gen.js + glyphs/glyphs.js. Three deliberate departures from those:
//
//   1. One file, no exports. Nothing imports this; it is only ever a CLI.
//   2. No browser support. The upstream generator carried DOM/canvas versions
//      of parseGlyphSVG, measureGlyph and toPNG for a browser playground, all
//      of which the CLI already shadowed with Node implementations. Gone.
//   3. No 'matte' variant. Under resvg — the only rasteriser this repo renders
//      with — matte's MCP mark sits at opacity 0.15 and all but disappears,
//      and its radial lift diverges more across renderers than the soft-light
//      blend it was meant to avoid. Every tile is now the watermark treatment.
//
// The MCP watermark is read from ./logo.svg at startup rather than inlined, so
// swapping the mark is a file swap. Its viewBox is read from that file too.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { basename, extname, join, resolve } from 'node:path';

const die = m => { console.error('generate: ' + m); process.exit(1); };

/* ---------- args ---------- */
const FLAGS = {
  out: 'icons', color: null, name: null, sizes: null,
  chroma: 1, png: true, 'mcp-mark': true, rounded: true, json: false, quiet: false,
  ico: false, manifest: false, 'flat-names': false
};

/* ---------- the ladder ---------- */
const LADDER = [
  { size: 512, use: 'PWA & store' },
  { size: 192, use: 'manifest' },
  { size: 180, use: 'apple-touch' },
  { size: 48,  use: '.ico' },
  { size: 32,  use: '.ico' },
  { size: 16,  use: 'browser tab' }
];

const HELP = `generate — build an MCP service icon set from a brand SVG glyph

  generate <glyph.svg> [more.svg ...] [options]

  --out <dir>        output directory                 (default: ./icons)
  --color <hex>      brand colour                     (default: sniffed from the file)
  --sizes <list>     comma-separated px ladder        (default: ${LADDER.map(s => s.size).join(',')})
  --name <prefix>    file prefix, e.g. --name github  (default: source filename)
  --ico              also write <prefix>.ico (16/32/48 packed, for /favicon.ico)
  --manifest         also write <prefix>.webmanifest with the PWA icons block
  --flat-names       favicon.ico / icon-<n>.png, no prefix (single-glyph runs only)
  --chroma <n>       gradient saturation multiplier   (default: 1)
  --no-png           emit the master SVG only, no rasteriser needed
  --no-mcp-mark      omit the MCP watermark (plain branded tile)
  --square           square tile instead of the 22.5% superellipse radius
  --json             print the manifest as JSON on stdout (one object per glyph)
  -q, --quiet        no progress output
  -h, --help         this

  Several inputs run as a batch into one --out directory; --name and --flat-names
  are then ignored and each set is prefixed with its own filename.`;

function parseArgs(argv) {
  const out = { ...FLAGS }, rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') out.help = true;
    else if (a === '-q' || a === '--quiet') out.quiet = true;
    else if (a === '--no-png') out.png = false;
    else if (a === '--no-mcp-mark') out['mcp-mark'] = false;
    else if (a === '--square') out.rounded = false;
    else if (a === '--json') out.json = true;
    else if (a === '--ico') out.ico = true;
    else if (a === '--manifest') out.manifest = true;
    else if (a === '--flat-names') out['flat-names'] = true;
    else if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      const key = (eq === -1 ? a.slice(2) : a.slice(2, eq));
      const val = eq === -1 ? argv[++i] : a.slice(eq + 1);
      if (!(key in out)) die(`Unknown option --${key}. Try --help.`);
      out[key] = val;
    } else rest.push(a);
  }
  return [out, rest];
}

/* ---------- colour math (sRGB ↔ OKLCH) ---------- */
const f = v => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
const g = v => (v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055);
const cl = v => Math.max(0, Math.min(1, v));

function hexToRgb(hex) {
  let h = String(hex).trim().replace('#', '');
  if (h.length === 3) h = h.split('').map(c => c + c).join('');
  if (h.length === 8) h = h.slice(0, 6);
  const n = parseInt(h, 16);
  if (!isFinite(n)) return null;
  return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
}
function rgbToHex(r) {
  return '#' + r.map(v => Math.round(cl(v) * 255).toString(16).padStart(2, '0')).join('');
}
function rgbToOklab([r, gg, b]) {
  const R = f(r), G = f(gg), B = f(b);
  const l = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
  const m = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
  const s = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  ];
}
function oklabToRgb([L, a, b]) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
  return [
    g(cl(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
    g(cl(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
    g(cl(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
  ];
}
const toLch = ([L, a, b]) => [L, Math.hypot(a, b), Math.atan2(b, a)];
const fromLch = ([L, C, h]) => [L, C * Math.cos(h), C * Math.sin(h)];

/**
 * Brand base colour → the two-stop tile gradient.
 * Both stops share the base hue and are pinned to fixed lightness steps, so every
 * icon in the set carries the same depth no matter how light or dark the brand is.
 */
function rampFromBase(baseHex, { chroma = 1 } = {}) {
  const rgb = hexToRgb(baseHex);
  if (!rgb) return { c1: '#4ea0f5', c2: '#1a6bd0' };
  let [L, C, h] = toLch(rgbToOklab(rgb));
  if (C < 0.02) C = 0.02;                       // achromatic brands get a whisper of hue
  // Chromatic brands can sit bright and stay legible; near-grey brands need real depth
  // or the tile turns to fog, so the whole ramp slides down as chroma falls away.
  const t = Math.min(C, 0.12) / 0.12;
  const light = 0.55 + 0.11 * t;
  const dark = 0.29 + 0.17 * t;
  const C1 = Math.min(0.19, C * 0.95 * chroma);
  const C2 = Math.min(0.19, C * 1.0 * chroma);
  return {
    c1: rgbToHex(oklabToRgb(fromLch([light, C1, h]))),
    c2: rgbToHex(oklabToRgb(fromLch([dark, C2, h])))
  };
}

/* ---------- glyph intake (no DOM in Node) ---------- */
const SHAPES = /^(path|circle|ellipse|rect|polygon|polyline|line|g|use)$/i;

// Normalise an SVG file into a monochrome glyph: drop presentation attributes so
// the mark inherits the icon's ink colour, keep genuine fill="none" holes, and
// keep strokes as currentColor. Returns { viewBox:[x,y,w,h], inner }.
function parseGlyphSVG(text, what = 'That file') {
  let s = String(text);
  const open = s.match(/<svg\b[^>]*>/i);
  if (!open) die(`${what} has no <svg> root.`);
  let inner = s.slice(open.index + open[0].length).replace(/<\/svg\s*>\s*$/i, '');
  inner = inner
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<(style|title|desc|metadata|script|image)\b[\s\S]*?<\/\1\s*>/gi, '')
    .replace(/<(style|title|desc|metadata|script|image)\b[^>]*\/>/gi, '');

  inner = inner.replace(/<([a-z:-]+)\b([^>]*)>/gi, (m, tag, attrs) => {
    if (!SHAPES.test(tag)) return m;
    const cleaned = attrs.replace(/\s(fill|stroke|class|style|color)\s*=\s*("[^"]*"|'[^']*')/gi,
      (am, attr, raw) => {
        const v = raw.slice(1, -1).trim();
        if (attr.toLowerCase() === 'stroke' && v !== 'none') return ' stroke="currentColor"';
        if (attr.toLowerCase() === 'fill' && v === 'none') return am;   // keep genuine holes
        return '';
      });
    return `<${tag}${cleaned}>`;
  });

  inner = inner.replace(/\s+/g, ' ').trim();
  if (!inner) die(`No drawable shapes found in ${what.toLowerCase()}.`);

  let vb = (open[0].match(/viewBox\s*=\s*["']([^"']+)["']/i)?.[1] || '').trim().split(/[\s,]+/).map(Number);
  if (vb.length !== 4 || vb.some(n => !isFinite(n))) {
    const num = a => parseFloat(open[0].match(new RegExp(a + '\\s*=\\s*["\']([\\d.]+)', 'i'))?.[1]);
    vb = [0, 0, num('width') || 24, num('height') || 24];
  }
  return { viewBox: vb, inner };
}

/** Sniff the brand colour out of the source file: the most-used non-neutral fill. */
function sniffBrandColor(text) {
  const hits = String(text).match(/#[0-9a-f]{6}\b|#[0-9a-f]{3}\b/gi) || [];
  const tally = new Map();
  for (const raw of hits) {
    const hex = rgbToHex(hexToRgb(raw));
    const [L, C] = toLch(rgbToOklab(hexToRgb(hex)));
    if (C < 0.045 || L < 0.12 || L > 0.95) continue;          // skip greys, near-black, near-white
    tally.set(hex, (tally.get(hex) || 0) + 1);
  }
  if (!tally.size) return null;
  return [...tally.entries()].sort((a, b) => b[1] - a[1])[0][0];
}

/* ---------- the MCP watermark ---------- */
// Read from disk at startup, not inlined: swapping the mark is a file swap, and
// the tile picks up the replacement's own viewBox rather than assuming 24x24.
const MARK_FILE = join(import.meta.dirname, 'logo.svg');
const MARK = parseGlyphSVG(
  await readFile(MARK_FILE, 'utf8').catch(() => die(`Cannot read the MCP mark at ${MARK_FILE}`)),
  'The MCP mark');

/* ---------- optical sizing ---------- */
const TARGET_INK = 0.125;   // em² of glyph ink inside a 1em tile
const LIVE_MAX = 0.62;      // keyline: no glyph bbox exceeds 62% of the tile
const INK = '#f3f5fe';      // neutral-100

/** Glyph side, in em, that equalises optical weight across brands. */
function glyphScale(m) {
  if (!m) return 0.56;
  return Math.round(Math.min(Math.sqrt(TARGET_INK / m.ink), LIVE_MAX / m.w, LIVE_MAX / m.h) * 1000) / 1000;
}
/** Small tiles lose the glyph to the padding — tighten the margin as the icon shrinks. */
function glyphScaleAt(base, px) {
  return Math.min(0.72, base * Math.min(1.22, Math.max(1, 1 + (64 - px) * 0.0045)));
}

// Ink area + bbox as fractions of the box — the numbers optical sizing runs on.
async function measureGlyph(glyph, raster, N = 96) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${N}" height="${N}" ` +
    `viewBox="${glyph.viewBox.join(' ')}"><g fill="#000" stroke-width="0.6">${glyph.inner}</g></svg>`;
  const d = await raster.rgba(svg, N);
  let ink = 0, x0 = N, y0 = N, x1 = 0, y1 = 0;
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (d[(y * N + x) * 4 + 3] / 255 > 0.5) {
      ink++;
      if (x < x0) x0 = x; if (x > x1) x1 = x;
      if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
  }
  if (!ink) return null;
  return { ink: ink / (N * N), w: (x1 - x0 + 1) / N, h: (y1 - y0 + 1) / N };
}

/* ---------- the icon ---------- */
/**
 * One self-contained SVG icon: soft-light MCP mark over the brand gradient.
 * No CSS variables, no external refs — safe to rasterise or hand to a designer.
 */
function buildIconSVG({ glyph, metrics, c1, c2, size = 512, ink, id = 'i', mcpMark = true, rounded = true }) {
  const S = 1000, R = rounded ? 225 : 0;
  const gs = glyphScaleAt(glyphScale(metrics), size) * S;
  const gx = (S - gs) / 2, gy = (S - gs) / 2;
  const wm = 1200, wx = -140, wy = -120;
  const vb = glyph.viewBox.join(' ');
  const glyphInk = ink || INK;
  const u = n => `${id}-${n}`;

  const bg = `<rect width="${S}" height="${S}" fill="url(#${u('bg')})"/>`;

  const mark = !mcpMark ? '' :
    `<svg x="${wx}" y="${wy}" width="${wm}" height="${wm}" viewBox="${MARK.viewBox.join(' ')}" ` +
    `fill="${INK}" opacity="0.55" mask="url(#${u('fade')})" ` +
    `style="mix-blend-mode:soft-light" overflow="visible">${MARK.inner}</svg>`;

  const defs =
    `<clipPath id="${u('clip')}"><rect width="${S}" height="${S}" rx="${R}" ry="${R}"/></clipPath>` +
    `<linearGradient id="${u('bg')}" x1="0" y1="0" x2="0.82" y2="1">` +
    `<stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/></linearGradient>` +
    `<linearGradient id="${u('fadeG')}" x1="0" y1="0" x2="0.5" y2="0.87">` +
    `<stop offset="0.08" stop-color="#fff"/><stop offset="0.58" stop-color="#fff" stop-opacity="0.35"/>` +
    `<stop offset="0.92" stop-color="#fff" stop-opacity="0"/></linearGradient>` +
    `<mask id="${u('fade')}"><rect x="-200" y="-200" width="1600" height="1600" fill="url(#${u('fadeG')})"/></mask>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${S} ${S}" role="img">` +
    `<defs>${defs}</defs><g clip-path="url(#${u('clip')})">${bg}${mark}` +
    `<svg x="${gx.toFixed(1)}" y="${gy.toFixed(1)}" width="${gs.toFixed(1)}" height="${gs.toFixed(1)}" viewBox="${vb}" fill="${glyphInk}" stroke="none" overflow="visible"><g fill="${glyphInk}" color="${glyphInk}">${glyph.inner}</g></svg>` +
    `</g></svg>`;
}

/* ---------- rasteriser (optional dependency) ---------- */
async function loadRasterizer() {
  try {
    const { Resvg } = await import('@resvg/resvg-js');
    return {
      name: 'resvg',
      png: (svg, size) => Buffer.from(
        new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng()),
      rgba: (svg, size) => {
        const img = new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render();
        return Buffer.from(img.pixels);
      }
    };
  } catch {}
  try {
    const sharp = (await import('sharp')).default;
    return {
      name: 'sharp',
      png: (svg, size) => sharp(Buffer.from(svg), { density: 384 }).resize(size, size).png().toBuffer(),
      rgba: (svg, size) => sharp(Buffer.from(svg), { density: 384 })
        .resize(size, size).ensureAlpha().raw().toBuffer()
    };
  } catch {}
  return null;
}

/* ---------- .ico container ---------- */
// An .ico is a 6-byte header, one 16-byte directory entry per image, then the
// image payloads — and since Vista the payloads may be PNGs verbatim, so the
// PNGs we already rendered go in untouched.
function packICO(entries) {
  const head = Buffer.alloc(6);
  head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(entries.length, 4);
  const dir = Buffer.alloc(16 * entries.length);
  let offset = head.length + dir.length;
  entries.forEach((e, i) => {
    const o = i * 16;
    dir.writeUInt8(e.size >= 256 ? 0 : e.size, o);
    dir.writeUInt8(e.size >= 256 ? 0 : e.size, o + 1);
    dir.writeUInt16LE(1, o + 4);        // color planes
    dir.writeUInt16LE(32, o + 6);       // bits per pixel
    dir.writeUInt32LE(e.png.length, o + 8);
    dir.writeUInt32LE(offset, o + 12);
    offset += e.png.length;
  });
  return Buffer.concat([head, dir, ...entries.map(e => e.png)]);
}

/* ---------- run ---------- */
const [opts, args] = parseArgs(process.argv.slice(2));
if (opts.help || !args.length) { console.log(HELP); process.exit(args.length ? 0 : 1); }

const inputs = args.map(a => resolve(a));
const batch = inputs.length > 1;
for (const p of inputs) if (extname(p).toLowerCase() !== '.svg') die(`Inputs must be .svg glyphs — got ${basename(p)}.`);
if (batch && opts.color) die('--color applies to one glyph; drop it so each is sniffed, or run them separately.');

const raster = opts.png ? await loadRasterizer() : null;
if (opts.png && !raster) die('No rasteriser found. Run `npm i @resvg/resvg-js` (or `sharp`), or pass --no-png.');

const dir = resolve(opts.out);
await mkdir(dir, { recursive: true });

const results = [];
for (const src of inputs) results.push(await one(src));

if (opts.json) console.log(JSON.stringify(batch ? results : results[0], null, 2));
else if (!opts.quiet) {
  for (const m of results) {
    console.log(`${basename(m.source)}  →  ${m.out}`);
    console.log(`  brand ${m.brand}   ramp ${m.ramp[0]} → ${m.ramp[1]}   glyph ${m.glyphScale}em` +
      (m.ink != null ? `   ink ${(m.ink * 100).toFixed(1)}%` : '  (no metrics: --no-png)'));
    for (const f of m.files) console.log(`  ${f.file.padEnd(28)} ${f.use}`);
  }
  if (batch) console.log(`\n${results.length} icon sets, ${results.reduce((n, m) => n + m.files.length, 0)} files.`);
}

async function one(src) {
  const text = await readFile(src, 'utf8').catch(() => die(`Cannot read ${src}`));

  const glyph = parseGlyphSVG(text, basename(src));
  const base = opts.color || sniffBrandColor(text);
  if (!base) die('No brand colour found in the file — pass one with --color "#4ea0f5".');
  if (!/^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(base)) die(`--color must be a hex value, got "${base}".`);
  const { c1, c2 } = rampFromBase(base, { chroma: Number(opts.chroma) || 1 });

  const metrics = raster ? await measureGlyph(glyph, raster) : null;
  const prefix = (!batch && opts.name) || basename(src, extname(src)).replace(/[^\w.-]+/g, '-');
  const flat = opts['flat-names'] && !batch;
  const stem = flat ? 'icon' : prefix;
  if (!raster && (opts.ico || opts.manifest)) die('--ico and --manifest need the PNG ladder — drop --no-png.');
  const sizes = !raster ? []
    : opts.sizes
      ? String(opts.sizes).split(',').map(n => parseInt(n, 10)).filter(n => n > 0)
      : LADDER.map(s => s.size);
  const useOf = Object.fromEntries(LADDER.map(s => [s.size, s.use]));

  const shared = {
    glyph, metrics, c1, c2,
    mcpMark: opts['mcp-mark'], rounded: opts.rounded
  };

  const written = [];
  const pngs = new Map();
  const masterName = `${stem}.svg`;
  await writeFile(join(dir, masterName), buildIconSVG({ ...shared, id: prefix, size: 512 }));
  written.push({ file: masterName, kind: 'svg', size: 512, use: 'master' });

  for (const size of sizes) {
    const svg = buildIconSVG({ ...shared, id: `${prefix}-${size}`, size });
    const name = `${stem}-${size}.png`;
    const buf = await raster.png(svg, size);
    pngs.set(size, buf);
    await writeFile(join(dir, name), buf);
    written.push({ file: name, kind: 'png', size, use: useOf[size] || '' });
  }

  // /favicon.ico — still the fallback Windows, Safari pinned tabs and any
  // browser that ignores <link rel="icon"> reach for by convention.
  if (opts.ico) {
    const want = [16, 32, 48].filter(n => pngs.has(n));
    if (!want.length) die('--ico needs 16, 32 or 48 in --sizes.');
    const name = flat ? 'favicon.ico' : `${stem}.ico`;
    await writeFile(join(dir, name), packICO(want.map(n => ({ size: n, png: pngs.get(n) }))));
    written.push({ file: name, kind: 'ico', size: Math.max(...want), use: `legacy favicon (${want.join('/')})` });
  }

  // The PWA icons block: what Chrome and Android read to install the app and draw
  // the home-screen icon. 192 and 512 are the two sizes the install prompt requires;
  // maskable lets Android crop the tile to the launcher's own shape.
  if (opts.manifest) {
    const icons = written.filter(f => f.kind === 'png' && f.size >= 192).map(f => ({
      src: f.file, sizes: `${f.size}x${f.size}`, type: 'image/png',
      purpose: 'any maskable'
    }));
    if (!icons.length) die('--manifest needs at least one size of 192 or above.');
    const name = flat ? 'manifest.webmanifest' : `${stem}.webmanifest`;
    await writeFile(join(dir, name), JSON.stringify({
      name: prefix, short_name: prefix, icons,
      background_color: c2, theme_color: base, display: 'standalone'
    }, null, 2) + '\n');
    written.push({ file: name, kind: 'webmanifest', size: null, use: 'PWA icons block' });
  }

  return {
    source: src, brand: base, ramp: [c1, c2],
    glyphScale: glyphScale(metrics), ink: metrics ? +(metrics.ink).toFixed(4) : null,
    rasterizer: raster?.name || null, out: dir, files: written
  };
}
