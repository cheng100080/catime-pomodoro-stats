$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\catime_dbg6.log"
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
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            var sb = new StringBuilder(256);
            GetClassName(hWnd, sb, 256);
            list.Add(sb.ToString());
            return true;
        }, IntPtr.Zero);
        return list;
    }
    public static IntPtr FindByClass(string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (found != IntPtr.Zero) { return false; }
            var sb = new StringBuilder(256);
            GetClassName(hWnd, sb, 256);
            if (sb.ToString() == cls) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
try {
    Add-Type -TypeDefinition $src
    L "Add-Type OK"
} catch {
    L "Add-Type FAILED: $($_.Exception.Message)"
    L "loop skipped"
    return
}

L ("known FindWindowW Shell_TrayWnd -> " + [WinEnum]::FindWindowW('Shell_TrayWnd', $null))
L ("known FindWindowW CatimeWindowClass -> " + [WinEnum]::FindWindowW('CatimeWindowClass', $null))
$all = [WinEnum]::TopLevelClasses()
L ("EnumWindows total top-level: " + $all.Count)
L ("EnumWindows has CatimeWindowClass: " + ($all -contains 'CatimeWindowClass'))

for ($i = 0; $i -lt 80; $i++) {
    $found = [WinEnum]::FindByClass('CatimeNotificationClass')
    $fw = [WinEnum]::FindWindowW('CatimeNotificationClass', $null)
    if ($found -ne [IntPtr]::Zero -or $fw -ne [IntPtr]::Zero) {
        L ("tick " + $i + " enumFind=" + $found + " findWindowW=" + $fw)
    }
    elseif ($i % 10 -eq 0) {
        L ("tick " + $i + " none")
    }
    Start-Sleep -Milliseconds 300
}
L "loop done"
