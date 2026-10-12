$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\catime_dbg3.log"
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss.fff), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PS=$($PSVersionTable.PSVersion)"

try {
    Add-Type -Namespace PomStat -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
'@
    L "T1 Add-Type: OK"
} catch {
    L "T1 Add-Type FAILED: $($_.Exception.Message)"
}
try {
    Add-Type -AssemblyName UIAutomationClient
    L "T2 UIA assembly: OK"
} catch {
    L "T2 UIA FAILED: $($_.Exception.Message)"
}

for ($i = 0; $i -lt 80; $i++) {
    $t0 = Get-Date
    $r1 = "n/a"
    try {
        $h = [PomStat.Win]::FindWindowW('CatimeNotificationClass', $null)
        $r1 = if ($h -eq [IntPtr]::Zero) { "ZERO" } else { "hwnd=$h" }
    } catch { $r1 = "ERR" }
    $t1 = Get-Date
    $r2 = "n/a"
    try {
        $c2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CatimeNotificationClass')
        $e2 = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $c2)
        $r2 = if ($e2 -ne $null) { "hwnd=$($e2.Current.NativeWindowHandle)" } else { "ZERO" }
    } catch { $r2 = "ERR" }
    $t2 = Get-Date
    $d1 = [int]($t1 - $t0).TotalMilliseconds
    $d2 = [int]($t2 - $t1).TotalMilliseconds
    if ($r1 -ne "ZERO" -or $r2 -ne "ZERO" -or $d1 -gt 50 -or $d2 -gt 50) {
        L "tick $i pinvoke=$r1 (${d1}ms) uia=$r2 (${d2}ms)"
    }
    Start-Sleep -Milliseconds 300
}
L "loop done"
