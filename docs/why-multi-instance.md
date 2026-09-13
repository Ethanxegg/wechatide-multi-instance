# 调研：4 个角色并行测试的可行方案对比

> 调研日期：2026-09-13
> 环境：微信开发者工具 2.02.2608060（`D:\Tencent\wechatdev`）｜appid `wxf7d06335c114b122`｜云开发环境 `jyhh-2ghn93anbf17478f`（ap-shanghai）｜工程 `apps/wechat`
> 目标：让 导生 / 家长A / 家长B / 导员 4 个身份**可同时（或可重复、可自动化）**地在真工具链上跑通链路

## 一、结论速览

| 方案 | 4 角色并行 | 可自动化 | 人工扫码 | 改代码 | 内存开销 | 判定 |
|---|---|---|---|---|---|---|
| **A** 官方多账号自动化（`testAccounts` + `--auto-account`） | ❌ | — | 0 | 无 | 低 | **实测无效，废弃** |
| **B** 多实例 × 4 个真实微信号登录 | ✅ | ✅ 每实例一个端口 | 4 次 | 无 | ~17 GB | **已验证可行**（2 实例 × 2 微信号实测通过） |
| **C** 云函数受控调试身份覆盖 | ✅（单窗口切角色） | ✅ 可进 CI | 0 | 需改（约 40 个函数待收口） | 低 | **推荐做日常回归** |
| **D** 手动多账号调试（现状） | ✅ | ❌ | 0（账号已在） | 无 | 低 | 只做人工抽查，无法回归 |

**建议**：日常功能回归走 **C**；需要验收"真账号隔离/云开发身份"本身时走 **B**；**D** 保留为人工抽查。

## 二、平台事实与证据

### 2.1 自动化服务的粒度是「工程」，不是「窗口」

automator 与 IDE 自带 MCP 工具集都按**工程路径**寻址唯一后端窗口：

```js
// js/ebfd3866…（IDE 自带 MCP 自动化工具集）
async function g(project, method, params) {
  const u = await IBackendProcessManagerService.getBackendWinIdByProjectPath(project);
  return await ITransferActionService.callClientService(u, IAutomatorBridgeService, 'request', [msg, timeout]);
}
```

同一工程的多个窗口共用同一个 `backendWinId`（`_backendProjectInfoMap` 以 `projectpath` 为键），单个 `node.mojom.NodeService` 承载全部窗口 → **一个工程只能有一个自动化端口**。实测：同一工程开第二个端口时旧端口掉线，且新端口读到的仍是第一个窗口的身份。

### 2.2 IDE 没有任何「连接/切换到第二个窗口」的接口

`Tool.*` 路由全表（`js/87c5c70c…`）里账号相关只有 `getTestAccounts` / `getTicket` / `setTicket` / `refreshTicket`，**没有打开或挂接某账号窗口的动作**；IDE 自带 MCP 的 `automation_testaccount` 工具同样是这 4 个 action。

### 2.3 `--auto-account` 在本版本不改云开发身份（实测）

`cli auto --project P --auto-account <openid>`（= SDK `automator.launch({ account })`）执行成功、窗口确实新开，但 `wx.cloud.callFunction('whoami')` 返回的仍是主账号：

| 次数 | 命令 | 结果 |
|---|---|---|
| 1 | `cli auto --auto-port 9450 --auto-account o6zAJs0C…` | 新窗口 `pages/entry/index`，openid `oTQpg3dr…`（主账号） |
| 2 | 先 `close --project` ×3，再 `cli auto`（随机端口 42484） | 同上，identity 与 `unionid` 均未变 |

### 2.4 为什么：CLI 侧的账号登录是 mock，真账号只在 IDE 内部 UI 路径

| 事实 | 证据 |
|---|---|
| `getTestUserInfo(ticket)` 是**硬编码桩**，无论传什么 ticket 都返回固定用户 `Can🌴` / `o6zAJswvMl4_S2x88N5vmH5NwMEk` | `js/3d0aed52…`、`js/fa74583b…` |
| CLI 的 v2 入口只把 `--ticket`/`--testTicket` 映射为 `AutoTicket`/`TestTicket` 两种 **mock 登录** | `js/1c52e22e…` `execV2WSAPI` |
| 登录类型枚举：`Normal=0, TestUser=1, TestTicket=2, AutoTicket=3`；真账号是 `TestUser`（带账号 `newticket` + `testuser` 参数） | `js/2e41a406…` |
| `agentStart` 会**复用已存在的工程窗口并忽略传入的 `account`**，只有工程无窗口时才新开并带上账号 | `js/3f4b5a72…` `exports.agentStart` |
| `accountMap`（自己扫码加的账号）只设 `userInfo`；只有内置 `multiAccountUserMap` 才设 `testUserInfo` | `js/3f4b5a72…` `S(o)` |
| 多账号调试窗口是主窗口 UI 以 **`simple: true` 简易窗口**打开的（`W.simple=1` + `W.testuserinfo`），`cli auto` 开的是普通 `autoTest` 窗口 | `js/fd771d7f…`、`js/963d91fd…` `genProjectUrlInfo` |
| 内置虚拟号（测试号🐷 等）票据 `ticketExpiredTime=1564739254536`（2019-08-02）早已 EXPIRED | profile `ls_901fe236…json` 的 `testUserOpenIds` |

