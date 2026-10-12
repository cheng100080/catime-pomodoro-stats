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
$LabelTotal = 'A'

# 轮询间隔（毫秒）。Catime 默认 toast 显示 3 秒以上，500ms 足够捕捉。
$PollMs = 500

# Catime 通知弹窗的窗口类名（源码 resource_ui_ids.h 定义，请勿改动）
$ToastClass = 'CatimeNotificationClass'

# ---------------- 路径 ----------------

$ScriptDir  = $PSScriptRoot
$OutputFile = Join-Path $ScriptDir 'output.txt'
$StateFile  = Join-Path $ScriptDir 'pomodoro_stats.json'

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
'@

# ---------------- 配置读取 ----------------

function Read-CatimeConfig {
    <#
      读取 Catime config.ini，返回:
        @{ Type = 'CATIME'|'OS'|'SYSTEM_MODAL'; Pattern = @(工作秒,休息秒,...) }
      读取失败时返回默认值（与 Catime 内置默认一致）。
    #>
    $result = @{ Type = 'CATIME'; Pattern = @(1500, 300, 1500, 600) }
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

function Write-Display {
    param([string]$Text)
    try {
        # Catime 要求 output.txt 为 UTF-8 无 BOM
        [System.IO.File]::WriteAllText($OutputFile, "<fps:1>$Text",
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Refresh-Display {
    param($State)
    $today  = Get-Date
    $dayKey = $today.ToString('yyyy-MM-dd')
    $t = 0
    if ($State.days.ContainsKey($dayKey)) { $t = $State.days[$dayKey] }
    $w = Get-WeekCount $State.days $today
    Write-Display ('{0}{1} {2}{3} {4}{5}' -f $LabelToday, $t, $LabelWeek, $w, $LabelTotal, $State.total)
}

# ---------------- 阶段完成处理 ----------------

function Invoke-PhaseComplete {
    param($State, $Pattern)

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
            # 则刚完成的是新循环的第 1 个阶段（工作阶段）
            $idx = 0
            $isWork = $true
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
            # 匹配失败时保留顺序索引；阶段序列第 1、3、5... 个为工作阶段
            $isWork = ($idx % 2 -eq 0)
        }
    }
    else {
        $isWork = ($idx % 2 -eq 0)
    }

    $State.phase     = ($idx + 1) % $n
    $State.lastEvent = $now

    if ($isWork) {
        $State.total++
        $dayKey = $now.ToString('yyyy-MM-dd')
        if (-not $State.days.ContainsKey($dayKey)) { $State.days[$dayKey] = 0 }
        $State.days[$dayKey]++
    }
    Save-State $State
    if ($isWork) { Refresh-Display $State }
}

# ---------------- 主循环 ----------------

$cfg        = Read-CatimeConfig
$cfgMtime   = if ($ConfigFile) { (Get-Item -LiteralPath $ConfigFile).LastWriteTime } else { $null }
$state      = Load-State
$lastToast  = [IntPtr]::Zero
$hintShown  = $false

# 启动时立即写一次，避免 Catime 窗口空白
Save-State $state
if ($cfg.Type -ne 'CATIME') {
    Write-Display 'SET CATIME'
    $hintShown = $true
}
else {
    Refresh-Display $state
}

for ($ti = 0; $ti -lt 240; $ti++) {
    try {
        # 配置热更新：仅当 config.ini 修改时间变化时才重新读取
        if ($ConfigFile) {
            $m = (Get-Item -LiteralPath $ConfigFile).LastWriteTime
            if ($m -ne $cfgMtime) {
                $cfgMtime = $m
                $cfg      = Read-CatimeConfig
            }
        }

        if ($cfg.Type -ne 'CATIME') {
            # 通知类型不是 CATIME 时无法可靠检测阶段完成，显示设置提示
            if (-not $hintShown) {
                Write-Display 'SET CATIME'
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
                Invoke-PhaseComplete $state $cfg.Pattern
            }
            elseif ($h -eq [IntPtr]::Zero) {
                $lastToast = [IntPtr]::Zero
            }
        }
    }
    catch { }
    Start-Sleep -Milliseconds $PollMs
}
