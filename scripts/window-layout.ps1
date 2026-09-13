<#
  记住 / 恢复各实例的窗口几何（位置 + 大小）
  用法：
    pwsh scripts\window-layout.ps1 -Action save     [-File <json>]
    pwsh scripts\window-layout.ps1 -Action restore  [-File <json>] [-Instances p2,p3,p4,p5]
    pwsh scripts\window-layout.ps1 -Action show
  说明：微信开发者工具自己只持久化**尺寸**（profile 的 WeappLocalData\localstorage_<hash>.json：
        position=full 模式尺寸 / liteCollapsed=lite 模式尺寸），**不记位置**；
        所以位置由本脚本记在 json 里，实例重启后跑一次 restore 即可复原。
        `devtools.ps1 start` 结束时若该 json 存在会自动 restore；也可单独跑
        `devtools.ps1 save-layout` / `restore-layout`。
        除工程窗口外，标题为 <LogTitle> 的独立日志窗（见 console-watch.js）也会一并记录。
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('save', 'restore', 'show')][string]$Action,
  [string]$File = '',
  [string]$Instances = 'p2,p3,p4,p5',
  [string]$LogTitle = '调试输出 · 四台',
  [string]$InstallRoot = 'D:\Tencent\wechatdev'
)

# 默认放在 skill 根目录，和 devtools.ps1 的 -LayoutFile 默认值一致
if (-not $File) { $File = Join-Path (Split-Path $PSScriptRoot -Parent) 'window-layout.json' }

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public class Lay {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public class Win { public IntPtr H; public string Title; public int X, Y, W, Ht; }
  public static List<Win> Visible(uint[] pids) {
    var list = new List<Win>();
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      foreach (var p in pids) if (p == pid && IsWindowVisible(h)) {
        var s = new StringBuilder(256); GetWindowText(h, s, 256);
        if (s.Length == 0) continue;
        RECT r; GetWindowRect(h, out r);
        list.Add(new Win { H = h, Title = s.ToString(), X = r.Left, Y = r.Top, W = r.Right - r.Left, Ht = r.Bottom - r.Top });
      } return true; }, IntPtr.Zero);
    return list;
  }
  public static IntPtr Find(uint[] pids, string title) {
    IntPtr f = IntPtr.Zero;
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      foreach (var p in pids) if (p == pid) { var s = new StringBuilder(256); GetWindowText(h, s, 256);
        if (s.ToString() == title) { f = h; return false; } } return true; }, IntPtr.Zero);
    return f;
  }
  public static IntPtr FindAny(string title) {
    IntPtr f = IntPtr.Zero;
    EnumWindows((h, l) => { var s = new StringBuilder(256); GetWindowText(h, s, 256);
      if (s.ToString() == title) { f = h; return false; } return true; }, IntPtr.Zero);
    return f;
  }
  public static Win GetAny(string title) {
    IntPtr f = FindAny(title);
    if (f == IntPtr.Zero) return null;
    RECT r; GetWindowRect(f, out r);
    return new Win { H = f, Title = title, X = r.Left, Y = r.Top, W = r.Right - r.Left, Ht = r.Bottom - r.Top };
  }
  public static void Place(IntPtr h, int x, int y, int w, int ht) { ShowWindow(h, 9); MoveWindow(h, x, y, w, ht, true); }
}
'@

function Pids($n) { [uint32[]]@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallRoot-$n\*" } | ForEach-Object { [uint32]$_.Id }) }
$skip = '项目列表|^$|IME|Sogou|SoPY|TSF'

if ($Action -eq 'save') {
  $rows = @()
  foreach ($n in $Instances.Split(',')) {
    $n = $n.Trim()
    foreach ($w in [Lay]::Visible((Pids $n))) {
      if ($w.Title -match $skip) { continue }
      $rows += [pscustomobject]@{
        instance = $n
        role     = $(if ($w.Title -match '的调试器$') { 'debugger' } else { 'main' })
        title    = $w.Title
        x        = $w.X
        y        = $w.Y
        width    = $w.W
        height   = $w.Ht
      }
    }
  }
  if ($LogTitle) {
    $lw = [Lay]::GetAny($LogTitle)
    if ($lw) {
      $rows += [pscustomobject]@{ instance = 'log'; role = 'console'; title = $lw.Title; x = $lw.X; y = $lw.Y; width = $lw.W; height = $lw.Ht }
    }
  }
  $rows | ConvertTo-Json -Depth 4 | Set-Content -Path $File -Encoding UTF8
  Write-Host "已记住 → $File（$($rows.Count) 个窗口）"
  foreach ($r in $rows) { Write-Host ("  {0,-4} {1,-8} {2,-10} {3}x{4} @ ({5},{6})" -f $r.instance, $r.role, $r.title, $r.width, $r.height, $r.x, $r.y) }
  return
}

if (-not (Test-Path $File)) { Write-Error "找不到 $File（先 -Action save）"; exit 2 }
$saved = @(Get-Content $File -Raw | ConvertFrom-Json)
if ($saved.Count -eq 1 -and -not $saved[0].title) { $saved = @($saved[0]) }
foreach ($v in $saved) {
  if (-not $v.title) { continue }
  if ($Action -eq 'show') { Write-Host ("  {0,-4} {1,-8} {2,-10} {3}x{4} @ ({5},{6})" -f $v.instance, $v.role, $v.title, $v.width, $v.height, $v.x, $v.y); continue }
  $h = if ($v.instance -eq 'log') { [Lay]::FindAny($v.title) } else { [Lay]::Find((Pids $v.instance), $v.title) }
  if ($h -eq [IntPtr]::Zero) { Write-Host "  [$($v.instance) $($v.role)] 窗口不在（跳过）"; continue }
  [Lay]::Place($h, $v.x, $v.y, $v.width, $v.height)
  Write-Host ("  [{0} {1}] → {2}x{3} @ ({4},{5})" -f $v.instance, $v.role, $v.width, $v.height, $v.x, $v.y)
  Start-Sleep -Milliseconds 400
}
