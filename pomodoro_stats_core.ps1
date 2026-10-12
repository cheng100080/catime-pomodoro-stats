<#
.SYNOPSIS
    Catime 番茄钟统计插件（pomodoro_stats）

.DESCRIPTION
    在 Catime 窗口实时显示：今日 / 本周（周一起） / 累计完成的番茄数，
    计数持久化在脚本旁的 pomodoro_stats.json，Catime 重启后不丢失。

    工作原理：
      1. Catime 每完成一个番茄钟阶段（工作或休息）都会弹出一次通知。
         当通知类型为 CATIME（默认值）时，该通知是一个窗口类名为
         "CatimeNotificationClass" 的置顶弹窗。
      2. 本插件每 500ms 检测一次该窗口是否出现；出现新窗口即视为
         "一个阶段刚刚完成"。
      3. 结合 config.ini [Pomodoro] POMODORO_TIME_OPTIONS 的阶段序列，
         判定刚完成的是工作阶段还是休息阶段，仅工作阶段计数。
         为避免阶段索引漂移，优先用"距上次完成事件的间隔"匹配阶段时长，
         匹配失败时回退到顺序索引。
      4. 结果写入脚本旁的 output.txt 供 Catime 显示。

    依赖：Windows 自带 PowerShell 5.1，无任何第三方组件。

    注意：需要 Catime 的通知类型为 CATIME（默认）。若为 OS 或
          SYSTEM_MODAL，本插件无法可靠检测阶段完成事件，将显示
          "SET CATIME" 提示。

.NOTES
    License: Apache-2.0
#>

#requires -version 5.1

$ErrorActionPreference = 'Stop'

# ---------------- 可配置项 ----------------

# 显示标签：T=今日(Today)  W=本周(Week)  A=累计(All)
# 注意：Catime 使用配置的字体渲染文本，部分精简字体缺少中文字形，
# 中文标签可能显示为方框，故默认使用 ASCII 标签。可自行改成中文试试。
$LabelToday = 'T'
$LabelWeek  = 'W'
$LabelMonth = 'M'
$LabelTotal = 'A'

# 显示哪些统计（设 $false 只是"不显示"，后台照常记录，可随时改回）
$ShowWeek  = $true
$ShowMonth = $false
$ShowTotal = $false

# 插件模式的窗口位置（可选；只影响插件运行时，不会改动你正常时间的位置设置）
#   'keep'        = 不动窗口（与正常时间共用 Catime 的位置）
#   'bottomright' = 贴工作区右下角（自动避开任务栏）
#   也可用：'bottomleft' / 'topright' / 'topleft' / 'center'
# 说明：Catime 的位置设置两种模式共用，而插件窗口尺寸与正常时间不同，
#       所以缩小后不会自动贴回右下角——用这个开关让插件自己贴角即可。
$PluginAnchor  = 'bottomright'
$AnchorMarginX = 0
$AnchorMarginY = 0

# 显示模式：
#   'both'  = 始终显示"统计 + 计时"（稳健：番茄钟每一段、普通倒计时都能看到计时）
#   'timer' = 推断正在计时时只显示计时，其余时间显示统计
#             ⚠ 注意：Catime 不提供"计时开始"的任何信号（开始计时不写配置文件、
#             不新建窗口、无 IPC），所以：
#               · 每轮番茄钟的第 1 段无法切换（插件感知不到它开始了），仍显示"统计 + 计时"
#               · 你手动中断计时后，统计要等该段预期结束才会恢复
#             想要纯计时观感就改成 'timer'
$TimerDisplayMode = 'timer'

# 计数口径（计什么算"1 个番茄"）：
#   'work'  = 每完成一个"工作阶段"计 1 个（正统番茄工作法：番茄 = 一个工作时段，休息不算）
#   'cycle' = 走完"一整轮"阶段序列（含休息）才计 1 个（即 Catime 内部 complete_pomodoro_cycles 的口径）
$CountUnit = 'work'

