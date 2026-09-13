<#
  微信开发者工具「多实例多账号」调试工具（Windows）

  为什么需要它：自动化服务是**每后端一份**，后端按**工程路径**划分——
  同一工程的多个窗口（含「多账号调试」开的简易窗口）共用一个后端、只能有一个自动化端口，
  且关掉主窗口会连带关掉简易窗口。所以"多个可独立驱动的身份"只能靠多个 IDE 实例。

  为什么每实例要独立 profile/端口：CLI 拉起 IDE 时不传 --user-data-dir，
  多实例会共用默认 Chromium profile 而被单实例锁挡住；必须手动启动 exe 并显式给
  --user-data-dir / --ide-http-port / --remote-port。

  用法：
    pwsh devtools.ps1 start   p3,p4 -Project <工程绝对路径>  # 起实例 + 开工程 + 挂端口 + 校验（末尾自动复原上次布局）
    pwsh devtools.ps1 verify  p3,p4 -Project <工程绝对路径>  # 只校验：端口、当前身份、库内角色
    pwsh devtools.ps1 fix     p3    -Project <工程绝对路径>  # invalid credential 时刷新该实例云会话
    pwsh devtools.ps1 lite    p3,p4 -Project <工程绝对路径>  # 把工程窗口切成 lite（只有模拟器的窄窗）
    pwsh devtools.ps1 save-layout    p3,p4                   # 记住这些窗口的位置+大小（含独立日志窗）
    pwsh devtools.ps1 restore-layout p3,p4                   # 复原上次记住的窗口布局
    pwsh devtools.ps1 arrange p3,p4                          # 窗口宫格摆开（会先最大化再改尺寸，习惯手调就别跑）
    pwsh devtools.ps1 status  p3,p4                          # 只列端口监听情况
    pwsh devtools.ps1 stop    p3,p4                          # 关闭这些实例（-DryRun 只打印）

  可选参数：
    -InstallRoot <路径>   开发者工具主安装目录（默认 D:\Tencent\wechatdev）
    -ChromiumRoot <路径>  各实例独立 Chromium 目录的父目录（默认 D:\ide-chromium）
    -Config <json 路径>   自定义实例表，见 README「实例表配置」
    -LayoutFile <json>    窗口布局文件（默认 <skill 根>\window-layout.json）
    -LogTitle <标题>       独立日志窗标题（默认「调试输出 · 四台」，见 scripts\console-watch.js）

  窗口形态：full 模式（默认）最小宽度被工具锁在 980；要「只有模拟器」的窄窗（280 / 设备宽+30）
  只能用 `lite` 动作——它走 MCP 工具 `open_project_window --window-mode liteMode`，因为 CLI 的
  `cli open` 在源码里写死了 "fullMode"（传 --window-mode 无效，实测）。

  首次使用：实例起来后必须**手动**在每个窗口退出登录并用不同微信号扫码
  （profile 是从主实例整份拷来的，不退登录就四个实例同一个账号）。
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'verify', 'fix', 'arrange', 'status', 'lite', 'save-layout', 'restore-layout')]
  [string]$Action = 'verify',

  [Parameter(Position = 1)]
  [string[]]$Names = @('p2', 'p3', 'p4', 'p5'),

  [string]$Project,
  [string]$InstallRoot = 'D:\Tencent\wechatdev',
  [string]$ChromiumRoot = 'D:\ide-chromium',
  [string]$Config,
  [string]$LayoutFile,
  [string]$LogTitle = '调试输出 · 四台',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# 默认实例表：ide=IDE HTTP 端口 / remote=CLI 回调端口 / chrome=独立 Chromium 目录 / auto=自动化端口
