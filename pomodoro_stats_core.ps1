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
$PluginAnchor  = 'keep'
$AnchorMarginX = 0
$AnchorMarginY = 0

# 显示布局：
#   'stacked' = 两行：第一行小字统计，第二行大字计时（用 markdown 标题字号分级实现：
#               ###### = 基准×0.9， # = 基准×1.5）
#   'single'  = 单行：统计 + 计时排在同一行
$DisplayLayout = 'stacked'

# 说明：空闲时钟完全交给 Catime——<catime></catime> 标签处由 Catime 渲染当前计时/时间，
# 插件不自写时间（自写会与 Catime 自带"当前时间"重复显示，此功能已移除）。

# 统计行是否渲染成图片：
#   $false = 普通文字（受 Catime 字号档位限制：统计最小只能到计时的 60%）
#   $true  = 由插件画成 PNG 贴在计时上方（可任意小、行距可压到很紧；
#            字体与配色自动跟随 Catime 当前设置；仅在计数变化时重绘一次，开销极小）
$StatsAsImage     = $true
$StatsImageScreenPx = 27  # 统计行在**屏幕上**的字号（像素）；原文字版约 54px，27 ≈ 一半

# 计时期间的显示：
#   'both'  = 始终显示"统计 + 计时"（推荐：番茄钟每一段都能同时看到计时）
#   'timer' = 推断正在计时时只显示计时，其余时间显示统计
#             ⚠ Catime 不提供"计时开始"信号（开始计时不写配置文件、不新建窗口、无 IPC），
#             所以每轮第 1 段无法切换，且手动中断后统计要等该段预期结束才恢复
$TimerDisplayMode = 'both'

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