# 阶段类型模板：按 config.ini 里 POMODORO_TIME_OPTIONS 的顺序，逐段标注
#   'W' = 工作阶段   'B' = 休息阶段
# 例：序列 45m,10m,45m,20m → 'WBWB'；序列 10m,5m,10m → 'WBW'
#
# 【这是本插件自定义的配置项，不是 Catime 的功能】
#   Catime 没有"工作/休息"这个概念，官方文档里也没有 W/B 这种写法；
#   这里的 W/B 只是本脚本自己用的简写（Work / Break 的首字母）。
#   平时保持为空即可，不需要填写。
#
# 留空（默认）= 自动模式：按 Catime 的常见约定，第 1、3、5… 段视为工作阶段
#                （即以工作阶段开始、工作与休息交替）
#
# 说明：Catime 内部并不记录"工作/休息"属性（源码里该字段只会是 IDLE 或 WORK），
# 通知文本也只含时长与轮次，因此工作/休息完全靠用户约定。若你的序列不符合
# 上述约定（例如以休息段开始、或连续两段工作），在这里显式写出模板最可靠；
# 模板长度与序列长度不一致时会自动回退到自动模式，并在日志中记录。
$PhaseTypes = ''

# 轮询间隔（毫秒）。Catime 默认 toast 显示 3 秒以上，500ms 足够捕捉。
$PollMs = 500

# Catime 通知弹窗的窗口类名（源码 resource_ui_ids.h 定义，请勿改动）
$ToastClass = 'CatimeNotificationClass'

# ---------------- 路径 ----------------

$ScriptDir  = $PSScriptRoot
$OutputFile = Join-Path $ScriptDir 'output.txt'
$StateFile  = Join-Path $ScriptDir 'pomodoro_stats.json'
$LogFile    = Join-Path $ScriptDir 'pomodoro_stats.log'

# 插件目录为 <Catime根目录>\resources\plugins，故根目录为上两级
$CatimeRoot = Split-Path (Split-Path $ScriptDir -Parent) -Parent
$ConfigCandidates = @(
    (Join-Path $CatimeRoot 'config.ini')
    (Join-Path $env:LOCALAPPDATA 'Catime\config.ini')
)
$ConfigFile = $ConfigCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

# ---------------- Win32 互操作 ----------------