# remote 避开主实例常用的 3799
$Instances = [ordered]@{
  p2 = @{ ide = 43595; remote = 3803; chrome = (Join-Path $ChromiumRoot 'p2'); auto = 9421 }
  p3 = @{ ide = 43596; remote = 3800; chrome = (Join-Path $ChromiumRoot 'p3'); auto = 9422 }
  p4 = @{ ide = 43597; remote = 3801; chrome = (Join-Path $ChromiumRoot 'p4'); auto = 9423 }
  p5 = @{ ide = 43598; remote = 3802; chrome = (Join-Path $ChromiumRoot 'p5'); auto = 9424 }
}

if ($Config) {
  if (-not (Test-Path $Config)) { throw "找不到配置文件：$Config" }
  $cfg = Get-Content $Config -Raw | ConvertFrom-Json
  if ($cfg.installRoot) { $InstallRoot = $cfg.installRoot }
  if ($cfg.chromiumRoot) { $ChromiumRoot = $cfg.chromiumRoot }
  if ($cfg.instances) {
    $built = [ordered]@{}
    foreach ($prop in $cfg.instances.PSObject.Properties) {
      $n = $prop.Name; $v = $prop.Value
      $built[$n] = @{
        ide    = [int]$v.ide
        remote = [int]$v.remote
        chrome = if ($v.chrome) { $v.chrome } else { Join-Path $ChromiumRoot $n }
        auto   = [int]$v.auto
      }
    }
    $Instances = $built
  }
}

function Resolve-Project([string]$p) {
  if ($p) { return (Resolve-Path $p).Path }
  $dir = (Get-Location).Path
  while ($dir) {
    if (Test-Path (Join-Path $dir 'project.config.json')) { return $dir }
    $parent = Split-Path $dir -Parent
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw '找不到工程目录（向上没有 project.config.json）——请用 -Project <工程绝对路径> 指定'
}

# 只有这几个动作需要工程；布局/状态/停止/摆窗不需要，缺 -Project 时不报错
$NeedsProject = @('start', 'verify', 'fix', 'lite') -contains $Action
try { $Project = Resolve-Project $Project }
catch { if ($NeedsProject) { throw } else { $Project = '' } }
$VerifyScript = Join-Path $PSScriptRoot 'verify-identities.js'

$Names = @($Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Selected = @($Names | Where-Object { $Instances.Contains($_) })
if (-not $Selected) { throw "没有可用实例名，可选：$($Instances.Keys -join ', ')" }

function Get-Install([string]$n) { "$InstallRoot-$n" }
function Get-Cli([string]$n) { Join-Path (Get-Install $n) 'cli.bat' }
function Test-Port([int]$p) { [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) }

function Get-MainProfile {
  $udRoot = Join-Path $env:LOCALAPPDATA '微信开发者工具\User Data'
  $p = Get-ChildItem $udRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'Default\.ide-status') } |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $p) { throw '找不到现役 CLI profile（含 Default\.ide-status）——先正常启动一次开发者工具并登录' }
  return $p
}

function Get-CliProfile([string]$n) {
  $out = & (Get-Cli $n) --debug __noop 2>&1 | Out-String
  $m = [regex]::Match($out, 'userDirPath\s+(.+?)\s*(\r?\n|$)')
  if (-not $m.Success) { throw "取不到 $n 的 userDirPath" }
  return Split-Path $m.Groups[1].Value.Trim() -Parent
}

