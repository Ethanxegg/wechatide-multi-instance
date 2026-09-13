/* console-watch.js —— 把各实例模拟器的 console 实时打到独立窗口
 *
 * 为什么不用每次调 CLI：`wechatide <tool>` 每次都会起一个 Electron 进程（~1-2s），
 * 四台轮询会很重。这里改成**每台保持一个 `wechatide mcp` 常驻进程**（stdio JSON-RPC），
 * 循环调用工具 `get_simulator_console`，只打印新增行。
 *
 * 用法：
 *   node .local-scratch/console-watch.js --project <工程绝对路径> [--instances p2,p3,p4,p5] [--interval 3000]
 *   node .local-scratch/console-watch.js --project <工程> --instances p3          # 只看一台
 *   node .local-scratch/console-watch.js --project <工程> --filter 'grep -n .'    # 看全部（含 info/log）
 * 选项：
 *   --levels warn,error    要显示的级别（默认 warn,error = warn 及以上）。**每个级别单独发一条 grep**：
 *                          过滤串经 cmd 传递，里面的 `|` 会被当管道符吃掉（`-E "warn|error"` 实测报错）
 *   --levels-file <文件>   从文件读过滤条件、**每轮重读**（改文件即可换过滤，不用重启窗口）：
 *                          内容 `warn,error` 视为级别列表；以 `grep ` 开头则整串当自定义过滤
 *   --filter <grep 串>     完全自定义过滤（给了就忽略 --levels / --levels-file）
 *   --install-root <目录>   各副本安装目录前缀（默认 D:\Tencent\wechatdev）
 *   --no-color              纯文本（重定向到文件时用）
 * 注意：MCP 客户端名必须是 IDE 已授权的那个（skill-cli 默认 `dsh`），换新名字 initialize 会返回
 *       "Client authorization pending"。
 */
const { spawn } = require('child_process');

const INSTANCES = {
  p2: { ide: 43595, label: '陈珂羽/导员', color: '\x1b[36m' },
  p3: { ide: 43596, label: '电💓我/导生', color: '\x1b[35m' },
  p4: { ide: 43597, label: 'Aaronnnnn/家长', color: '\x1b[33m' },
  p5: { ide: 43598, label: '纪文正/导生', color: '\x1b[32m' },
};
const RESET = '\x1b[0m';
const DIM = '\x1b[90m';

function parseArgs(argv) {
  const out = { project: '', instances: 'p2,p3,p4,p5', interval: 3000, installRoot: 'D:\\Tencent\\wechatdev', levels: 'warn,error', levelsFile: '', filter: '', color: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project') out.project = argv[++i];
    else if (a === '--instances') out.instances = argv[++i];
    else if (a === '--interval') out.interval = Number(argv[++i]);
    else if (a === '--install-root') out.installRoot = argv[++i];
    else if (a === '--levels') out.levels = argv[++i];
    else if (a === '--levels-file') out.levelsFile = argv[++i];
    else if (a === '--filter') out.filter = argv[++i];
    else if (a === '--no-color') out.color = false;
  }
  return out;
}

const opts = parseArgs(process.argv.slice(2));
if (!opts.project) { console.error('缺少 --project <工程绝对路径>'); process.exit(2); }
const names = opts.instances.split(',').map((s) => s.trim()).filter((n) => INSTANCES[n]);

/** 过滤条件：优先 --filter，其次 --levels-file（**每轮重读**，改文件即可换过滤，不用重启窗口），最后 --levels */
function currentGreps() {
  if (opts.filter) return [opts.filter];
  if (opts.levelsFile) {
    try {
      const raw = require('fs').readFileSync(opts.levelsFile, 'utf8').trim();
      if (raw) {
        if (raw.startsWith('grep ')) return [raw];
        return raw.split(',').map((s) => s.trim()).filter(Boolean).map((lvl) => `grep -n -i ${lvl}`);
      }
    } catch (e) { /* 文件不存在就退回默认 */ }
  }
  return opts.levels.split(',').map((s) => s.trim()).filter(Boolean).map((lvl) => `grep -n -i ${lvl}`);
}
const greps = currentGreps();

