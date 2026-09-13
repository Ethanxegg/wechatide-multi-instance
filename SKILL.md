---
name: wechatide-multi-instance
description: >-
  微信开发者工具「多实例多账号」并行调试：在一台机器上起 N 个互相独立的开发者工具实例，
  每个实例登录不同微信号、各挂一个自动化端口，从而同时驱动导生 / 家长 / 导员等多个身份。
  也覆盖这一路的坑与处置：多账号调试窗口不可自动化、同一 appid 的 access_token 互相顶掉
  （invalid credential）、agent start 只绑第一个窗口、CLI 参数真名（cache --clean session）、
  以及小程序侧 `module '@babel/runtime/...' is not defined` / `Cloud API isn't enabled` 的鉴别与修复。
  当需要多个角色同时在线调试、多窗口并行自动化、开多个开发者工具实例，
  或同工程的第二个窗口连不上自动化端口、新实例编译报模块缺失时使用。
whenToUse: >-
  用户要"多角色/多账号同时在线测试"、"开多个开发者工具实例"、"多窗口调试图自动化"，
  或多账号调试开的窗口连不上自动化端口、报 invalid credential、
  新开的窗口报 module is not defined / Cloud API isn't enabled 时。
metadata:
  short-description: 开发者工具多实例多账号并行调试
  platform: Windows
---

# wechatide-multi-instance

在一台机器上同时驱动**多个微信开发者工具实例、每个实例登录不同微信号**，用于需要「多个角色同时在线」的联调与端到端测试。

## 先记住这四条（实测结论，别再试错）

1. **自动化服务是"每后端一份"，后端按工程路径划分。** 同一工程开多个窗口（含「多账号调试」的简易窗口）共用一个后端 → 只能有一个自动化端口，且永远绑在**第一个**窗口上。
2. **「多账号调试」窗口不可自动化**：它由主窗口 UI 以 `simple` 窗口打开，URL 里没有 `autoPort`（不自带端口）；且**关掉主窗口会连带关掉它**，所以也无法"只剩它"让自动化选中。
3. **CLI 的账号参数是 mock**：`--auto-account` 只会写 `userInfo`、不改云开发身份；`--ticket` / `--testTicket` 走的是硬编码桩用户（`Can🌴` / `o6zAJswvMl4_S2x88N5vmH5NwMEk`）。要多个真身份 → **多实例**。
4. **同一 appid 的多实例会争 `access_token`**：微信 token 全局唯一，后取的顶掉先取的 → 报
   `webapi_getwxaasyncsecinfo:fail invalid credential, access_token is invalid or not latest`。
   在出问题的那台实例上执行 `cache --clean session` 即可刷新。

> 结论：**要 N 个可独立驱动的身份，只能起 N 个 IDE 实例**，每实例独立安装副本 + 独立 `--user-data-dir` + 不同微信号登录。

## 安装

```bash
npx skills add <owner>/wechatide-multi-instance -g      # 或手动拷到 ~/.dsh/skills/、<repo>/.agents/skills/
```

前置：Windows；开发者工具已登录过一次（脚本要读它的 CLI profile）；工程有 `project.config.json` 且能解析 `miniprogram-automator`；每个要登录的微信号对目标 appid 有开发者/体验成员权限；内存每实例约 3–4 GB。

## 标准流程

```powershell
$S = "<本 skill 目录>\scripts\devtools.ps1"
$P = <工程绝对路径>

pwsh $S start   p2,p3,p4,p5 -Project $P -InstallRoot <开发者工具主安装目录>
# 【人工】每个窗口：头像 → 退出登录 → 用不同微信号扫码
pwsh $S verify  p2,p3,p4,p5 -Project $P     # 四个 openid 必须互不相同 + 打印库内角色
pwsh $S arrange p2,p3,p4,p5                 # 宫格摆窗，便于肉眼区分
pwsh $S fix     p3 -Project $P              # invalid credential 时刷新该实例云会话
pwsh $S stop    p2,p3,p4,p5                 # 收尾（-DryRun 只打印）
```

默认实例表（`-Config <json>` 可自定义，见 README）：

| 实例 | 安装副本 | IDE HTTP | CLI 回调 | Chromium 目录 | 自动化端口 |
|---|---|---|---|---|---|
| p2 | `<InstallRoot>-p2` | 43595 | 3803 | `<ChromiumRoot>\p2` | 9421 |
| p3 | `<InstallRoot>-p3` | 43596 | 3800 | `<ChromiumRoot>\p3` | 9422 |
| p4 | `<InstallRoot>-p4` | 43597 | 3801 | `<ChromiumRoot>\p4` | 9423 |
| p5 | `<InstallRoot>-p5` | 43598 | 3802 | `<ChromiumRoot>\p5` | 9424 |

单端口操作（任意测试脚本）：

```js
const automator = require('miniprogram-automator');
const mp = await automator.connect({ wsEndpoint: 'ws://127.0.0.1:9422' });
const who = await mp.evaluate(() => wx.cloud.callFunction({ name: 'whoami' }).then(r => r.result));
const page = await mp.currentPage();
mp.disconnect();
```

## 故障速查