function Ensure-Instance([string]$n) {
  $s = $Instances[$n]
  $copy = Get-Install $n
  if (-not (Test-Path $copy)) {
    Write-Host "[$n] 复制安装目录（首次，约 1.2 GB）…"
    robocopy $InstallRoot $copy /E /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
  }
  $prof = Get-CliProfile $n
  if (-not (Test-Path "$prof\Default\.ide-status")) {
    Write-Host "[$n] 建独立 CLI profile（继承登录态与 CLI 开关）…"
    New-Item -ItemType Directory -Force -Path $prof | Out-Null
    robocopy (Get-MainProfile) $prof /E /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
  }
  Set-Content "$prof\Default\.ide" -Value $s.ide -Encoding ascii -NoNewline
  Remove-Item "$prof\Default\.cli" -Force -ErrorAction SilentlyContinue

  if (-not (Test-Port $s.ide)) {
    Write-Host "[$n] 启动实例（IDE $($s.ide) / 自动化 $($s.auto) / chromium $($s.chrome)）…"
    Start-Process -FilePath (Join-Path $copy '微信开发者工具.exe') `
      -ArgumentList '--cli', '--remote-port', "$($s.remote)", '--ide-http-port', "$($s.ide)", "--user-data-dir=$($s.chrome)" `
      -WindowStyle Minimized
    for ($i = 0; $i -lt 30 -and -not (Test-Port $s.ide); $i++) { Start-Sleep -Seconds 1 }
  }
  if (-not (Test-Port $s.ide)) { throw "[$n] IDE HTTP $($s.ide) 未监听，启动失败" }
}

function Open-Project([string]$n) {
  & (Get-Cli $n) open --project $Project --port $Instances[$n].ide *> $null
  Start-Sleep -Seconds 6
}

function Attach-Automation([string]$n) {
  $s = $Instances[$n]
  if (Test-Port $s.auto) { Write-Host "[$n] 自动化端口 $($s.auto) 已在监听"; return }
  $out = & (Get-Cli $n) agent start --project $Project --auto-port $s.auto --trust-project --port $s.ide 2>&1 | Out-String
  if ($out -match 'automator server already started on port (\d+)') {
    Write-Host "[$n] 该实例已有自动化端口 $($Matches[1])（同一工程只能一个）"
  } elseif ($out -match '"status":\s*"ok"') {
    Write-Host "[$n] 已挂自动化端口 $($s.auto)"
  } else {
    Write-Host "[$n] 挂端口返回异常：$($out.Trim().Split("`n")[-1])"
  }
}

function Stop-Instance([string]$n) {
  $copy = Get-Install $n
  # 用 Get-Process 的 .Path 前缀匹配；中文进程名过滤在子 pwsh 里会返回空
  $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($copy, 'OrdinalIgnoreCase') })
  if (-not $procs) { Write-Host "[$n] 没有在跑的进程"; return }
  foreach ($p in $procs) {
    if ($DryRun) { Write-Host "[$n] -DryRun 将结束 PID $($p.Id)" }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
  if (-not $DryRun) { Write-Host "[$n] 已结束 $($procs.Count) 个进程" }
}

function Arrange-Windows {
  if (-not ('Win32Api' -as [type])) {
    Add-Type -Namespace W -Name Win32Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
  }
  Add-Type -AssemblyName System.Windows.Forms
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $cols = if ($Selected.Count -le 1) { 1 } else { 2 }
  $rows = [Math]::Ceiling($Selected.Count / $cols)
  $w = [int]($area.Width / $cols)
  $h = [int]($area.Height / $rows)
  $i = 0
  foreach ($n in $Selected) {
    $exe = Get-Install $n
    $proc = Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.StartsWith($exe, 'OrdinalIgnoreCase') -and $_.MainWindowHandle -ne 0 } |
      Select-Object -First 1
    if (-not $proc) { Write-Host "[$n] 没有可见窗口（先 start/open 工程，或等窗口就绪后重跑）"; $i++; continue }
    $x = $area.X + ($i % $cols) * $w
    $y = $area.Y + [Math]::Floor($i / $cols) * $h
    [W.Win32Api]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null
    Start-Sleep -Milliseconds 300
    [W.Win32Api]::MoveWindow($proc.MainWindowHandle, $x, $y, $w, $h, $true) | Out-Null
    Write-Host "[$n] 窗口 → ($x,$y) ${w}x${h}"
    $i++
  }
}

function Invoke-Verify {
  $ports = @($Selected | ForEach-Object { $Instances[$_].auto })
  & node $VerifyScript --project $Project @ports
  if ($LASTEXITCODE -ne 0) { Write-Host '校验脚本返回非 0（可能有实例身份重复或端口不通）' }
}

# ---- 窗口布局：记住/复原位置+大小（工具自己只记尺寸，不记位置）----
$LayoutScript = Join-Path $PSScriptRoot 'window-layout.ps1'
if (-not $LayoutFile) { $LayoutFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'window-layout.json' }

function Invoke-Layout([string]$mode) {
  if (-not (Test-Path $LayoutScript)) { Write-Host "  （缺 $LayoutScript，跳过）"; return }
  & $LayoutScript -Action $mode -File $LayoutFile -Instances ($Selected -join ',') -LogTitle $LogTitle -InstallRoot $InstallRoot
}

# ---- lite 窗口：只有模拟器的窄窗（full 模式最小宽 980 被工具锁死，lite 是 280 / 设备宽+30）----
function Switch-ToLite([string]$n) {
  $s = $Instances[$n]
  $w = Join-Path (Get-Install $n) 'wechatide.cmd'
  if (-not (Test-Path $w)) { Write-Host "[$n] 该副本没有 wechatide.cmd（版本过老？），跳过"; return }
  Write-Host "[$n] 切 lite 窗口…"
  # 已存在的窗口不换模式：必须先关再开
  & $w -c dsh close_project_window --project $Project *> $null
  for ($i = 1; $i -le 12; $i++) {
    Start-Sleep -Seconds 2
    $open = @(Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.StartsWith((Get-Install $n), 'OrdinalIgnoreCase') -and $_.MainWindowTitle -eq (Split-Path $Project -Leaf) })
    if (-not $open) { break }
  }
  $out = & $w -c dsh open_project_window --project $Project --window-mode liteMode 2>&1 | Out-String
  if ($out -notmatch '"success":\s*true') {
    Write-Host "[$n] open_project_window 异常：$((($out.Trim() -split "`n") | Select-Object -Last 1).Trim())"
    return
  }
  Start-Sleep -Seconds 12
  Attach-Automation $n
}