# 说明：经实测，FindWindowW 按类名查找对非本进程注册的窗口类不可靠
# （返回 0），而 EnumWindows + GetClassName 可稳定跨进程枚举，故采用后者。
# 注意：-MemberDefinition 模式下代码位于类体内，不能用 using 指令，需全限定名。
Add-Type -Namespace PomStat -Name Win -MemberDefinition @'
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SystemParametersInfo(uint action, uint param, out RECT rect, uint winIni);
// 返回类名为 cls 的第一个顶层窗口句柄，找不到返回 IntPtr.Zero
public static IntPtr FindWindowByClass(string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
        if (found != IntPtr.Zero) { return false; }
        var sb = new System.Text.StringBuilder(256);
        GetClassName(hWnd, sb, 256);
        if (sb.ToString() == cls) { found = hWnd; return false; }
        return true;
    }, IntPtr.Zero);
    return found;
}
// 窗口尺寸编码成一个 long（宽<<32 | 高），便于比较是否变化
public static long GetWindowSignature(IntPtr hWnd) {
    RECT r;
    if (!GetWindowRect(hWnd, out r)) { return 0; }
    return ((long)(r.Right - r.Left) << 32) | (uint)(r.Bottom - r.Top);
}
// 把窗口贴到指定位置：mode 1=右下 2=左下 3=右上 4=左上 5=居中 6=绝对坐标
public static bool AnchorWindow(IntPtr hWnd, int mode, int marginX, int marginY) {
    RECT r, wa;
    if (!GetWindowRect(hWnd, out r)) { return false; }
    int w = r.Right - r.Left, h = r.Bottom - r.Top;
    if (!SystemParametersInfo(0x0030, 0, out wa, 0)) { return false; }
    int x, y;
    switch (mode) {
        case 1: x = wa.Right  - w - marginX; y = wa.Bottom - h - marginY; break;
        case 2: x = wa.Left   + marginX;     y = wa.Bottom - h - marginY; break;
        case 3: x = wa.Right  - w - marginX; y = wa.Top    + marginY;     break;
        case 4: x = wa.Left   + marginX;     y = wa.Top    + marginY;     break;
        case 5: x = wa.Left + (wa.Right - wa.Left - w) / 2;
                y = wa.Top  + (wa.Bottom - wa.Top - h) / 2;               break;
        case 6: x = marginX; y = marginY;                                 break;
        default: return false;
    }
    return SetWindowPos(hWnd, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
}
'@

# ---------------- 配置读取 ----------------

function Read-CatimeConfig {
    <#
      读取 Catime config.ini，返回:
        @{ Type = 'CATIME'|'OS'|'SYSTEM_MODAL'; Pattern = @(工作秒,休息秒,...) }
      读取失败时返回默认值（与 Catime 内置默认一致）。
    #>
    $result = @{ Type = 'CATIME'; Pattern = @(1500, 300, 1500, 600); LoopCount = 1 }
    if (-not $ConfigFile) { return $result }
    try {
        $section = ''
        foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
            if ($t.StartsWith('[') -and $t.EndsWith(']')) {
                $section = $t.Substring(1, $t.Length - 2).Trim()
                continue
            }
            $eq = $t.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $t.Substring(0, $eq).Trim()
            $val = $t.Substring($eq + 1).Trim()
            if ($section -eq 'Notification' -and $key -eq 'NOTIFICATION_TYPE' -and $val) {
                $result.Type = $val.ToUpper()
            }
            elseif ($section -eq 'Pomodoro' -and $key -eq 'POMODORO_LOOP_COUNT') {
                if ($val -match '^\d+$' -and [int]$val -ge 1) { $result.LoopCount = [int]$val }
            }
            elseif ($section -eq 'Pomodoro' -and $key -eq 'POMODORO_TIME_OPTIONS') {
                $parts = @()
                foreach ($p in ($val -split ',')) {
                    $p = $p.Trim()
                    if ($p -match '^\d+$' -and [int]$p -gt 0) { $parts += [int]$p }
                }
                if ($parts.Count -ge 1 -and $parts.Count -le 16) { $result.Pattern = $parts }
            }
        }
    }
    catch { }
    return $result
}

# ---------------- 阶段类型判定（工作 / 休息） ----------------

function Get-WorkMask {
    <#
      返回 @{ Mask = @($true,$false,...); Source = '说明' }
      Mask 与阶段序列逐段对应：$true = 工作阶段（计数），$false = 休息阶段（不计数）。
      优先采用显式模板 $PhaseTypes；为空或长度与序列不一致时回退到自动模式。
    #>
    param($Pattern, [string]$Types)

    $t = ''
    if ($Types) { $t = ($Types -replace '[^WwBb]', '').ToUpper() }

    if ($t.Length -gt 0 -and $t.Length -eq $Pattern.Count) {
        $mask = @()
        foreach ($c in $t.ToCharArray()) { $mask += ($c -eq 'W') }
        return @{ Mask = $mask; Source = ('显式模板 ' + $t) }
    }

    if ($t.Length -gt 0) {
        $why = ('显式模板长度 {0} 与序列长度 {1} 不一致，已回退自动模式' -f $t.Length, $Pattern.Count)
    }
    else {
        $why = '自动模式（第 1、3、5… 段 = 工作阶段）'
    }

    $mask = @()
    for ($i = 0; $i -lt $Pattern.Count; $i++) { $mask += (($i % 2) -eq 0) }
    return @{ Mask = $mask; Source = $why }
}

# ---------------- 状态持久化 ----------------

function Load-State {
    $state = @{ total = 0; days = @{}; phase = 0; lastEvent = $null }
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $state.total  = [int]$j.total
            $state.phase  = [int]$j.phase
            if ($j.lastEvent) { $state.lastEvent = [datetime]$j.lastEvent }
            $d = @{}
            foreach ($p in $j.days.PSObject.Properties) {
                if ($p.Name -match '^\d{4}-\d{2}-\d{2}$') { $d[$p.Name] = [int]$p.Value }
            }
            $state.days = $d
        }
        catch { }
    }
    return $state
}

