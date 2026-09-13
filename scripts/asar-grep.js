/* 在 app.asar 的**打包条目内容**里搜关键字（按路径过滤只是 list 的能力，这里搜内容）
 * 用法：node scripts/asar-grep.js <asar> <kw1> [kw2] [kw3] ... [--pad=200] [--max=6] [--ext=js]
 */
const fs = require('fs');

function readHeader(buf) {
  const headerBufLen = buf.readUInt32LE(4);
  const jsonLen = buf.readUInt32LE(12);
  return { header: JSON.parse(buf.slice(16, 16 + jsonLen).toString('utf8')), contentOffset: 8 + headerBufLen };
}
function walk(node, prefix, out) {
  const files = node.files || {};
  for (const name of Object.keys(files)) {
    const e = files[name];
    const p = prefix ? prefix + '/' + name : name;
    if (e.files) walk(e, p, out); else out.push({ path: p, entry: e });
  }
  return out;
}

const argv = process.argv.slice(2);
const asarPath = argv.shift();
const opts = { pad: 200, max: 6, ext: '' };
const kws = [];
for (const a of argv) {
  if (a.startsWith('--pad=')) opts.pad = Number(a.slice(6));
  else if (a.startsWith('--max=')) opts.max = Number(a.slice(6));
  else if (a.startsWith('--ext=')) opts.ext = a.slice(6);
  else kws.push(a);
}

const buf = fs.readFileSync(asarPath);
const { header, contentOffset } = readHeader(buf);
const all = walk(header, '', []);
console.log(`条目 ${all.length} 个，关键字 ${JSON.stringify(kws)}`);

let hits = 0, scanned = 0, scannedBytes = 0;
for (const it of all) {
  const e = it.entry;
  if (e.unpacked) continue;
  if (opts.ext && !it.path.endsWith('.' + opts.ext)) continue;
  const off = Number(e.offset), size = Number(e.size);
  if (!Number.isFinite(off) || !Number.isFinite(size)) continue;
  scanned++; scannedBytes += size;
  const txt = buf.slice(contentOffset + off, contentOffset + off + size).toString('utf8');
  for (const kw of kws) {
    const i = txt.indexOf(kw);
    if (i < 0) continue;
    hits++;
    console.log(`\n=== [${kw}] ${it.path}  size=${size}  offset=${i} ===`);
    console.log(txt.slice(Math.max(0, i - opts.pad), i + kw.length + opts.pad).replace(/\n/g, '⏎'));
    if (hits >= opts.max) {
      console.log(`\n已到 --max=${opts.max} 上限（扫描 ${scanned} 个条目 / ${(scannedBytes / 1048576).toFixed(0)} MB）`);
      process.exit(0);
    }
    break; // 每个条目只报一次
  }
}
console.log(`\n扫描 ${scanned} 个条目 / ${(scannedBytes / 1048576).toFixed(0)} MB，命中 ${hits} 处`);