**一句话**：多账号调试**手动点**能用，是因为主窗口 UI 走了 `simple` 窗口 + `userInfo` 的内部路径；CLI / automator 复现不了这条路径，所以"连第二个窗口"在平台层面不存在。

### 2.5 实测：多账号窗口没有独立端口，且与主窗口同生共死

| 步骤 | 观察 |
|---|---|
| 手动开 主窗口 + 多账号调试窗口 | 全机仍只有 **1 个** `node.mojom.NodeService`（后端仍是一份）；除已知的无关端口外，没有新的自动化端口 |
| `cli agent start --project <工程> --auto-port 9441` | `openedProjectWindow: false`（复用已有窗口），该端口读到的是**主窗口**（`pages/guide/dashboard`，主账号 `oTQpg3dr…`） |
| 手动关闭主窗口 | **多账号窗口随之关闭** |

⇒ 多账号窗口既不能自己起自动化端口（其 URL 里没有 `autoPort`），也不能通过"关掉主窗口、只剩它"的方式被 `agentStart` 选中（同生共死）→ **平台层不可自动化，结论闭合**。

## 三、方案 A：官方多账号自动化（已废弃）

- 设计意图：官方[自动化 FAQ](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/faq.html)「一台机器多账号 = 多账号调试 + `miniProgram.testAccounts`」，[MiniProgram API](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/miniprogram.html) 给了 `automator.launch({ projectPath, account })` 示例。
- 实测：`testAccounts()` 可用（返回 4 个账号），但 `launch({ account })` 身份不变（见 2.3、2.4）。
- 结论：**不作为方案**。保留脚本仅用于读取账号列表。

## 四、方案 B：多实例 × 4 个真实微信号

**做法**（配方见 `learned-rules.md` R35）：
1. 复制 4 份安装目录 + 各自独立 `--user-data-dir` / `--ide-http-port` / `--remote-port`；
2. 每个实例**用不同微信号扫码登录**（不是多账号调试的测试号）；
3. `cli agent start --project <工程> --auto-port 942N` 挂端口，`automator.connect({ wsEndpoint: 'ws://127.0.0.1:942N' })` 连接。

**关键约束**
- 每个实例的**主登录必须是不同微信号**；同一账号登在两个工具客户端会导致登录态失效（官方文档明确警告），我们实测的 `invalid credential` 即此；
- 多账号调试的测试号**不能跨实例复用**（同上原因）；
- 内存：4 实例 ≈ 17.2 GB 工作集（每实例 3.2–4.3 GB），动之前先腾内存。

**实测结论（2026-09-13，2 实例 × 2 微信号）**

| 实例 | IDE HTTP / 自动化端口 | 登录微信号 | 云身份（appid openid） | 库里角色 |
|---|---|---|---|---|
| p3 | 43596 / 9422 | 电💓我 | `oTQpg3drZOo480s_4W1ESjzKGn_0` | guide（导生，P0） |
| p4 | 43597 / 9423 | 夏毯毯 | `oTQpg3dffi_9ml6BUiHFrM7ZHL-Y` | parent（Aaronnnnn） |

- 每个实例有**独立后端**（各自一个 `node.mojom.NodeService`）和独立自动化端口，可同时驱动不同身份 ⇒ **方案成立**。
- 唯一真障碍是**同 appid 的 `access_token` 互相顶掉**，报 `webapi_getwxaasyncsecinfo:fail invalid credential, access_token is invalid or not latest`（`err_code 40001`）；在出问题的那台实例执行一次
  `cli cache --clean session --project <工程> --port <IDE端口>` 即可，清完两台同时正常（连续 3 轮稳定）。
- 注意 `dbQuery` 云函数是**自身范围**：只能读调用者自己那行，跨账号查库返回空。

**已固化为 DSH skill**：`wechatide-multi-instance`（用户级 `~/.dsh/skills/`，仓库内一份 `<repo>/.agents/skills/`），提供
`devtools.ps1 start|verify|fix|arrange|status|stop` 与 `verify-identities.js`（把"多实例同一 openid"判为失败）。

