/* 在 IDE 的词条文件里按中文关键字反查 key（用于确认某个 UI 文案/开关到底存不存在）
 * 用法：node scripts/locale-find.js <asar> <词条条目路径> <中文关键字...>
 */
const fs = require('fs');

const [asarPath, entryPath, ...kws] = process.argv.slice(2);
const buf = fs.readFileSync(asarPath);
const headerBufLen = buf.readUInt32LE(4);
const jsonLen = buf.readUInt32LE(12);
const header = JSON.parse(buf.slice(16, 16 + jsonLen).toString('utf8'));
const contentOffset = 8 + headerBufLen;

function find(node, prefix) {
  const files = node.files || {};
  for (const k of Object.keys(files)) {
    const e = files[k];
    const p = prefix ? prefix + '/' + k : k;
    if (e.files) { const r = find(e, p); if (r) return r; }
    else if (p === entryPath) return e;
  }
  return null;
}
const entry = find(header, '');
if (!entry) { console.error('找不到条目：' + entryPath); process.exit(2); }
const txt = buf.slice(contentOffset + Number(entry.offset), contentOffset + Number(entry.offset) + Number(entry.size)).toString('utf8');

// 抓 KEY:"中文值" / KEY:'中文值'
const pairs = [...txt.matchAll(/([A-Z][A-Z0-9_]{2,})\s*:\s*["']([^"'\n]{1,80})["']/g)].map((m) => [m[1], m[2]]);
const hits = pairs.filter(([, v]) => kws.some((kw) => v.includes(kw)));
console.log(`词条 ${pairs.length} 条，命中 ${hits.length} 条（关键字 ${JSON.stringify(kws)}）`);
for (const [k, v] of hits) console.log(`  ${k} = ${v}`);

