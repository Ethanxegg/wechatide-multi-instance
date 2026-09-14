# wechatide-multi-instance

在一台机器上同时驱动**多个微信开发者工具实例、每个实例登录不同微信号**，用于需要「多个角色同时在线」的联调与端到端测试（例如：导员录单 → 导生确认 → 家长付款）。

> 为什么不能用「多账号调试」+ 自动化：自动化服务是**每后端一份**，后端按**工程路径**划分。同一工程的多个窗口共用一个后端 → 只能有一个自动化端口，且永远绑在第一个窗口上；「多账号调试」开的简易窗口不自带端口，还会随主窗口一起关闭。CLI 的 `--auto-account` / `--ticket` 只是 mock，不改云开发身份。
> 完整证据与四方案对比见 [`docs/why-multi-instance.md`](docs/why-multi-instance.md)。

## 能做什么

- `devtools.ps1 start|stop|verify|fix|lite|full|save-layout|restore-layout|arrange|status`：一键起/停 N 个互相隔离的实例、挂自动化端口、校验每个实例当前是**哪个真实身份**（含库内用户与角色）、把工程窗口切成「只有模拟器」的窄窗（**start 默认就切 lite**）、记住/复原窗口布局、把窗口摆成宫格便于肉眼区分。
- `verify-identities.js`：逐个端口读 `whoami` + 页面路径 + 库内用户/角色；**把"多个实例其实是同一个账号"直接判为失败**、把云会话失效提示成一条修复命令。
- `patch-minicode-port.js`：修「第 3 个实例必被 Windows 按无响应杀掉」的工具 bug（内置 `minicode server` 只有 32123/33233 两个端口）；支持 `--check` / `--revert`。见 `SKILL.md` 专节。
- `console-watch.js`：**独立调试输出窗口**——把各实例模拟器的 console（默认 warn 及以上）实时打到单独窗口，行首带身份前缀，四台合并看。
- `window-layout.ps1`：记住 / 复原窗口位置与大小（工具自己只存尺寸、不存位置）。
- 取证 / 看图小工具：`list-windows.ps1`（列窗口）、`capture-window.ps1`（截整窗，`-Instance` 或 `-ProcessId`）、`patch-ide-layout.js`（改面板状态：显示/隐藏编辑器·调试器·模拟器）、`asar-grep.js` / `asar-extract.js` / `locale-find.js`（在 `app.asar` 里搜关键字 / 抠条目 / 按中文反查词条 key）。
- 附带一套踩坑速查（token 争用、模块缺失、构建超时、实例半死、窄窗 980 锁……），见 `SKILL.md`。

## 环境要求

- Windows（脚本用 `--user-data-dir` / `--ide-http-port` 等 Windows 版开发者工具参数）。
- 微信开发者工具已正常安装并登录过一次（脚本要读它的 CLI profile）。
- 目标工程有 `project.config.json`；工程里能解析到 `miniprogram-automator`（`npm i -D miniprogram-automator`）。
- 每个要登录的微信号对目标 appid 有**开发者 / 体验成员**权限。
- 内存：每实例约 3–4 GB；4 实例 + 4 窗口约 14–17 GB。

## 安装

**方式 A：用 skills CLI（推荐）**

```bash
# 先看看仓库里有哪些 skill（不安装）
npx skills add Ethanxegg/wechatide-multi-instance --list

# 装到指定 agent（用户级）；把 claude-code 换成你用的 agent id
npx skills add Ethanxegg/wechatide-multi-instance -g -a claude-code -y
# 装到所有已知 agent
npx skills add Ethanxegg/wechatide-multi-instance --all
```

> 实测：该 CLI 能正确识别本仓库（`Found 1 skill: wechatide-multi-instance`）。
> 不带 `-a` 时会交互式询问装到哪些 agent，非 TTY 环境会取消，务必带 `-a`（或 `--all`）。

**方式 B：手动放进 agent 的技能目录**

```powershell
# 用户级（DSH / Claude Code 都扫，推荐）
Copy-Item -Recurse . "$HOME\.dsh\skills\wechatide-multi-instance"
# 或项目级（随仓库走）
Copy-Item -Recurse . "<repo>\.agents\skills\wechatide-multi-instance"
```

**方式 C：直接 clone**，用 `scripts/devtools.ps1` 的绝对路径调用即可（不放进技能目录也能用）。

## 快速开始

```powershell
$S = "<本目录>\scripts\devtools.ps1"      # 或 $HOME\.dsh\skills\wechatide-multi-instance\scripts\devtools.ps1
$P = "<你的小程序工程绝对路径>"             # 含 project.config.json

# 【首次且要同时开 3 台以上】先给每个副本一组独立 minicode 端口（先停该实例再改）
node "<本目录>\scripts\patch-minicode-port.js" p3 32124 33234
node "<本目录>\scripts\patch-minicode-port.js" p4 32125 33235
node "<本目录>\scripts\patch-minicode-port.js" p5 32126 33236

pwsh $S start p2,p3,p4,p5 -Project $P      # 起 4 个实例 + 开工程 + 挂端口 + 切 lite（默认）+ 校验 + 复原布局
# 【人工】在每个窗口：右上角头像 → 退出登录 → 用不同微信号扫码
pwsh $S verify p2,p3,p4,p5 -Project $P     # 四个 openid 必须互不相同；同时打印库内角色
pwsh $S lite   p2,p3,p4,p5 -Project $P     # 已默认 lite；想在起完之后再切一次时用
pwsh $S full   p2,p3,p4,p5 -Project $P     # 需要编辑器/调试器面板时切回 full
pwsh $S save-layout p2,p3,p4,p5            # 记住窗口位置+大小（start 结束时会自动 restore）
pwsh $S arrange p2,p3,p4,p5                # 可选：2×2 摆窗（会先最大化再改尺寸；习惯手动调窗口就别跑）
pwsh $S stop   p2,p3,p4,p5                 # 收尾
```

