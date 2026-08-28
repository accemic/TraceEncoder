// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: ISC
//
// Gate B1-2: addresses in the dashboard are not truncated to 32 bit.
//
// What is checked is the SHIPPED code: hex64() is cut out of index.html
// and executed, not reimplemented here. A copy would become a lie after
// the first edit to index.html.
//
// The gate has three parts, and the third is the most important:
//   1. hex64() returns the correct result for RV32, boundary, and Sv39
//      addresses.
//   2. index.html no longer contains `>>>0` or Number()-based hex at the
//      address sites (text check -- otherwise one site gets fixed and the
//      second is missed).
//   3. COUNTERPROOF: the OLD expressions must be WRONG on the same vectors.
//      If they are not, the gate checks nothing and flags itself red.
//
// Invocation:  node tools/ctrace_dashboard/test_addr64.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
// Normalize CRLF: index.html has Windows line endings in the tree; the
// pattern checks below should not depend on that.
const HTML = readFileSync(join(HERE, 'index.html'), 'utf8').replace(/\r\n/g, '\n');

// --- 1. Get hex64 from the shipped file -------------------------------------
function extract(name) {
  const start = HTML.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`function ${name}() not found in index.html`);
  const end = HTML.indexOf('\n}\n', start);
  if (end < 0) throw new Error(`End of ${name}() not found`);
  return HTML.slice(start, end + 2);
}
const hex64 = new Function(`${extract('hex64')}; return hex64;`)();

// --- Vectors -----------------------------------------------------------------
// The Sv39 address is not made up: it is the load address of
// sw/cva6_char/char_test_hi64.elf (readelf -l: 0xffffffc063fff000).
const V = [
  { what: 'null/0',             in: '0x0',                want: '0x00000000' },
  { what: 'RV32 MBV RAM',       in: '0xa0100000',         want: '0xA0100000' },
  { what: 'RV32 CVA6 DDR',      in: '0x64000000',         want: '0x64000000' },
  { what: 'RV32 boundary',      in: '0xffffffff',         want: '0xFFFFFFFF' },
  { what: 'first 33-bit addr',  in: '0x100000000',        want: '0x100000000' },
  { what: 'above 2**53',        in: '0x20000000000001',   want: '0x20000000000001' },
  { what: 'Rocket guest RAM',   in: '0x80000000',         want: '0x80000000' },
  { what: 'Sv39 hi64 (ELF)',    in: '0xffffffc063fff000', want: '0xFFFFFFC063FFF000' },
  { what: 'Sv39 fn odd',        in: '0xffffffc063fff12c', want: '0xFFFFFFC063FFF12C' },
  { what: 'Sv39 Linux kernel',  in: '0xffffffff80200abc', want: '0xFFFFFFFF80200ABC' },
];

// The OLD path, as it actually ran: the server sent `addr` as a JSON NUMBER,
// the browser turned it into a double, and only then did
// `Number(d.a).toString(16)` run. The rounding therefore already happens in
// transport -- which is why it is simulated here instead of formatting the
// string directly.
const oldPath  = big => {
  const n = JSON.parse(`{"a":${big}}`).a;         // JSON number -> double
  return '0x' + Number(n).toString(16).padStart(8, '0');
};
const newPath  = big => hex64(JSON.parse(`{"a":"0x${big.toString(16)}"}`).a);
const old_shift = x => '0x' + (x >>> 0).toString(16).toUpperCase().padStart(8, '0');

let fails = [];
let counterproof = 0;

console.log('%s %s %s %s %s',
  'vector'.padEnd(22), 'input'.padEnd(22), 'hex64 (JSON string)'.padEnd(21),
  'old (JSON number)'.padEnd(21), 'old >>>0');
for (const v of V) {
  const big = BigInt(v.in);
  const got = hex64(v.in);
  const gotJson = newPath(big);
  const oldT = oldPath(big);
  const oldS = old_shift(Number(v.in));
  if (got !== v.want) fails.push(`${v.what}: hex64(${v.in}) = ${got}, expected ${v.want}`);
  if (gotJson !== v.want) fails.push(`${v.what}: via JSON string = ${gotJson}, expected ${v.want}`);
  // Counterproof: above 32 bit, at least one of the old expressions MUST
  // return something other than the correct value.
  if (big > 0xffffffffn) {
    if (oldT.toUpperCase() === v.want && oldS === v.want) {
      fails.push(`${v.what}: COUNTERPROOF BLIND -- both old expressions are correct here`);
    } else counterproof++;
  }
  console.log('%s %s %s %s %s',
    v.what.padEnd(22), v.in.padEnd(22), String(got).padEnd(21),
    oldT.padEnd(21), oldS);
}

