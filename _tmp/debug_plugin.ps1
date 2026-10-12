$ErrorActionPreference = 'Stop'
$log = "$env:TEMP\catime_dbg.log"
function L($m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss.fff), $m) }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PSVersion=$($PSVersionTable.PSVersion)"
try {
    Add-Type -Namespace PomStat -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
'@
    L "add-type OK"
    $t = [PomStat.Win]::FindWindowW('CatimeNotificationClass', $null)
    L "initial find result: $t (zero=$($t -eq [IntPtr]::Zero))"
} catch {
    L "STARTUP EX: $($_.Exception.Message)"
    L "STARTUP EX FULL: $($_.Exception | Out-String)"
}
$n = 0
while ($n -lt 48) {
    $n++
    try {
        $h = [PomStat.Win]::FindWindowW('CatimeNotificationClass', $null)
        if ($h -ne [IntPtr]::Zero) { L "FOUND hwnd=$h at tick $n" }
    } catch {
        L "LOOP EX tick ${n}: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 250
}
L "loop done"
