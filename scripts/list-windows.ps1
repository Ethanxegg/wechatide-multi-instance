<#
  列出某个（或全部）开发者工具实例的顶层窗口：句柄 / 可见性 / 类名 / 标题 / 位置尺寸
  用法：pwsh scripts\list-windows.ps1 -Instances p2,p3,p4,p5 [-InstallRoot D:\Tencent\wechatdev]
  用途：确认窗口有没有出、是不是只剩模拟器（lite）、独立日志窗在不在、位置对不对
#>
param(
  [string]$Instances = 'p2,p3,p4,p5',
  [string]$InstallRoot = 'D:\Tencent\wechatdev'
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinList {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public static List<string> List(uint[] pids) {
    var outp = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      foreach (var p in pids) if (p == pid) {
        var t = new StringBuilder(256); GetWindowText(h, t, 256);
        var c = new StringBuilder(256); GetClassName(h, c, 256);
        RECT r; GetWindowRect(h, out r);
        outp.Add(string.Format("{0}|{1}|{2}|{3}|{4}x{5}@{6},{7}", h.ToInt64(),
          IsWindowVisible(h) ? "可见" : "隐藏", c, t, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top));
      }
      return true;
    }, IntPtr.Zero);
    return outp;
  }
}
'@

foreach ($inst in $Instances.Split(',')) {
  $inst = $inst.Trim()
  $ps = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallRoot-$inst\*" })
  Write-Host "=== [$inst] 进程 $($ps.Count) ==="
  $rows = [WinList]::List([uint32[]]($ps | ForEach-Object { [uint32]$_.Id }))
  foreach ($r in $rows) {
    $f = $r.Split('|')
    if ($f[2] -match 'IME|Sogou|SoPY|TSF') { continue }
    Write-Host ("  {0,-9} {1,-18} {2,-24} {3}" -f $f[1], $f[2], ($f[3].Substring(0, [Math]::Min(22, $f[3].Length))), $f[4])
  }
}
