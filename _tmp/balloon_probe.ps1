# 只读实验：复刻 Catime 的 Shell_NotifyIcon 气球调用，检测气球弹出时出现的窗口
# 仅创建本进程临时托盘图标并弹出气球，前后快照枚举所有可见顶层窗口。不碰 Catime、不碰用户配置。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinEnum {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static List<string> Snapshot() {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h) {
            if (!IsWindowVisible(h)) return true;
            var c = new System.Text.StringBuilder(256); GetClassName(h, c, 256);
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            list.Add(c + "|" + t + "|pid=" + pid);
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
Add-Type -TypeDefinition $src

function Snap { return [WinEnum]::Snapshot() }

$log = "D:/files/works/20051012CatTime插件/_tmp/balloon_probe_result.txt"
function Out($m) { Add-Content -Path $log -Value $m }
Remove-Item $log -ErrorAction SilentlyContinue

$baseline = Snap
Out "=== 基线可见顶层窗口数: $($baseline.Count) ==="

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Application
$icon.Visible = $true
Start-Sleep -Milliseconds 500

# 复刻 Catime: NIIF_NONE(无图标), 标题为空, 3 秒超时
$icon.ShowBalloonTip(3000, "", "45m Pomodoro completed (Cycle1/1 Round 1/4)", [System.Windows.Forms.ToolTipIcon]::None)
Out "气球已弹出，开始 15 秒窗口监控..."

$deadline = (Get-Date).AddSeconds(15)
$seen = @{}
while ((Get-Date) -lt $deadline) {
    $now = Snap
    foreach ($w in $now) {
        if ($baseline -notcontains $w -and -not $seen.ContainsKey($w)) {
            $seen[$w] = $true
            Out "NEW: $w"
        }
    }
    Start-Sleep -Milliseconds 200
}

if ($seen.Count -eq 0) { Out "RESULT: 气球期间未出现任何新的可见顶层窗口" }
$icon.Visible = $false
$icon.Dispose()
Out "=== 实验结束，托盘图标已清理 ==="
