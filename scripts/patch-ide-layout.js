/* 改某个开发者工具实例的「面板布局」状态（调试器弹出为独立窗口 / 只留模拟器）
 *
 * 状态文件：<profile>\WeappLocalData\localstorage_<hash>.json（含 debug / simulator / editor 三个键；
 * 另一个 localstorage_<hash>.json 是设置，含 appearance.editorShow/debugShow/simulatorShow）
 * 关键位：debug.popup = true → 调试器弹出成独立窗口（面板处显示「调试器已经弹出」）
 *         debug.show / simulator.show / editor.show → 面板是否显示
 *         simulator.popup = true → 模拟器改为弹窗形式（本次要 false，让预览留在主窗口）
 *
 * 用法：node .local-scratch/patch-ide-layout.js <实例名> [--debug-popup=on|off] [--debug-show=on|off]
 *                                            [--editor-show=on|off] [--simulator-show=on|off]
 *                                            [--simulator-popup=on|off] [--dry]
 * 注意：必须在**实例已停**时改，运行时改会被 IDE 覆盖。
 */
const fs = require('fs');
const path = require('path');

const LOCALAPPDATA = process.env.LOCALAPPDATA;
const USER_DATA = path.join(LOCALAPPDATA, '微信开发者工具', 'User Data');

function profileDirOf(instance, idePort) {
  // 默认实例名→IDE 端口表；也可用 --ide-port= 显式指定
  const want = idePort || { p2: '43595', p3: '43596', p4: '43597', p5: '43598' }[instance];
  const dirs = fs.readdirSync(USER_DATA, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  for (const d of dirs) {
    const wl = path.join(USER_DATA, d, 'WeappLocalData');
    if (!fs.existsSync(wl)) continue;
    for (const f of fs.readdirSync(wl)) {
      if (!f.endsWith('.json')) continue;
      try {
        const j = JSON.parse(fs.readFileSync(path.join(wl, f), 'utf8'));
        if (j && j.debug && j.simulator && j.editor && j.simulator.width !== undefined && j.debug.popup !== undefined) {
          const ide = path.join(USER_DATA, d, 'Default', '.ide');
          const port = fs.existsSync(ide) ? fs.readFileSync(ide, 'utf8').trim() : '';
          if (want && port === want) return { dir: wl, file: path.join(wl, f), state: j, profile: d };
        }
      } catch (e) { /* 不是 JSON 或无关键键 */ }
    }
  }
  return null;
}

const [instance, ...flags] = process.argv.slice(2);
if (!instance) { console.error('用法：node patch-ide-layout.js <实例名> [--ide-port=43597] [--debug-popup=on|off] …'); process.exit(1); }
const dry = flags.includes('--dry');
const idePortFlag = (flags.find((f) => f.startsWith('--ide-port=')) || '').split('=')[1];
const set = {};
for (const f of flags) {
  const m = f.match(/^--([a-z-]+)=(on|off)$/);
  if (m) set[m[1]] = m[2] === 'on';
}
const on = (v) => (v === undefined ? undefined : !!v);

const found = profileDirOf(instance, idePortFlag);
if (!found) { console.error(`[${instance}] 找不到面板状态文件（实例是否从未开过工程窗口？）`); process.exit(2); }

const s = found.state;
const before = { 'debug.popup': s.debug.popup, 'debug.show': s.debug.show, 'simulator.show': s.simulator.show, 'simulator.popup': s.simulator.popup, 'editor.show': s.editor.show };

if (on(set['debug-popup']) !== undefined) s.debug.popup = on(set['debug-popup']);
if (on(set['debug-show']) !== undefined) s.debug.show = on(set['debug-show']);
if (on(set['editor-show']) !== undefined) s.editor.show = on(set['editor-show']);
if (on(set['simulator-show']) !== undefined) s.simulator.show = on(set['simulator-show']);
if (on(set['simulator-popup']) !== undefined) s.simulator.popup = on(set['simulator-popup']);

const after = { 'debug.popup': s.debug.popup, 'debug.show': s.debug.show, 'simulator.show': s.simulator.show, 'simulator.popup': s.simulator.popup, 'editor.show': s.editor.show };
console.log(`[${instance}] profile=${found.profile}  文件=${path.basename(found.file)}`);
console.log('  改前', JSON.stringify(before));
console.log('  改后', JSON.stringify(after));
if (dry) { console.log('  --dry：未写入'); process.exit(0); }

const bak = `${found.file}.bak-layout`;
if (!fs.existsSync(bak)) fs.writeFileSync(bak, fs.readFileSync(found.file));
fs.writeFileSync(found.file, JSON.stringify(s));
console.log(`  已写入（备份 ${path.basename(bak)}）`);

// 同步设置文件里的三处开关，避免与状态文件不一致
const settingsFile = path.join(found.dir, path.basename(found.file).replace(/^localstorage_/, 'localstorage_'));
for (const f of fs.readdirSync(found.dir)) {
  if (!/^(localstorage|ls)_.*\.json$/.test(f)) continue;
  const p = path.join(found.dir, f);
  if (p === found.file) continue;
  try {
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (!j.appearance) continue;
    const b = { editorShow: j.appearance.editorShow, debugShow: j.appearance.debugShow, simulatorShow: j.appearance.simulatorShow };
    if (on(set['editor-show']) !== undefined) j.appearance.editorShow = on(set['editor-show']);
    if (on(set['debug-show']) !== undefined) j.appearance.debugShow = on(set['debug-show']);
    if (on(set['simulator-show']) !== undefined) j.appearance.simulatorShow = on(set['simulator-show']);
    const bak2 = `${p}.bak-layout`;
    if (!fs.existsSync(bak2)) fs.writeFileSync(bak2, fs.readFileSync(p));
    fs.writeFileSync(p, JSON.stringify(j));
    console.log(`  设置文件 ${f}：${JSON.stringify(b)} → ${JSON.stringify({ editorShow: j.appearance.editorShow, debugShow: j.appearance.debugShow, simulatorShow: j.appearance.simulatorShow })}`);
  } catch (e) { /* 跳过非设置文件 */ }
}