# 插件版本号（写入启动日志，便于确认运行的代码版本）
$PluginVersion = 'v0.19'

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
Add-Type -Namespace PomStat -Name Win -ReferencedAssemblies System.Drawing -MemberDefinition @'
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
// 窗口"指纹"：包含位置与尺寸，位置或尺寸一变就重新贴角（Catime 有时会把位置重置回配置值）
public static long GetWindowSignature(IntPtr hWnd) {
    RECT r;
    if (!GetWindowRect(hWnd, out r)) { return 0; }
    long sig = (r.Right - r.Left) * 100003 + (r.Bottom - r.Top);
    sig = sig * 100003 + r.Left;
    sig = sig * 100003 + r.Top;
    return sig;
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
// 把一行文字渲染成透明 PNG（字体与配色跟随 Catime 当前设置），返回 "宽x高"，失败返回 ""
public static string RenderStatsImage(string text, string fontPath, string colorSpec, int fontPx, string outPath) {
    System.Drawing.Text.PrivateFontCollection pfc = new System.Drawing.Text.PrivateFontCollection();
    try {
        if (!string.IsNullOrEmpty(fontPath) && System.IO.File.Exists(fontPath)) { pfc.AddFontFile(fontPath); }
        System.Drawing.FontFamily fam = (pfc.Families.Length > 0) ? pfc.Families[0]
                                          : System.Drawing.FontFamily.GenericSansSerif;
        System.Drawing.Color c1 = System.Drawing.Color.White, c2 = System.Drawing.Color.White;
        bool g1 = TryParseHexColor(colorSpec, 0, out c1);
        bool g2 = TryParseHexColor(colorSpec, 1, out c2);
        if (!g1) { c1 = System.Drawing.Color.White; }
        if (!g2) { c2 = c1; }
        using (System.Drawing.Font font = new System.Drawing.Font(fam, (float)fontPx,
                   System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Pixel))
        using (System.Drawing.Bitmap probe = new System.Drawing.Bitmap(4, 4))
        using (System.Drawing.Graphics gp = System.Drawing.Graphics.FromImage(probe)) {
            System.Drawing.StringFormat sf = System.Drawing.StringFormat.GenericTypographic;
            sf.FormatFlags |= System.Drawing.StringFormatFlags.MeasureTrailingSpaces;
            System.Drawing.SizeF sz = gp.MeasureString(text, font, new System.Drawing.PointF(0f, 0f), sf);
            int w = (int)System.Math.Ceiling(sz.Width) + 4;
            int h = (int)System.Math.Ceiling(sz.Height) + 4;
            if (w < 8) { w = 8; }
            if (h < 8) { h = 8; }
            using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(w, h,
                       System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using (System.Drawing.Brush br = (c1 == c2)
                           ? (System.Drawing.Brush)new System.Drawing.SolidBrush(c1)
                           : (System.Drawing.Brush)new System.Drawing.Drawing2D.LinearGradientBrush(
                                 new System.Drawing.Rectangle(0, 0, w, h), c1, c2, 0f)) {
                    g.DrawString(text, font, br, 2f, 2f, sf);
                }
                bmp.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
            }
            return w.ToString() + "x" + h.ToString();
        }
    }
    catch (System.Exception) { return ""; }
    finally { pfc.Dispose(); }
}
// 解析形如 "#89F7FE_#66A6FF" 的第 idx 段颜色（0 或 1）
private static bool TryParseHexColor(string spec, int idx, out System.Drawing.Color c) {
    c = System.Drawing.Color.White;
    if (string.IsNullOrEmpty(spec)) { return false; }
    string[] parts = spec.Split('_');
    if (idx >= parts.Length) { return false; }
    string t = parts[idx].Trim();
    if (t.Length < 7 || t[0] != '#') { return false; }
    try {
        int r = System.Convert.ToInt32(t.Substring(1, 2), 16);
        int g = System.Convert.ToInt32(t.Substring(3, 2), 16);
        int b = System.Convert.ToInt32(t.Substring(5, 2), 16);
        c = System.Drawing.Color.FromArgb(255, r, g, b);
        return true;
    }
    catch (System.Exception) { return false; }
}
'@

# ---------------- 配置读取 ----------------

function Read-CatimeConfig {
    <#
      读取 Catime config.ini，返回:
        @{ Type = 'CATIME'|'OS'|'SYSTEM_MODAL'; Pattern = @(工作秒,休息秒,...) }
      读取失败时返回默认值（与 Catime 内置默认一致）。
    #>
    $result = @{ Type = 'CATIME'; Pattern = @(1500, 300, 1500, 600); LoopCount = 1
                 FontFile = ''; TextColor = ''; PluginScale = 1.0 }
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
            elseif ($section -eq 'Display' -and $key -eq 'FONT_FILE_NAME' -and $val) {
                # 供"统计行图片"使用：与时钟保持同一字体
                $fp = [System.Environment]::ExpandEnvironmentVariables($val)
                if (-not [System.IO.Path]::IsPathRooted($fp)) { $fp = Join-Path $CatimeRoot $fp }
                $result.FontFile = $fp
            }
            elseif ($section -eq 'Display' -and $key -eq 'CLOCK_TEXT_COLOR' -and $val) {
                # 供"统计行图片"使用：与时钟保持同一配色
                $result.TextColor = $val
            }
            elseif ($section -eq 'Display' -and $key -eq 'PLUGIN_SCALE' -and $val) {
                # 图片会被 Catime 按此缩放放大，输出尺寸要除回去才能 1:1 显示
                $sc = 0.0
                if ([double]::TryParse($val, [ref]$sc) -and $sc -gt 0) { $result.PluginScale = $sc }
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
                # 既要格式合法，也要日历合法：2026-02-30 这类"格式对、日期错"的脏键
                # 若放进来，会让后续的 Get-WeekCount/Get-MonthCount 每次刷新都 ParseExact 抛异常，
                # 因此在此直接丢弃（同时要求值为可转 int 的正整数）。
                if ($p.Name -match '^\d{4}-\d{2}-\d{2}$') {
                    try {
                        [datetime]::ParseExact($p.Name, 'yyyy-MM-dd', $null) | Out-Null
                        [int]$v = $p.Value
                        if ($v -ge 0) { $d[$p.Name] = $v }
                    }
                    catch { }
                }
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
        # 清理 400 天以前的明细，保持状态文件精简。
        # 个别被手动改坏的日期键（如 2026-02-30，格式合法但日历不合法）
        # 会让 ParseExact 抛异常；此处逐键容错，单个坏键跳过即可，
        # 避免"一颗坏键导致整次 Save 中断、计数永久写不进磁盘"。
        $cutoff = (Get-Date).Date.AddDays(-400)
        $stale = @()
        foreach ($k in $State.days.Keys) {
            try {
                if ([datetime]::ParseExact($k, 'yyyy-MM-dd', $null) -lt $cutoff) { $stale += $k }
            }
            catch { }
        }
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

function Update-StatsImage {
    <# 把统计行渲染成 PNG；内容/字体/配色未变时复用上次结果（不重复绘制） #>
    param([string]$Text, $Cfg)

    if (-not $StatsAsImage) { return '' }
    # 缩放必须参与缓存键：用户在插件模式缩放时钟时 Catime 会写回 PLUGIN_SCALE，
    # 显示尺寸 = spec × 当前缩放。缩放一变就用新缩放重算 spec，
    # 图片才能保持固定屏幕大小（$StatsImageScreenPx），不随时钟缩放漂移。
    $key = ('{0}|{1}|{2}|{3}|{4}' -f $Text, $Cfg.FontFile, $Cfg.TextColor,
                $StatsImageScreenPx, $Cfg.PluginScale)
    if ($script:StatsImgKey -eq $key -and $script:StatsImgSize -and $script:StatsImgName -and
        (Test-Path -LiteralPath (Join-Path $ScriptDir $script:StatsImgName))) {
        return $script:StatsImgSize
    }

    $size = ''
    $usedName = ''
    # Catime 加载图片后会一直占用文件句柄（实测永久锁），因此每次用一个新文件名；
    # 同时尽力清理旧图（被占用的删不掉，留给下次 Catime 重启后由本函数清掉）
    $stamp = (Get-Date).ToString('HHmmss') + ([int](Get-Random -Maximum 99)).ToString('00')
    foreach ($name in @(('stats_{0}.png' -f $stamp), ('stats_{0}b.png' -f $stamp))) {
        $path = Join-Path $ScriptDir $name
        $r = ''
        try {
            $r = [PomStat.Win]::RenderStatsImage($Text, [string]$Cfg.FontFile,
                        [string]$Cfg.TextColor, [int]$StatsImageScreenPx, $path)
        }
        catch { $r = '' }
        if ($r) { $size = $r; $usedName = $name; break }
    }
    if ($usedName) {
        try {
            Get-ChildItem -LiteralPath $ScriptDir -Filter 'stats*.png' |
                Where-Object { $_.Name -ne $usedName } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    if (-not $size) {
        Write-Log '统计行图片生成失败，本次回退为文字显示'
        $script:StatsImgKey = ''
        $script:StatsImgSize = ''
        return ''
    }

    # Catime 会把图片按 PLUGIN_SCALE 放大，所以输出尺寸要除以它，才能 1:1 清晰显示
    $sc = [double]$Cfg.PluginScale
    if ($sc -le 0) { $sc = 1.0 }
    $spec = ''
    try {
        $wh = $size.Split('x')
        $sw = [int][math]::Max(1, [math]::Round(([double]$wh[0]) / $sc))
        $sh = [int][math]::Max(1, [math]::Round(([double]$wh[1]) / $sc))
        $spec = '{0}x{1}' -f $sw, $sh
    }
    catch { $spec = $size }

    $script:StatsImgKey  = $key
    $script:StatsImgSize = $spec
    $script:StatsImgName = $usedName
    return $spec
}

function Refresh-Display {
    param($State)
    $timerOnly = ($TimerDisplayMode -eq 'timer') -and ($script:TimerEndsAt -ne $null) -and
                 ((Get-Date) -lt $script:TimerEndsAt)

    if ($timerOnly) {
        if ($DisplayLayout -eq 'stacked') { Write-Display '<catime></catime>' }
        else { Write-Display '<catime></catime>' }
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
    $line = $parts -join ' '

    if ($DisplayLayout -eq 'stacked') {
        # 优先用图片渲染统计行（可任意小、行距可贴近）；失败则回退到 markdown 标题分级
        $img = Update-StatsImage $line $cfg
        $zwsp = [string][char]0x200B   # 零宽空格：分隔图片与后续内容（不可见）
        # 计时只保留标签：Catime 在 <catime></catime> 处渲染当前计时/时间，
        # 空闲时钟由 Catime 自己管理，插件不自写（避免与"当前时间"重复）。
        # 标签始终保留（缺了会被 Catime 杀掉）。
        # 图片与标签必须**同一行**：分行时第二行行高仅按字号算（20px），
        # 而图片高 38px，会把时间文字压在图片上（用户实测重叠）。
        $timerLine = '<catime></catime>'
        if ($img) {
            Write-Display ("<md>![{0}]({1}){2}</md>{3}" -f $img, $script:StatsImgName, $zwsp, $timerLine)
        }
        else {
            Write-Display ("<md>###### {0}{1}</md>{2}" -f $line, $zwsp, $timerLine)
        }
    }
    else {
        Write-Display ($line + $CatimeTag)
    }
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
            # 用间隔匹配阶段时长（容忍暂停造成的偏差），实现阶段索引自纠正。
            # 容差随段长缩放、下限 2 秒（覆盖检测抖动）：原来的固定 60s 下限
            # 在小段长测试序列（如 5,10,5）下会让任何间隔都命中所有段，
            # 把工作段误判成休息段导致漏计；匹配失败时回退顺序索引，行为正确。
            for ($i = 0; $i -lt $n; $i++) {
                $tol = [math]::Max(2, $Pattern[$i] * 0.15)
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

Write-Log ("启动: 版本={0} PS={1} 配置={2} 类型={3} 阶段序列={4}" -f `
    $PluginVersion, $PSVersionTable.PSVersion, $ConfigFile, $cfg.Type, ($cfg.Pattern -join ','))
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
                # 缩放变化会写回 config.ini 触发本分支：必须立即重算统计行 spec，
                # 否则图片要等下一次计数才恢复固定大小（v0.18 用户实测问题）
                if ($cfg.Type -eq 'CATIME' -and -not $hintShown) {
                    Refresh-Display $state
                }
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
