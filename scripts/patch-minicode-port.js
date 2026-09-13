/* patch-minicode-port.js —— 修微信开发者工具「minicode server 双端口」bug
 *
 * 为什么需要它：app.asar 里的 MiniCodeService 把端口写死成 32123，只回退一次到 33233：
 *
 *   constructor(...) { this.currentPort = 32123 }
 *   listen(e) {
 *     e.listen(this.currentPort, '127.0.0.1')
 *     e.on('error', t => { if (t.code === 'EADDRINUSE') { this.currentPort = 33233; e.listen(this.currentPort, '127.0.0.1') } })
 *   }
 *
 * 33233 也被占 → 再次进入同一分支 → 无限重试，主进程死循环（实测 5 秒涨 6.5 秒 CPU、内存 +120MB），
 * Windows 约 30 秒后按无响应杀掉（Application Hang 1002 / WER AppHangB1）。
 * 表现：第 3 个实例起不来——无窗口、进程停在 4~6 个（健康实例 20~21）、日志末行停在 `enable cli service`。
 * 所以该版本同时最多 2 台实例；要更多，就给每个副本一组独立端口。
 *
 * 用法：
 *   node patch-minicode-port.js <实例名> <主端口> <回退端口>     # 打补丁（先停该实例！）
 *   node patch-minicode-port.js --check <实例名>                # 只看当前端口，不改
 *   node patch-minicode-port.js --revert <实例名>               # 从 app.asar.bak-minicode 还原
 *
 * 例（实测分配，四台互不冲突）：
 *   p2 32123/33233（主安装默认，无需改）  p3 32124/33234  p4 32125/33235  p5 32126/33236
 *
 * 注意：
 *   1. asar 头部记录了每个文件的偏移，替换必须**字节等长** —— 端口固定 5 位数字。
 *   2. 只改 <InstallRoot>-pN 副本，别动主安装；每份会留 app.asar.bak-minicode。
 *   3. 改之前必须停掉该实例进程（app.asar 被占用时写不进去）。
 */
const fs = require('fs');
const path = require('path');

const NEEDLE_MAIN = 'this.currentPort=32123';
const NEEDLE_FALLBACK = 'this.currentPort=33233';
const MARKER = 'minicode server started';

const count = (hay, needle) => { let i = hay.indexOf(needle), n = 0; while (i >= 0) { n++; i = hay.indexOf(needle, i + 1); } return n; };

function asarOf(name) {
  const file = `D:/Tencent/wechatdev-${name}/resources/app.asar`;
  if (!fs.existsSync(file)) throw new Error('找不到 ' + file + '（--install-root 不是 D:\\Tencent\\wechatdev 时请改用绝对路径）');
  return file;
}

function main() {
  const [mode, name, mainPort, fallbackPort] = process.argv.slice(2);
  if (!mode) {
    console.error('用法：node patch-minicode-port.js <实例名> <主端口> <回退端口> | --check <实例名> | --revert <实例名>');
    process.exit(1);
  }
  const target = mode.startsWith('--') ? name : mode;
  const file = asarOf(target);
  const backup = `${file}.bak-minicode`;

  if (mode === '--revert') {
    if (!fs.existsSync(backup)) { console.error('没有备份 ' + backup + '，无法还原'); process.exit(1); }
    fs.copyFileSync(backup, file);
    console.log(`${target}: 已从 ${path.basename(backup)} 还原`);
    return;
  }

  const current = fs.readFileSync(file);
  const text = current.toString('latin1');   // latin1 = 1 字符 1 字节，索引与字节偏移一致

  if (mode === '--check') {
    const m = text.match(/this\.currentPort=(\d{5})/g) || [];
    console.log(`${target}: ${m.join(' / ') || '未找到端口常量'}`);
    return;
  }

  if (!/^\d{5}$/.test(String(mainPort)) || !/^\d{5}$/.test(String(fallbackPort))) {
    console.error('端口必须是 5 位数字（保持字节长度）'); process.exit(4);
  }
  if (count(text, NEEDLE_MAIN) !== 1 || count(text, NEEDLE_FALLBACK) !== 1) {
    console.error(`常量出现次数异常（${count(text, NEEDLE_MAIN)}/${count(text, NEEDLE_FALLBACK)}），拒绝修改——可能已打过补丁或版本不同`);
    process.exit(2);
  }
  if (!text.includes(MARKER)) { console.error('没找到 MiniCodeService 特征串，拒绝修改'); process.exit(3); }

  const patched = text
    .replace(NEEDLE_MAIN, `this.currentPort=${mainPort}`)
    .replace(NEEDLE_FALLBACK, `this.currentPort=${fallbackPort}`);
  const out = Buffer.from(patched, 'latin1');
  if (out.length !== current.length) { console.error('长度变了，拒绝写入'); process.exit(5); }

  if (!fs.existsSync(backup)) fs.writeFileSync(backup, current);
  fs.writeFileSync(file, out);

  const back = fs.readFileSync(file).toString('latin1');
  const ok = count(back, `this.currentPort=${mainPort}`) === 1 && count(back, `this.currentPort=${fallbackPort}`) === 1;
  console.log(`${target}: 32123 -> ${mainPort}，33233 -> ${fallbackPort}；长度 ${out.length}（未变）；备份 ${path.basename(backup)}；读回校验 ${ok ? 'OK' : '失败'}`);
  if (!ok) process.exit(6);
}

try { main(); } catch (e) { console.error(String(e.message || e)); process.exit(1); }
