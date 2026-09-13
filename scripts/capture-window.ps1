<#
  截取开发者工具某个窗口的**整个窗口**（用于确认面板布局 / 窗口形态；不受遮挡影响）
  用法：pwsh scripts\capture-window.ps1 -Instance p5 -Out shot.png [-InstallRoot D:\Tencent\wechatdev]
        pwsh scripts\capture-window.ps1 -ProcessId 1234 -Out shot.png   # 按 PID 抓任意窗口（含独立日志窗）
  说明：PrintWindow(PW_RENDERFULLCONTENT=2) 抓窗口自身内容；若返回全黑（GPU 合成窗口偶发），
        自动回退到按窗口矩形抓屏（会先最大化 + 置前）。
        注意参数名是 -ProcessId：叫 -Pid 会撞 PowerShell 只读自动变量 $PID。
#>
param(
  [string]$Instance = '',
  [int]$ProcessId = 0,
  [Parameter(Mandatory = $true)][string]$Out,
  [string]$InstallRoot = 'D:\Tencent\wechatdev'
)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@

$proc = if ($ProcessId -gt 0) {
  Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
} elseif ($Instance) {
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallRoot-$Instance\*" -and $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
} else { $null }
if (-not $proc) { Write-Error "找不到窗口（-Instance $Instance / -ProcessId $ProcessId）"; exit 1 }
$label = if ($Instance) { $Instance } else { "pid$ProcessId" }
if ($proc.MainWindowHandle -eq 0) { Write-Error "[$label] 没有可见窗口"; exit 1 }

$h = $proc.MainWindowHandle
$r = New-Object WinCap+RECT
[void][WinCap]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
Write-Host "[$label] 窗口 ${w}x${ht} @ ($($r.Left),$($r.Top)) PID $($proc.Id)"

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][WinCap]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# 全黑则回退抓屏
$probe = $bmp.GetPixel([int]($w / 2), [int]($ht / 2))
if ($probe.R -eq 0 -and $probe.G -eq 0 -and $probe.B -eq 0) {
  Write-Host '  PrintWindow 返回黑图，回退抓屏…'
  [void][WinCap]::ShowWindow($h, 3)          # 最大化保证完整可见
  [void][WinCap]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 700
  [void][WinCap]::GetWindowRect($h, [ref]$r)
  $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
  $bmp.Dispose()
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $ht))
  $g.Dispose()
}

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "  已保存 $Out"