/** 一行的格式是 `<行号>:<console 条目的 JSON 数组>`；渲染成可读文本 */
function renderLine(raw) {
  if (/^--\s*$/.test(raw)) return null;                    // grep 的分组分隔行
  const m = raw.match(/^(\d+):(.*)$/s);
  const n = m ? Number(m[1]) : 0;
  const body = m ? m[2] : raw;
  let text = body;
  try {
    const arr = JSON.parse(body);
    if (Array.isArray(arr)) {
      const kind = String(arr[0] || '').replace(/[[\]]/g, '');
      text = `[${kind}] ` + arr.slice(1).map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ');
    }
  } catch (e) { /* 非 JSON 就原样打印 */ }
  return { n, text: text.replace(/\s+$/, '') };
}

function startInstance(name) {
  const meta = INSTANCES[name];
  const cmd = `${opts.installRoot}-${name}\\wechatide.cmd`;
  // Windows 上 Node 不能直接 spawn .cmd（EINVAL），走 cmd.exe /c；
  // 不用 shell:true —— 那样 Node 会打 DEP0190 警告（"arguments are not escaped"），脏了日志窗
  const child = spawn('cmd.exe', ['/c', cmd, 'mcp'], { cwd: process.cwd(), windowsHide: true });
  let buf = '';
  let id = 1;
  let lastLine = 0;
  let cycle = new Map();          // 本轮抓到的行：多条 grep 合并后按行号排序输出
  let flushTimer = null;
  const pending = new Map();
  const prefix = opts.color ? `${meta.color}[${name} ${meta.label}]${RESET}` : `[${name} ${meta.label}]`;

  function stamp() { return `${opts.color ? DIM : ''}${new Date().toTimeString().slice(0, 8)}${opts.color ? RESET : ''}`; }

  function flush() {
    flushTimer = null;
    const items = [...cycle.entries()].sort((a, b) => a[0] - b[0]);
    cycle = new Map();
    for (const [n, text] of items) {
      if (n <= lastLine) continue;
      if (n < lastLine) lastLine = 0;                 // 缓冲区被清空 / 行号回绕
      lastLine = Math.max(lastLine, n);
      console.log(`${prefix} ${stamp()} ${text}`);
    }
  }

  function send(method, params) {
    const msg = { jsonrpc: '2.0', id: id++, method, params };
    pending.set(msg.id, method);
    child.stdin.write(JSON.stringify(msg) + '\n');
    return msg.id;
  }

  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line || line[0] !== '{') continue;                 // 跳过 bridge 的状态行
      let msg;
      try { msg = JSON.parse(line); } catch (e) { continue; }
      if (!msg.id) continue;
      const was = pending.get(msg.id);
      pending.delete(msg.id);
      if (was !== 'tools/call') continue;
      const text = msg.result?.content?.[0]?.text ?? msg.result?.result ?? '';
      for (const raw of String(text).split('\n')) {
        const parsed = renderLine(raw);
        if (!parsed) continue;
        cycle.set(parsed.n, parsed.text);
      }
      if (!flushTimer) flushTimer = setTimeout(flush, 400);
    }
  });

  child.on('exit', (code) => console.log(`${prefix} 连接结束（exit ${code}）`));

  // 客户端名必须用 IDE 已授权过的那个（skill-cli 默认 client 名 = dsh）；换新名字会返回 "Client authorization pending"
  send('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'dsh', version: '1.0' } });
  setTimeout(() => {
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    setInterval(() => {
      for (const g of currentGreps()) {
        send('tools/call', { name: 'get_simulator_console', arguments: { project: opts.project, command: g } });
      }
    }, opts.interval);
  }, 2500);

  return child;
}

console.log(`console-watch: ${names.join(', ')} → ${opts.project}`);
console.log(`  过滤：${greps.join('  +  ')}（间隔 ${opts.interval}ms，Ctrl+C 退出）`);
const kids = names.map(startInstance);
process.on('SIGINT', () => { kids.forEach((k) => { try { k.kill(); } catch (e) {} }); process.exit(0); });