function Save-State {
    param($State)
    try {
        # 清理 400 天以前的明细，保持状态文件精简
        $cutoff = (Get-Date).Date.AddDays(-400)
        $stale = @($State.days.Keys | Where-Object {
            [datetime]::ParseExact($_, 'yyyy-MM-dd', $null) -lt $cutoff
        })
        foreach ($k in $stale) { $State.days.Remove($k) | Out-Null }

        $obj = [ordered]@{
            version   = 1
            total     = $State.total
            phase     = $State.phase
            lastEvent = if ($State.lastEvent) { $State.lastEvent.ToString('o') } else { $null }
            days      = $State.days
        }
        $json = $obj | ConvertTo-Json -Depth 5 -Compress
        $tmp  = "$StateFile.tmp"
        # UTF-8 无 BOM，先写临时文件再移动，保证中途被杀也不会写坏状态
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $StateFile -Force
    }
    catch { }
}

# ---------------- 统计与显示 ----------------

function Get-WeekStart {
    param([datetime]$Date)
    # 以周一为一周的开始
    return $Date.Date.AddDays(-((([int]$Date.DayOfWeek) + 6) % 7))
}

function Get-WeekCount {
    param($Days, [datetime]$Today)
    $ws = Get-WeekStart $Today
    $n  = 0
    foreach ($k in $Days.Keys) {
        $dt = [datetime]::ParseExact($k, 'yyyy-MM-dd', $null)
        if ($dt -ge $ws -and $dt -le $Today.Date) { $n += $Days[$k] }
    }
    return $n
}

function Get-MonthCount {
    param($Days, [datetime]$Today)
    $prefix = $Today.ToString('yyyy-MM')
    $n = 0
    foreach ($k in $Days.Keys) {
        if ($k.StartsWith($prefix)) { $n += $Days[$k] }
    }
    return $n
}