switch ($Action) {
  'start' {
    foreach ($n in $Selected) { Ensure-Instance $n; Open-Project $n; Attach-Automation $n }
    Write-Host ''
    Invoke-Verify
    if (Test-Path $LayoutFile) {
      Write-Host ''
      Write-Host "复原上次记住的窗口布局（$LayoutFile）…"
      Invoke-Layout 'restore'
    }
    Write-Host "`n下一步：若上面出现「身份重复」，在每个实例窗口右上角头像 → 退出登录 → 用不同微信号扫码，再跑 verify。"
  }
  'verify' { Invoke-Verify }
  'status' {
    foreach ($n in $Selected) {
      $s = $Instances[$n]
      $ide = if (Test-Port $s.ide) { '✓' } else { '✗' }
      $auto = if (Test-Port $s.auto) { '✓' } else { '✗' }
      "[{0}] IDE {1}={2}  自动化 {3}={4}" -f $n, $s.ide, $ide, $s.auto, $auto
    }
  }
  'fix' {
    foreach ($n in $Selected) {
      $s = $Instances[$n]
      Write-Host "[$n] 刷新云会话（cache --clean session）…"
      & (Get-Cli $n) cache --clean session --project $Project --port $s.ide 2>&1 | Select-Object -Last 1
      Start-Sleep -Seconds 5
    }
    Write-Host ''
    Invoke-Verify
  }
  'lite' {
    if (-not $Project) { throw 'lite 需要 -Project <工程绝对路径>' }
    foreach ($n in $Selected) { Switch-ToLite $n }
    Write-Host ''
    Invoke-Verify
  }
  'save-layout' { Invoke-Layout 'save' }
  'restore-layout' { Invoke-Layout 'restore' }
  'arrange' { Arrange-Windows }
  'stop' { foreach ($n in $Selected) { Stop-Instance $n } }
}
