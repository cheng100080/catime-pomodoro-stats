$log = "D:/files/works/20051012CatTime插件/_tmp/probe_step.txt"
Remove-Item $log -ErrorAction SilentlyContinue
function Out($m) { Add-Content -Path $log -Value $m }
try {
    Out "step1: start"
    Add-Type -AssemblyName System.Windows.Forms
    Out "step2: winforms ok"
    Add-Type -AssemblyName System.Drawing
    Out "step3: drawing ok"
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
    Out "step4: add-type ok"
    $snap = [WinEnum]::Snapshot()
    Out "step5: snapshot count=$($snap.Count)"
} catch {
    Out "ERROR: $($_.Exception.Message)"
}
Out "done"