function Write-Display {
    param([string]$Text)
    try {
        # Catime 要求 output.txt 为 UTF-8 无 BOM
        [System.IO.File]::WriteAllText($OutputFile, "<fps:1>$Text",
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $LogFile) -and
            (Get-Item -LiteralPath $LogFile).Length -gt 65536) {
            Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value (
            "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    }
    catch { }
}

# 显示文本末尾必须带 <catime></catime>：
# Catime 在开始计时/番茄钟时会停掉所有插件并关闭插件显示，
# 只有输出中含该标签的插件会被保留（源码 window_procedure.c: CleanupBeforeTimerAction）。
# 该标签处会渲染当前计时/时间，因此插件模式下也能看到倒计时。
$CatimeTag = '  <catime></catime>'

function Refresh-Display {
    param($State)
    # $TimerDisplayMode='timer' 且推断正在计时 → 只显示计时
    if ($TimerDisplayMode -eq 'timer' -and $script:TimerEndsAt -ne $null -and
        (Get-Date) -lt $script:TimerEndsAt) {
        Write-Display '<catime></catime>'
        return
    }
    $today  = Get-Date
    $dayKey = $today.ToString('yyyy-MM-dd')
    $t = 0
    if ($State.days.ContainsKey($dayKey)) { $t = $State.days[$dayKey] }
    $w = Get-WeekCount  $State.days $today
    $mo = Get-MonthCount $State.days $today

    # 按开关拼装显示内容（未显示的项后台照常统计）
    $parts = @(('{0}{1}' -f $LabelToday, $t))
    if ($ShowWeek)  { $parts += ('{0}{1}' -f $LabelWeek, $w) }
    if ($ShowMonth) { $parts += ('{0}{1}' -f $LabelMonth, $mo) }
    if ($ShowTotal) { $parts += ('{0}{1}' -f $LabelTotal, $State.total) }
    Write-Display (($parts -join ' ') + $CatimeTag)
}

# ---------------- 阶段完成处理 ----------------

function Invoke-PhaseComplete {
    param($State, $Pattern, $WorkMask, $LoopCount)

    $now    = Get-Date
    $n      = $Pattern.Count
    $idx    = $State.phase % $n
    $isWork = $false
    $last   = $State.lastEvent

    if ($last) {
        $gap = ($now - $last).TotalSeconds
        $maxDur = ($Pattern | Measure-Object -Maximum).Maximum
        if ($gap -gt (2 * $maxDur + 300)) {
            # 距上次完成间隔远超任何一个阶段时长：视为重新开始了新的番茄钟，
            # 则刚完成的是新序列的第 1 段（类型由阶段类型模板决定）
            $idx = 0
        }
        else {
            # 用间隔匹配阶段时长（容忍暂停造成的偏差），实现阶段索引自纠正
            $best = -1
            $bestErr = [double]::MaxValue
            $curErr = [double]::MaxValue
            for ($i = 0; $i -lt $n; $i++) {
                $tol = [math]::Max(60, $Pattern[$i] * 0.15)
                $err = [math]::Abs($gap - $Pattern[$i])
                if ($err -le $tol) {
                    if ($err -lt $bestErr) { $bestErr = $err; $best = $i }
                    if ($i -eq $idx) { $curErr = $err }
                }
            }
            # 多个阶段时长相同（如 25,5,25,10）时，优先保持与当前索引连续，防止索引漂移
            if ($best -ge 0 -and $curErr -le $bestErr + 2.0) { $best = $idx }
            if ($best -ge 0) { $idx = $best }
        }
    }

    # 工作/休息由阶段类型模板决定（见 Get-WorkMask）
    $isWork = [bool]$WorkMask[$idx]

    # 计数口径：work = 每个工作阶段；cycle = 整轮序列走完（刚完成的是序列最后一段）
    $isCounted = if ($CountUnit -eq 'cycle') { ($idx -eq ($n - 1)) } else { $isWork }

    $State.phase     = ($idx + 1) % $n
    $State.lastEvent = $now

    if ($isCounted) {
        $State.total++
        $dayKey = $now.ToString('yyyy-MM-dd')
        if (-not $State.days.ContainsKey($dayKey)) { $State.days[$dayKey] = 0 }
        $State.days[$dayKey]++
        Write-Log ("计 1 个番茄(口径={0}): total={1}" -f $CountUnit, $State.total)
    }
    # 推断"下一段计时"的结束时刻（Catime 番茄钟各段无缝衔接），供 $TimerDisplayMode='timer' 使用
    if ($idx -eq ($n - 1)) { $script:CyclesDone++ }
    if (($idx -eq ($n - 1)) -and ($script:CyclesDone -ge $LoopCount)) {
        # 整轮循环已跑完 → Catime 停表，之后不再有计时
        $script:TimerEndsAt = $null
    }
    else {
        $script:TimerEndsAt = $now.AddSeconds($Pattern[($idx + 1) % $n])
    }

    Save-State $State
    if ($isCounted) { Refresh-Display $State }
}

# ---------------- 主循环 ----------------

$cfg        = Read-CatimeConfig
$cfgMtime   = if ($ConfigFile) { (Get-Item -LiteralPath $ConfigFile).LastWriteTime } else { $null }
$workMask   = (Get-WorkMask $cfg.Pattern $PhaseTypes).Mask
$maskSource = (Get-WorkMask $cfg.Pattern $PhaseTypes).Source
$state      = Load-State
$lastToast  = [IntPtr]::Zero
$hintShown  = $false
$loggedErr  = @{}
$script:TimerEndsAt = $null   # 推断的"当前这段计时结束时刻"（$TimerDisplayMode='timer' 用）
$script:CyclesDone  = 0       # 本次运行中已跑完的循环数
$timerOnlyShown     = $false  # 当前是否处于"只显示计时"状态
$lastWinSig         = 0       # 上次看到的 Catime 窗口尺寸（用于窗口贴角）

# 插件模式窗口定位模式
$AnchorMode = switch ($PluginAnchor) {
    'bottomright' { 1 }
    'bottomleft'  { 2 }
    'topright'    { 3 }
    'topleft'     { 4 }
    'center'      { 5 }
    default       { 0 }
}

Write-Log ("启动: PS={0} 配置={1} 类型={2} 阶段序列={3}" -f `
    $PSVersionTable.PSVersion, $ConfigFile, $cfg.Type, ($cfg.Pattern -join ','))
Write-Log ("阶段类型: {0} → {1}（{2}）" -f `
    ($cfg.Pattern -join ','), (($workMask | ForEach-Object { if ($_) { 'W' } else { 'B' } }) -join ''), $maskSource)

# 启动时立即写一次，避免 Catime 窗口空白
Save-State $state
if ($cfg.Type -ne 'CATIME') {
    Write-Display ('SET CATIME' + $CatimeTag)
    $hintShown = $true
}
else {
    Refresh-Display $state
}

# 启动时若启用了窗口贴角，立即贴一次
if ($AnchorMode -gt 0) {
    $hw0 = [PomStat.Win]::FindWindowByClass('CatimeWindowClass')
    if ($hw0 -ne [IntPtr]::Zero) {
        $lastWinSig = [PomStat.Win]::GetWindowSignature($hw0)
        [PomStat.Win]::AnchorWindow($hw0, $AnchorMode, $AnchorMarginX, $AnchorMarginY) | Out-Null
        Write-Log ("插件模式窗口已贴角: {0} (margin {1},{2})" -f $PluginAnchor, $AnchorMarginX, $AnchorMarginY)
    }
}

while ($true) {
    try {
        # 配置热更新：仅当 config.ini 修改时间变化时才重新读取
        if ($ConfigFile) {
            $m = (Get-Item -LiteralPath $ConfigFile).LastWriteTime
            if ($m -ne $cfgMtime) {
                $cfgMtime = $m
                $cfg      = Read-CatimeConfig
                $wm       = Get-WorkMask $cfg.Pattern $PhaseTypes
                $workMask   = $wm.Mask
                $maskSource = $wm.Source
                Write-Log ("配置已重载: 类型={0} 阶段序列={1}" -f $cfg.Type, ($cfg.Pattern -join ','))
                Write-Log ("阶段类型: {0}（{1}）" -f `
                    (($workMask | ForEach-Object { if ($_) { 'W' } else { 'B' } }) -join ''), $maskSource)
            }
        }

        if ($cfg.Type -ne 'CATIME') {
            # 通知类型不是 CATIME 时无法可靠检测阶段完成，显示设置提示
            if (-not $hintShown) {
                Write-Display ('SET CATIME' + $CatimeTag)
                $hintShown = $true
            }
        }
        else {
            if ($hintShown) {
                Refresh-Display $state
                $hintShown = $false
            }
            $h = [PomStat.Win]::FindWindowByClass($ToastClass)
            if ($h -ne [IntPtr]::Zero -and $h -ne $lastToast) {
                # 出现新的 toast 窗口 = 一个番茄钟阶段刚刚完成
                $lastToast = $h
                Invoke-PhaseComplete $state $cfg.Pattern $workMask $cfg.LoopCount
            }
            elseif ($h -eq [IntPtr]::Zero) {
                $lastToast = [IntPtr]::Zero
            }

            # $TimerDisplayMode='timer'：推断的计时窗口开/关时切换显示
            if ($TimerDisplayMode -eq 'timer') {
                $running = ($script:TimerEndsAt -ne $null) -and ((Get-Date) -lt $script:TimerEndsAt)
                if ($running -ne $timerOnlyShown) {
                    $timerOnlyShown = $running
                    Refresh-Display $state
                }
            }

            # 插件模式窗口贴角（$PluginAnchor 非 'keep' 时生效；窗口尺寸变化后重新贴角）
            if ($AnchorMode -gt 0) {
                $hw = [PomStat.Win]::FindWindowByClass('CatimeWindowClass')
                if ($hw -ne [IntPtr]::Zero) {
                    $sig = [PomStat.Win]::GetWindowSignature($hw)
                    if ($sig -ne 0 -and $sig -ne $lastWinSig) {
                        $lastWinSig = $sig
                        [PomStat.Win]::AnchorWindow($hw, $AnchorMode, $AnchorMarginX, $AnchorMarginY) | Out-Null
                    }
                }
            }
        }
    }
    catch {
        # 同类错误只记一次，避免刷日志
        $msg = $_.Exception.Message
        if (-not $loggedErr.ContainsKey($msg)) {
            $loggedErr[$msg] = $true
            Write-Log ("循环异常: {0}" -f $msg)
        }
    }
    Start-Sleep -Milliseconds $PollMs
}
