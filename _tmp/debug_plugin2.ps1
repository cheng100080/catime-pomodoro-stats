$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\catime_dbg2.log"
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss.fff), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PS=$($PSVersionTable.PSVersion)"

# T1: Add-Type (需要 csc 编译)
try {
    Add-Type -Namespace PomStat -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
'@
    L "T1 Add-Type: OK"
    L "T1 initial find: $([PomStat.Win]::FindWindowW('CatimeNotificationClass', $null))"
} catch {
    L "T1 Add-Type FAILED: $($_.Exception.Message)"
    L "T1 FULL: $($_ | Out-String)"
}

# T2: UIAutomation（纯程序集加载，无需编译）
try {
    Add-Type -AssemblyName UIAutomationClient
    L "T2 UIAutomationClient assembly: OK"
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CatimeNotificationClass')
    $el = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    if ($el -ne $null) { L "T2 UIA find: name=$($el.Current.Name) hwnd=$($el.Current.NativeWindowHandle)" } else { L "T2 UIA find: null" }
} catch {
    L "T2 UIA FAILED: $($_.Exception.Message)"
}

# 循环对比两种方法
for ($i = 0; $i -lt 60; $i++) {
    $r1 = "n/a"
    try {
        $h = [PomStat.Win]::FindWindowW('CatimeNotificationClass', $null)
        $r1 = if ($h -eq [IntPtr]::Zero) { "ZERO" } else { "$h" }
    } catch { $r1 = "ERR" }
    $r2 = "n/a"
    try {
        $c2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CatimeNotificationClass')
        $e2 = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $c2)
        $r2 = if ($e2 -ne $null) { "hwnd=$($e2.Current.NativeWindowHandle)" } else { "ZERO" }
    } catch { $r2 = "ERR" }
    L "tick $i pinvoke=$r1 uia=$r2"
    Start-Sleep -Milliseconds 300
}
L "loop done"