**适用**：验收账号隔离、云开发真身份、消息通知真链路。
**不适用**：日常回归（4 次扫码 + 内存成本）。

## 五、方案 C：云函数受控调试身份覆盖（推荐）

**思路**：不动工具链，在**我们自己的云函数**里加一个受控的"以某测试用户身份执行"能力，单窗口即可演 4 个角色。

**现状成本**：`cloud.getWXContext()` 在约 40 个云函数里出现 **159 处**，**没有统一身份封装** → 全量收口是一次重构；建议按需收口。

**两种落地形态**
- **C1 收口式（干净但工作量大）**：新增 `cloudfunctions/_shared/identity.js`，导出 `resolveOpenId(cloud, event)`；按"是否有 `process.env.ALLOW_DEBUG_IDENTITY === '1'` + 目标是否 `openid.startsWith('test_')` + 短时效 token"判定；逐步替换 159 处调用点。
- **C2 按链路式（推荐先做）**：只覆盖多角色联动所需链路——`login`、`contractManage`、`serviceManage`、`interviewManage`、`notificationsManage`；沿用仓库既有调试入口体例（`interviewManage/index.js:1127 handleDebugInterview`）。

**安全边界（必须同时满足）**
1. 仅当函数环境变量显式打开调试开关才生效（线上默认关）；
2. 仅允许切到 `openid` 以 `test_` 开头的测试用户（现库里有 18 个，如 `测试A未签约`、`测试B1`）；
3. 覆盖动作写审计日志（谁、切到谁、何时）；
4. token 短时效、单次使用。

**收益**：0 扫码、0 额外内存、可写进自动化测试与 CI。

## 六、方案 D：手动多账号调试（现状）

- 主窗口（电💓我）先开 → 工具菜单「多账号调试」→ 勾选账号 → 新开 `simple` 窗口。
- 优点：0 成本、账号已在（4 个：Mr.know-A-Bit / 意味深长的省略号 / 夏毯毯 / 水星来信，票据有效期至 2026-09-13 ~ 2026-10-11）。
- 缺点：无法自动化、无法回归、跨设备不可复现；`close` 掉主窗口会连带关掉多账号窗口。

## 七、决策建议

```
需要"真账号/真工具链"验收？ ── 是 ──> B（多实例 × 真实微信号）
        │
        否
        ↓
需要反复回归 / 进 CI？ ── 是 ──> C（先做 C2 按链路覆盖）
        │
        否
        ↓
D（人工抽查）
```

## 八、附录

### 8.1 复现命令（脚本在 `.local-scratch/`，未入库）
```bash
node .local-scratch/probe-testaccounts.js 9431        # 只读：列出多账号调试账号 + 当前云身份
node .local-scratch/cli-auto-probe.js <openid> 9450  # 以某账号启动并读身份（需命令行调 CLI）
node .local-scratch/reset-and-switch.js <openid>     # 先 close 再 auto，验证身份是否切换
node .local-scratch/asar-grep.js "D:\Tencent\wechatdev\resources\app.asar" <关键字>  # asar 内容检索
```

### 8.2 参考文档
- [多账号调试](https://developers.weixin.qq.com/miniprogram/dev/devtools/multiaccount.html)（主账号登录态被所有窗口共享；同一测试账号登录其他工具客户端会失效）
- [自动化 FAQ](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/faq.html)（一台机器多账号 / 多机器同账号 `getTicket`）
- [MiniProgram API](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/miniprogram.html)（`testAccounts`/`getTicket`/`setTicket`）
- [虚拟账号测试](https://developers.weixin.qq.com/miniprogram/dev/devtools/minitest/virtual_test.html)（云测的测试号 v1–v20，与本机工具多账号不是同一套）

### 8.3 账号数据位置
- 多账号表：`%LOCALAPPDATA%\微信开发者工具\User Data\<profileHash>\WeappLocalData\ls_901fe2362b838016d7eda417458008c2.json`（每账号含 `newticket` / `signature` / `loginStatus` / `ticketExpiredTime`）
- 主登录：同目录 `localstorage_bb1f1c31590074019fb12d13fe40f221.json`

## 九、未验证 / 不确定

1. `agent start` 在"工程确实没有任何窗口"时新开窗口是否会带上账号身份（代码 `f()` 路径上带，但本机实验无法保证该前置条件，未下结论）。
2. ~~`simple` 简易窗口是否可被自动化~~ —— 已由 2.5 结论闭合：无独立端口 + 与主窗口同生共死 ⇒ 不可自动化。
3. 方案 C 的 159 处调用点里，哪些必须收口才能覆盖 4 角色链路 —— 需要一次代码盘点（未做）。