| 现象 | 原因 | 处置 |
|---|---|---|
| `invalid credential, access_token is invalid or not latest`（err_code 40001） | 同 appid 多实例争 token | 该实例执行 `cli cache --clean session --project <工程> --port <IDE端口>`；或 `devtools.ps1 fix <实例>` |
| 第二个端口报 `automator server already started on port X (code 10)` | 一工程一后端一端口 | 别在同工程挂第二个；要并行 → 多实例 |
| `verify` 报所有实例同一 openid | profile 拷贝带过来的主登录 | 逐实例退出登录 + 换微信号扫码 |
| 实例进程在、但没有窗口 | `--cli` 启动只当服务 | `cli open --project <工程> --port <IDE端口>` 才出界面 |
| `Account <x> not exist` / 身份没变 | 用了 `--auto-account` | 该参数不改云身份；改用多实例 |
| `close --project` 后端口还监听着 | 该命令**异步**生效 | 别用"端口还在"判断它没执行，隔十几秒再看 |
| 关掉主窗口后多账号窗口也没了 | 简易窗口跟随主窗口 | 平台行为，不是 bug |
| `module '@babel/runtime/helpers/xxx.js' is not defined` | 增强编译给对象展开注入 helper，但 npm 依赖里没有 `@babel/runtime` | 见下方专节 |
| `Cloud API isn't enabled, please call wx.cloud.init first`、`getApp()` 为空 | app 初始化失败（通常就是上面的模块错误） | 先修模块错误，再**重启该实例** |
| `Component is not found` / `wx://not-found` | 编译缓存 + 工程文件列表快照陈旧 | `cache --clean compile` + `--clean file`，重开窗口；文件真缺才查代码 |
| `build-npm` 卡住（CLI 数分钟无返回）或 `Fetching AppID detailed information → TimeoutError` | 微信侧接口慢 + 多实例并发 | **只留一个实例**再试；仍失败走专节的手工兜底 |
| 窗口刚开时 `arrange` 报"没有可见窗口" | 窗口尚未就绪 | 等 10 秒再跑一次 |
| 实例"半死"（automator 超时 / app 不初始化） | 编译状态坏了 | 关掉该实例进程后 `devtools.ps1 start <实例>` 重启（登录态在 profile 里，不丢） |

CLI 参数真名（容易记错）：清缓存 `cli cache --clean <storage\|file\|compile\|auth\|network\|session\|all>`（**不是** `cleancache`）；`cli open-other` **不带参数**；全命令表 `cli --help`。

### 专节：`module '@babel/runtime/...' is not defined`

**一条命令鉴别**：`Test-Path <工程>\miniprogram\miniprogram_npm\@babel`
- **在** → 缓存陈旧：清 `compile` + `file` 缓存后重开窗口。
- **不在** → npm 依赖/产物问题，按下面走。

**根因**：`project.config.json` 开着 `es6: true` + `enhance: true` 时，编译器对对象展开（`{ ...a }`）注入 `require('@babel/runtime/helpers/...')`；而 `packNpmManually: true` 指定的 `miniprogram/package.json` 里没有 `@babel/runtime` → 产物里也没有。**老窗口靠编译缓存仍能跑，只有新开的窗口会炸**。

```powershell
# ① 补依赖
cd <工程>\miniprogram; npm i '@babel/runtime@^7' --save
# ② 只留一个实例，再让工具构建（微信侧慢，可能多次超时）
& <副本>\cli.bat build-npm --project <工程> --port <IDE端口>
# ③ 官方构建仍被超时卡死时的兜底：按工具自己的产物布局手工放入
Copy-Item <工程>\miniprogram\node_modules\@babel\runtime `
          <工程>\miniprogram\miniprogram_npm\@babel\runtime -Recurse
& <副本>\cli.bat cache --clean compile --project <工程> --port <IDE端口>
& <副本>\cli.bat cache --clean file    --project <工程> --port <IDE端口>
# ④ 重启该实例（app 才会重新初始化），再 verify
```

判据：`hasApp=true`、`route=pages/...`、`cloudOk=true`、`whoami` 正常返回。
⚠️ `miniprogram_npm` **不在文件监听范围**，改完不会自动重编译，必须清缓存 + 重开/重启实例。

## 不要浪费时间再试的事

- **连「多账号调试」的简易窗口**：没有端口、随主窗口关闭，平台层不支持。
- **`--auto-account` / `--ticket`**：前者只写 userInfo，后者是硬编码桩用户。
- **同工程挂第二个自动化端口**：`automator server already started`。
- **多实例并发时跑 `build-npm`**：会把 IDE 构建服务卡死。
- **指望改 `miniprogram_npm` 后自动重编译**：不在监听范围。
- **用"端口还在监听"判断 `close --project` 没执行**：它是异步的。

## 已知限制

- 仅 Windows（依赖 Windows 版开发者工具的 `--user-data-dir` / `--ide-http-port` / CLI 行为）。
- 每实例一套安装副本（约 1.2 GB）与一个 Chromium 目录；4 实例内存约 14–17 GB。
- 身份隔离依赖**每个微信号都有该 appid 的权限**；账号不足时无解（云函数侧受控身份是另一条路，见 `docs/why-multi-instance.md` 方案 C）。
- 实测版本：微信开发者工具 **2.02.2608060**；更高版本若改了 `agentStart` / 窗口寻址逻辑，需重新验证。

## 参考

- [`docs/why-multi-instance.md`](docs/why-multi-instance.md)：平台层证据 + 四方案对比（含"为什么官方多账号自动化不可用"）。
- [`README.md`](README.md)：安装、实例表配置、快速开始。
- 官方文档：[多账号调试](https://developers.weixin.qq.com/miniprogram/dev/devtools/multiaccount.html)、[自动化 FAQ](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/faq.html)。