// --- 2. JSON path: why the server sends hex STRINGS -------------------------
// Even a perfect renderer would come too late if the number is already
// rounded at JSON.parse. This proves that the server change (addr as
// string) is necessary, not just a matter of taste.
const sv39 = 0xffffffc063fff12cn;   // function start with low bits set
const asNumber = JSON.parse(`{"addr": ${sv39}}`).addr;
const asString = JSON.parse(`{"addr": "0x${sv39.toString(16)}"}`).addr;
if (BigInt(asNumber) === sv39) {
  fails.push('COUNTERPROOF BLIND -- JSON number survives 0x' + sv39.toString(16)
    + ' losslessly; the string representation would then be unnecessary');
} else counterproof++;
if (hex64(asString) !== '0x' + sv39.toString(16).toUpperCase()) {
  fails.push('JSON string path: hex64 returns ' + hex64(asString));
}
console.log(`\nJSON number  0x${sv39.toString(16)} -> 0x${BigInt(asNumber).toString(16)}`
  + `  (deviation ${(BigInt(asNumber) - sv39).toString()} bytes)`);
console.log(`JSON string                        -> ${hex64(asString)}  (exact)`);

// How frequent is the loss? Do not claim it, count it: 4-byte-aligned
// addresses over a 1-MiB window of the Sv39 kernel. (Some addresses survive
// by chance -- which is exactly what makes the defect insidious, because it
// looks like it "works after all".)
let lost = 0, n = 0;
for (let off = 0n; off < 0x100000n; off += 4n) {
  const a = 0xffffffc063f00000n + off;
  n++;
  if (BigInt(JSON.parse(`{"a":${a}}`).a) !== a) lost++;
}
console.log(`Sv39 sample: ${lost} of ${n} 4-byte-aligned addresses `
  + `(${(lost / n * 100).toFixed(1)} %) do NOT survive the JSON number path`);
if (lost === 0) fails.push('COUNTERPROOF BLIND -- not a single loss in the Sv39 sample');

// --- 3. Text check: no more 32-bit truncation at address sites --------------
// Not searching for the ONE known spot -- searching for the PATTERN.
const forbidden = [
  { re: /Number\(d\.a\)/, why: 'treemap tooltip converts the address via Number() again' },
  { re: /f\.addr[^_]*>>>\s*0/, why: 'function address truncated by >>>0' },
  { re: /pc(_lo|64|_hex)?\s*>>>\s*0/i, why: 'PC truncated by >>>0' },
];
for (const f of forbidden) {
  const m = HTML.match(f.re);
  if (m) fails.push(`index.html: ${f.why} (${m[0]})`);
}
// And the counterproof for the text check: the pattern must actually be
// able to match -- otherwise it too is blind.
if (!/Number\(d\.a\)/.test('tip 0x'+'Number(d.a).toString(16)')) {
  fails.push('COUNTERPROOF BLIND -- the text check does not find its own pattern');
} else counterproof++;

// --- 4. The script block must parse at all -----------------------------------
// A typo in index.html would otherwise only show up in the browser -- and
// there only to whoever has the console open. new Function() PARSES without
// executing.
const scripts = [...HTML.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
  .map(m => m[1]);
if (!scripts.length) fails.push('index.html: no inline <script> found');
try {
  new Function(scripts.join('\n'));
  console.log(`Script block: ${scripts.length} piece(s), ${scripts.join('').length} chars, parses`);
} catch (e) {
  fails.push('index.html: script block does not parse -- ' + e.message);
}

// --- Verdict -------------------------------------------------------------------
console.log();
if (fails.length) {
  console.log(`GATE B1-2: FAIL (${fails.length} findings)`);
  for (const f of fails) console.log('  - ' + f);
  process.exit(1);
}
console.log(`GATE B1-2: PASS -- ${V.length} vectors, ${counterproof} counterproofs red, `
  + `${forbidden.length} text patterns without match`);
