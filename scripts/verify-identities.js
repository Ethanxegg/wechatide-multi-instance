/* 校验多个微信开发者工具实例的自动化端口：当前页面、云身份、库内用户与角色
 *
 * 关键作用：多实例最常见的失败是**所有实例其实是同一个账号**
 *（实例 profile 从主实例整份拷贝，没手动退登录），这里会把重复 openid 直接判为失败。
 *
 * 用法：node verify-identities.js [--project <工程绝对路径>] <autoPort> [autoPort...]
 *   --project 用于解析 miniprogram-automator（从该工程的 node_modules 向上找）；
 *   工程里没装可先 `npm i -D miniprogram-automator`。
 * 退出码：0 全部正常且身份互不相同；1 有端口不通 / 身份重复 / 云会话失效
 */
const path = require('path');

function loadAutomator(projectPath) {
  const roots = [projectPath, process.cwd()].filter(Boolean);
  try {
    return require(require.resolve('miniprogram-automator', { paths: roots }));
  } catch (e) {
    console.error('找不到 miniprogram-automator。请在工程（或本目录）执行：npm i -D miniprogram-automator');
    console.error('（--project 指向工程根目录时，脚本会从该目录向上查找 node_modules）');
    throw e;
  }
}

/** 在窗口内按 openid 查自己的用户文档（dbQuery 只能读调用者自己那行；工程没有该函数时会返回 null） */
const LOOKUP_SELF = function (openid) {
  return wx.cloud.callFunction({
    name: 'dbQuery',
    data: { collection: 'users', where: { openid: openid }, limit: 1 },
  }).then(function (r) {
    const res = r.result || {};
    const u = (res.data || res.list || [])[0];
    return u ? { name: u.name, role: u.role, status: u.status || u.isActive } : null;
  }).catch(function () { return null; });
};

/** 通用身份回显：任何工程都可用（dbQuery 是业务函数，可能不存在） */
const WHOAMI = function () {
  return wx.cloud.callFunction({ name: 'whoami' })
    .then(function (r) { return r.result || {}; })
    .catch(function (e) { return { err: String(e.errMsg || e.message || e) }; });
};

const CRED_HINT = '云会话失效 → 在该实例执行 devtools.ps1 fix <实例名>（即 cli cache --clean session）';

function pad(s, n) {
  const str = String(s == null ? '-' : s);
  let len = 0;
  for (const ch of str) len += ch.charCodeAt(0) > 0x7f ? 2 : 1;
  return str + ' '.repeat(Math.max(0, n - len));
}

async function inspect(automator, port) {
  let mp;
  try {
    mp = await automator.connect({ wsEndpoint: `ws://127.0.0.1:${port}` });
  } catch (e) {
    return { port, error: '端口不通（工程窗口没开或没挂自动化端口）' };
  }
  try {
    const page = await mp.currentPage().catch(() => null);
    const who = await mp.evaluate(WHOAMI);
    if (who.err) {
      const invalid = /invalid credential|access_token/.test(who.err);
      return { port, page: page && page.path, error: invalid ? `云会话失效：${CRED_HINT}` : who.err };
    }
    const user = await mp.evaluate(LOOKUP_SELF, who.openid).catch(() => null);
    return { port, page: page && page.path, openid: who.openid, appid: who.appid, user };
  } finally {
    try { mp.disconnect(); } catch (_) { /* ignore */ }
  }
}

(async () => {
  const argv = process.argv.slice(2);
  let project = '';
  const ports = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--project') { project = argv[++i] || ''; continue; }
    if (/^\d+$/.test(argv[i])) ports.push(Number(argv[i]));
  }
  if (!ports.length) {
    console.error('用法：node verify-identities.js [--project <工程绝对路径>] <autoPort> [autoPort...]');
    process.exit(1);
  }

  const automator = loadAutomator(project ? path.resolve(project) : '');
  const rows = [];
  for (const port of ports) rows.push(await inspect(automator, port));

  console.log(pad('端口', 8) + pad('页面', 34) + pad('云身份 openid', 30) + pad('库内用户/角色', 26) + '判定');
  for (const r of rows) {
    const user = r.user ? `${r.user.name}(${r.user.role})` : (r.openid ? '库里无此用户' : '-');
    console.log(pad(r.port, 8) + pad(r.page, 34) + pad(r.openid, 30) + pad(user, 26) + (r.error ? '✗ ' + r.error : '✓'));
  }

  const ids = rows.filter((r) => r.openid).map((r) => r.openid);
  const dup = [...new Set(ids.filter((v, i) => ids.indexOf(v) !== i))];
  const failed = rows.filter((r) => r.error);
  if (dup.length) {
    console.log(`\n⚠️ 身份重复：${dup.join(', ')}`);
    console.log('   说明有实例没换登录账号 —— 在该实例窗口右上角头像「退出登录」后用另一个微信号扫码；');
    console.log('   若确认已扫码仍重复，检查每个实例的 --user-data-dir 是否独立。');
  }
  if (ids.length > 1 && !dup.length) console.log(`\n✓ ${ids.length} 个实例身份互不相同，可并行调试`);
  process.exit(failed.length || dup.length ? 1 : 0);
})().catch((e) => {
  console.error('校验失败：', e && (e.message || e));
  process.exit(1);
});