> **窗口形态默认 lite**（2026-09-13 起）：`start` 会在挂完端口后自动把每个实例切成「只有模拟器」的窄窗（约 400px，可并排摆开），
> 这样起完就是可用的窄窗布局。要完整界面（编辑器 + 模拟器 + 调试器）用 `start ... -WindowMode full`，或随时 `full` 动作切回；
> 切模式都是「先关窗再开」（工具限制，见「实测结论」）。

独立调试输出窗口（四台合并、行首带身份前缀、默认 warn 及以上）：

```powershell
node "<本目录>\scripts\console-watch.js" --project $P --instances p2,p3,p4,p5
```

连接某个实例（任意测试脚本）：

```js
const automator = require('miniprogram-automator');
const mp = await automator.connect({ wsEndpoint: 'ws://127.0.0.1:9422' });   // 9421..9424 依实例而定
const who = await mp.evaluate(() => wx.cloud.callFunction({ name: 'whoami' }).then(r => r.result));
const page = await mp.currentPage();
mp.disconnect();
```

## 实例表配置

默认实例表（可用 `-InstallRoot` / `-ChromiumRoot` 改根目录）：

| 实例 | 安装副本 | IDE HTTP | CLI 回调 | Chromium 目录 | 自动化端口 |
|---|---|---|---|---|---|
| p2 | `<InstallRoot>-p2` | 43595 | 3803 | `<ChromiumRoot>\p2` | 9421 |
| p3 | `<InstallRoot>-p3` | 43596 | 3800 | `<ChromiumRoot>\p3` | 9422 |
| p4 | `<InstallRoot>-p4` | 43597 | 3801 | `<ChromiumRoot>\p4` | 9423 |
| p5 | `<InstallRoot>-p5` | 43598 | 3802 | `<ChromiumRoot>\p5` | 9424 |

要改端口或增删实例，传 `-Config instances.json`：

```json
{
  "installRoot": "D:\\Tencent\\wechatdev",
  "chromiumRoot": "D:\\ide-chromium",
  "instances": {
    "p2": { "ide": 43595, "remote": 3803, "auto": 9421 },
    "p6": { "ide": 43600, "remote": 3806, "auto": 9430, "chrome": "D:\\ide-chromium\\p6" }
  }
}
```

## 实测结论（帮你少走弯路）

- 同一 appid 的多实例会**争 `access_token`**（微信 token 全局唯一）：报 `invalid credential, access_token is invalid or not latest` 时，在出问题的那台执行 `devtools.ps1 fix <实例>` 即可（等价于 `cli cache --clean session`）。
- **该版本不打补丁最多同时开 2 台**：工具内置 `minicode server` 端口写死 32123、只回退 33233，两个都被占就无限重试 → 第 3 台的主进程被 Windows 判无响应杀掉（无窗口、进程只剩 4~6 个、日志停在 `enable cli service`）。换启动方式、重装 profile、重启都不解决，要 3 台以上用 `scripts/patch-minicode-port.js` 给每个副本一组独立端口。证据与复现见 [`docs/why-multi-instance.md`](docs/why-multi-instance.md) 2.6。
- 每实例的 CLI profile 是从主实例**整份拷贝**的 → 不手动换号，N 个实例都是同一个账号；`verify` 会把这个判为失败。
- `es6 + enhance` 增强编译会给对象展开注入 `@babel/runtime` helper：工程 `miniprogram/package.json` 里没有该依赖时，**只有新开的窗口**会报 `module '@babel/runtime/...' is not defined`、app 初始化失败。处置见 `SKILL.md` 专节。
- 别在多个实例同时跑开发者工具的「构建 npm」；实测会把它卡死。
- **窗口能多窄**：full 模式最小宽被工具锁在 980；`lite`（只有模拟器）是 280 / 「设备宽+30」。CLI 的 `open` 源码写死 `fullMode`，所以切 lite 只能走 MCP 工具（`devtools.ps1 lite` 已封装），且**必须先关窗再开**才会换模式。
- `start` 不会把**已开着**的窗口打回 full（CLI open 发现窗口在就直接返回）；但窗口原本关着时 `start` 会用 full 开，之后想窄窗要补一次 `lite`。
- **窗口位置工具不存**（只存尺寸 `position` / `liteCollapsed`），跨重启靠 `save-layout` / `restore-layout`。

## 兼容与验证

- 开发与实测环境：微信开发者工具 **2.02.2608060**（Windows）。
- 该版本已验证的坑：`minicode server` 双端口导致同时最多 2 台实例（补丁见 `scripts/patch-minicode-port.js`）。更高版本若修了这个回退逻辑，补丁脚本的 `--check` 会报"常量出现次数异常"并拒绝修改 —— 那就说明不用补了。
- 官方文档依据：[多账号调试](https://developers.weixin.qq.com/miniprogram/dev/devtools/multiaccount.html)、[自动化 FAQ](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/faq.html)。

## 许可

MIT，见 [LICENSE](LICENSE)。
