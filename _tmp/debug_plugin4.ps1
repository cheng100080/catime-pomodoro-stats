$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\catime_dbg4.log"
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss.fff), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PS=$($PSVersionTable.PSVersion)"

try {
    Add-Type -Namespace PomStat -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);
'@
    L "Add-Type: OK"
} catch {
    L "Add-Type FAILED: $($_.Exception.Message)"
}

# 已知类名测试（这些窗口此刻一定存在）
foreach ($cls in @('Shell_TrayWnd', 'CatimeWindowClass', 'Notepad', 'Progman')) {
    $h = [PomStat.Win]::FindWindowW($cls, $null)
    L "FindWindowW($cls) -> $h"
}

# EnumWindows 枚举所有顶层窗口类名
function Enum-TopClasses {
    $names = New-Object System.Collections.Generic.List[string]
    $cb = [PomStat.EnumProc]{
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [PomStat.Win]::GetClassName($h, $sb, 256) | Out-Null
        $names.Add($sb.ToString())
        return $true
    }
    [PomStat.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $names
}

for ($i = 0; $i -lt 80; $i++) {
    $classes = Enum-TopClasses
    $hasToast = ($classes -contains 'CatimeNotificationClass')
    if ($hasToast) {
        L "tick $i ENUM-FOUND CatimeNotificationClass (total windows: $($classes.Count))"
    }
    elseif ($i % 10 -eq 0) {
        L "tick $i no toast (total windows: $($classes.Count))"
    }
    Start-Sleep -Milliseconds 300
}
L "loop done"
