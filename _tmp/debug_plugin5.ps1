$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\catime_dbg5.log"
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss.fff), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PS=$($PSVersionTable.PSVersion)"

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinEnum {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    public static List<string> TopLevelClasses() {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h) {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            list.Add(sb.ToString());
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
try {
    Add-Type -TypeDefinition $src
    L "Add-Type OK"
} catch {
    L "Add-Type FAILED: $($_.Exception.Message)"
}

foreach ($cls in @('Shell_TrayWnd', 'CatimeWindowClass', 'Progman')) {
    L ("FindWindowW(" + $cls + ",null) -> " + [WinEnum]::FindWindowW($cls, $null))
}

for ($i = 0; $i -lt 80; $i++) {
    $classes = [WinEnum]::TopLevelClasses()
    $has = $false
    foreach ($c in $classes) { if ($c -eq 'CatimeNotificationClass') { $has = $true } }
    if ($has) {
        $f1 = [WinEnum]::FindWindowW('CatimeNotificationClass', $null)
        $f2 = [WinEnum]::FindWindowW('CatimeNotificationClass', 'Catime Notification')
        $f3 = [WinEnum]::FindWindowW($null, 'Catime Notification')
        $f4 = [WinEnum]::FindWindowW('CatimeNotificationClass', '')
        L ("tick " + $i + " ENUM-FOUND total=" + $classes.Count + " findClsNull=" + $f1 + " findClsTitle=" + $f2 + " findNullTitle=" + $f3 + " findClsEmpty=" + $f4)
    }
    elseif ($i % 10 -eq 0) {
        L ("tick " + $i + " no toast total=" + $classes.Count)
    }
    Start-Sleep -Milliseconds 300
}
L "loop done"
