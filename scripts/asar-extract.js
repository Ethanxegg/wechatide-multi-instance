/* 从 app.asar 里按条目路径抠出单个文件
 * 用法：node scripts/asar-extract.js <asar> <条目路径> [输出文件]
 */
const fs = require('fs');

const [asarPath, entryPath, outFile] = process.argv.slice(2);
if (!asarPath || !entryPath) {
  console.error('用法：node asar-extract.js <asar> <条目路径> [输出文件]');
  process.exit(1);
}

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
if (outFile) { fs.writeFileSync(outFile, txt); console.log(`已写出 ${outFile}（${txt.length} 字符）`); }
else process.stdout.write(txt);

