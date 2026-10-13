<#
.SYNOPSIS
    Catime 番茄钟显示插件（pomodoro_dashboard）

.DESCRIPTION
    统计插件（pomodoro_stats）的搭档：弹窗展示统计并可人工校准。

    读取统计插件写在插件根目录的 pomodoro_stats.json：
      展示：今日 / 本周(只读，派生) / 累计 / 近 7 天每日
      编辑：近 7 天每日计数 + 累计（total）；保存后原子写回 json，
            version/phase/lastEvent 原样保留（phase 动了会打乱统计插件索引）
    保存成功后提示用户手动重新运行统计插件使修改生效（v1 无自动拉起）。

    运行期间 output.txt 只写 <catime></catime> 标签（时钟照常显示），
    不再写入 "Dashboard" 等英文提示（用户反馈：时钟字号过大、编辑模式溢出）。

    依赖：Windows 自带 PowerShell 5.1 + .NET Framework WPF，无第三方组件。
    注意：必须以 -STA 启动（launcher 已加）；Catime 同时只跑一个插件，
          从菜单启动本面板会自动停掉统计插件，天然避免写冲突。

.NOTES
    License: Apache-2.0
#>

#requires -version 5.1
param([switch]$SelfTest, [switch]$UiCheck)

$ErrorActionPreference = 'Stop'

# ---------------- 路径 ----------------

$ScriptDir   = $PSScriptRoot
$PluginsRoot = Split-Path $ScriptDir -Parent
$OutputFile  = Join-Path $ScriptDir 'output.txt'

# 数据文件两级候选：插件根目录（默认布局）→ LOCALAPPDATA 绝对兜底
$StateCandidates = @(
    (Join-Path $PluginsRoot 'pomodoro_stats.json'),
    (Join-Path $env:LOCALAPPDATA 'Catime\resources\plugins\pomodoro_stats.json')
)
$StateFile = $StateCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

# ---------------- 基础函数 ----------------

function Write-OutputText {
    param([string]$Text)
    try {
        # Catime 要求 output.txt 为 UTF-8 无 BOM；末尾必须带 <catime></catime>
        [System.IO.File]::WriteAllText($OutputFile, "<fps:1>$Text",
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Read-State {
    # 返回 @{ Ok=$true; Data=json对象 } 或 @{ Ok=$false; Reason='...' }
    # 读取失败重试 2 次（间隔 100ms），应对恰逢统计插件原子写回的瞬间
    if (-not $StateFile) { return @{ Ok = $false; Reason = '未找到统计数据文件 pomodoro_stats.json' } }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($StateFile)
            $j = $raw | ConvertFrom-Json
            return @{ Ok = $true; Data = $j }
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
    return @{ Ok = $false; Reason = '统计数据文件读取/解析失败（可能已损坏）' }
}

function Normalize-Days {
    # 与统计插件同规则：格式合法 + 日历合法 + 非负整数，其余丢弃
    param($Json)
    $d = @{}
    if ($null -eq $Json.days) { return $d }
    foreach ($p in $Json.days.PSObject.Properties) {
        if ($p.Name -match '^\d{4}-\d{2}-\d{2}$') {
            try {
                [datetime]::ParseExact($p.Name, 'yyyy-MM-dd', $null) | Out-Null
                [int]$v = $p.Value
                if ($v -ge 0) { $d[$p.Name] = $v }
            }
            catch { }
        }
    }
    return $d
}

function Get-WeekStart {
    param([datetime]$Date)
    return $Date.Date.AddDays(-((([int]$Date.DayOfWeek) + 6) % 7))
}

function Get-WeekCount {
    param($Days, [datetime]$Today)
    $ws = Get-WeekStart $Today
    $n = 0
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

function Save-State {
    # 原子写：临时文件 + Move -Force；version/phase/lastEvent 原样带回
    param($Json, $NewDays, [int]$NewTotal)
    $obj = [ordered]@{
        version   = $Json.version
        total     = $NewTotal
        phase     = $Json.phase
        lastEvent = $Json.lastEvent
        days      = $NewDays
    }
    $json = $obj | ConvertTo-Json -Depth 5 -Compress
    $tmp  = "$StateFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

# ---------------- SelfTest（无头自检，不弹窗） ----------------

if ($SelfTest) {
    $r = Read-State
    if (-not $r.Ok) { Write-Output ("SELFTEST: NODATA - " + $r.Reason); exit 0 }
    $j    = $r.Data
    $days = Normalize-Days $j
    $now  = Get-Date
    $todayKey = $now.ToString('yyyy-MM-dd')
    $today = 0
    if ($days.ContainsKey($todayKey)) { $today = $days[$todayKey] }
    $week = Get-WeekCount $days $now
    $total = 0
    try { $total = [int]$j.total } catch { }
    Write-Output ("SELFTEST: today={0} week={1} total={2}" -f $today, $week, $total)
    for ($i = 0; $i -lt 7; $i++) {
        $dk = $now.Date.AddDays(-$i).ToString('yyyy-MM-dd')
        $c = 0
        if ($days.ContainsKey($dk)) { $c = $days[$dk] }
        Write-Output ("  {0} = {1}" -f $dk, $c)
    }
    exit 0
}

# ---------------- WPF 面板（浅色卡片风，固定配色） ----------------

Add-Type -AssemblyName PresentationFramework

$state = Read-State
$haveData = $state.Ok
$j    = $null
$days = @{}
if ($haveData) { $j = $state.Data; $days = Normalize-Days $j }
$now = Get-Date
$todayKey = $now.ToString('yyyy-MM-dd')

$weekCn = @('周日','周一','周二','周三','周四','周五','周六')

# 运行期间时钟只保留标签：不再向时钟写 "Dashboard" 等英文
# （用户反馈：时钟字号渲染过大、编辑模式下时钟组件增高溢出屏幕）
Write-OutputText '<catime></catime>'

# XAML：浅色卡片风（暖白底 + 白卡片 + 细边框），固定配色，宽 560 近正方形
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pomodoro Dashboard" Width="520" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" FontFamily="Microsoft YaHei UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#89F7FE" Offset="0"/>
      <GradientStop Color="#66A6FF" Offset="1"/>
    </LinearGradientBrush>
    <!-- 番茄图标：TDesign tomato（MIT，24x24 线性描边，SVG path 直转 XAML，零依赖）
         果身红 / 蒂叶绿 / 外轮廓红（原 SVG 的 stem path 拆为蒂叶+外轮廓两段分别着色） -->
    <PathGeometry x:Key="TomatoBody" Figures="M12 5.514s2.556-.763 4-.338c2.817.828 4.998 2.822 5 7.324s-3.982 9.248-7.557 8.4c-.902-.214-.867-.299-1.443-.299s-.541.085-1.443.3C7 21.743 3 16.996 3 12.5S5.113 6 8 5.175c1.447-.414 4 .338 4 .338"/>
    <PathGeometry x:Key="TomatoLeaf" Figures="M9.5 3L12 5.513L14.69 3m.959 2.687l-.352.512c-1.589 2.314-5.005 2.314-6.594 0l-.352-.512"/>
    <PathGeometry x:Key="TomatoOutline" Figures="M12 5.514s-2.553-.752-4-.338C5.113 6 3 8.004 3 12.5s4 9.244 7.557 8.4c.902-.214.867-.299 1.443-.299s.541.085 1.443.3c3.575.847 7.56-3.899 7.557-8.4c-.002-4.503-2.183-6.497-5-7.325c-1.444-.425-4 .338-4 .338Z"/>
    <Style x:Key="NumBox" TargetType="TextBox">
      <Setter Property="Width" Value="68"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#2F2F2C"/>
      <Setter Property="BorderBrush" Value="#E3DFD6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="4,0"/>
    </Style>
    <Style x:Key="DayLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#55524B"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#ECE8E0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#2F2F2C"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Width" Value="150"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="8" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#55524B"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Width" Value="90"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="#E3DFD6" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PillTab" TargetType="TabItem">
      <Setter Property="Foreground" Value="#9A968C"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder" CornerRadius="8" Padding="16,7"
                    Background="Transparent" BorderBrush="Transparent" BorderThickness="1">
              <ContentPresenter ContentSource="Header"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#F0EDE7"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#FFFFFF"/>
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="#ECE8E0"/>
                <Setter Property="Foreground" Value="#2F2F2C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="12" Background="#F7F5F0" BorderBrush="#E7E2D9" BorderThickness="1">
    <StackPanel Margin="22,0,22,14">
      <!-- 标题栏（可拖动） -->
      <Border x:Name="TitleBar" Background="Transparent" Margin="-22,0,-22,12" Padding="22,12">
        <Grid>
          <StackPanel>
            <TextBlock Text="Pomodoro Dashboard" FontSize="15" FontWeight="Bold"
                       Foreground="#2F2F2C"/>
            <Rectangle Height="3" Width="46" RadiusX="1.5" RadiusY="1.5"
                       Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,5,0,0"/>
          </StackPanel>
          <Button x:Name="CloseBtn" Content="&#10005;" Width="28" Height="28"
                  HorizontalAlignment="Right" VerticalAlignment="Top"
                  Background="Transparent" BorderThickness="0" Foreground="#9A968C"
                  FontSize="12" Cursor="Hand"/>
        </Grid>
      </Border>
      <!-- 标签页：概览 / 热力图（V2） -->
      <TabControl x:Name="MainTabs" Background="Transparent" BorderThickness="0" Margin="0,2,0,0">
        <TabItem Header="概览" Style="{StaticResource PillTab}">
        <StackPanel>
      <!-- 概览卡片 -->
      <UniformGrid Columns="4">
        <Border Style="{StaticResource Card}" Margin="0,0,5,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="今日" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="TodayCard" Text="0" Foreground="#2F2F2C" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <Grid Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Path Fill="#D94848" Stretch="Uniform" Data="{StaticResource TomatoBody}"/>
                <Path Stroke="#D94848" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoOutline}"/>
                <Path Stroke="#5FA85B" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoLeaf}"/>
              </Grid>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="5,0,5,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="本周" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="WeekCard" Text="0" Foreground="#4A90D9" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <Grid Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Path Fill="#D94848" Stretch="Uniform" Data="{StaticResource TomatoBody}"/>
                <Path Stroke="#D94848" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoOutline}"/>
                <Path Stroke="#5FA85B" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoLeaf}"/>
              </Grid>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="5,0,5,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="本月" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="MonthCard" Text="0" Foreground="#4A90D9" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <Grid Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Path Fill="#D94848" Stretch="Uniform" Data="{StaticResource TomatoBody}"/>
                <Path Stroke="#D94848" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoOutline}"/>
                <Path Stroke="#5FA85B" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoLeaf}"/>
              </Grid>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="5,0,0,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="累计" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="TotalCard" Text="0" Foreground="#2F2F2C" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <Grid Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Path Fill="#D94848" Stretch="Uniform" Data="{StaticResource TomatoBody}"/>
                <Path Stroke="#D94848" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoOutline}"/>
                <Path Stroke="#5FA85B" StrokeThickness="2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                      Stretch="Uniform" Data="{StaticResource TomatoLeaf}"/>
              </Grid>
            </StackPanel>
          </StackPanel>
        </Border>
      </UniformGrid>
      <!-- 提示 -->
      <TextBlock x:Name="HintText" Foreground="#9A968C" FontSize="11" Margin="2,10,0,2"
                 TextWrapping="Wrap"
                 Text="校准前请先停止统计插件（从 Catime 菜单启动本面板会自动停止）。"/>
      <!-- 近 7 天 -->
      <TextBlock Text="近 7 天" Foreground="#2F2F2C" FontSize="13"
                 FontWeight="Bold" Margin="2,4,0,6"/>
      <StackPanel x:Name="DayRows"/>
      <!-- 按钮：默认隐藏，编辑任意数字后出现 -->
      <StackPanel x:Name="BtnRow" Orientation="Horizontal" HorizontalAlignment="Center"
                  Visibility="Collapsed">
        <Button x:Name="SaveBtn" Content="保存" Style="{StaticResource PrimaryBtn}" Margin="0,0,10,0"/>
        <Button x:Name="CancelBtn" Content="取消" Style="{StaticResource GhostBtn}"/>
      </StackPanel>
      <!-- 状态栏 -->
      <TextBlock x:Name="StatusText" Foreground="#9A968C" FontSize="12" Margin="2,8,0,0"
                 TextWrapping="Wrap" Text=""/>
      <!-- 底部统一提示 -->
      <TextBlock Text="单击数字可人工校准数量" Foreground="#B3AEA4" FontSize="11"
                 HorizontalAlignment="Center" Margin="0,10,0,0"/>
        </StackPanel>
        </TabItem>
        <TabItem Header="热力图" Style="{StaticResource PillTab}">
          <StackPanel Margin="0,10,0,0">
            <TextBlock Text="近 12 周每日完成度" Foreground="#2F2F2C" FontSize="13"
                       FontWeight="Bold" Margin="2,0,0,8"/>
            <Grid x:Name="HeatGrid"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
              <TextBlock Text="少" Foreground="#9A968C" FontSize="11" VerticalAlignment="Center"/>
              <Rectangle Width="110" Height="6" RadiusX="3" RadiusY="3" Margin="8,0">
                <Rectangle.Fill>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#2666A6FF" Offset="0"/>
                    <GradientStop Color="#66A6FF" Offset="1"/>
                  </LinearGradientBrush>
                </Rectangle.Fill>
              </Rectangle>
              <TextBlock Text="多" Foreground="#9A968C" FontSize="11" VerticalAlignment="Center"/>
              <TextBlock x:Name="HeatLegendNote" Text="" Foreground="#B3AEA4" FontSize="11"
                         VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <TextBlock Text="格子颜色越深表示当日完成越多；悬停可查看具体数值" Foreground="#B3AEA4"
                       FontSize="11" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          </StackPanel>
        </TabItem>
      </TabControl>
    </StackPanel>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

$TitleBar  = $window.FindName('TitleBar')
$CloseBtn  = $window.FindName('CloseBtn')
$TodayCard = $window.FindName('TodayCard')
$WeekCard  = $window.FindName('WeekCard')
$TotalCard = $window.FindName('TotalCard')
$MonthCard = $window.FindName('MonthCard')
$HintText  = $window.FindName('HintText')
$DayRows   = $window.FindName('DayRows')
$BtnRow    = $window.FindName('BtnRow')
$SaveBtn   = $window.FindName('SaveBtn')
$CancelBtn = $window.FindName('CancelBtn')
$StatusText = $window.FindName('StatusText')

$conv = [System.Windows.Media.BrushConverter]::new()
$script:SuppressEditEvent = $true   # 初始填充不触发"已编辑"显隐

# ---- 生成 7 天编辑行（今天在最上） ----
$DayBoxes = @{}   # 日期键 -> TextBox
for ($i = 0; $i -lt 7; $i++) {
    $dt = $now.Date.AddDays(-$i)
    $dk = $dt.ToString('yyyy-MM-dd')
    $c = 0
    if ($days.ContainsKey($dk)) { $c = $days[$dk] }

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Style = $window.Resources['DayLabel']
    $name = $dt.ToString('MM-dd') + ' ' + $weekCn[[int]$dt.DayOfWeek]
    if ($i -eq 0) { $name += '（今天）' }
    $lbl.Text = $name

    $box = New-Object System.Windows.Controls.TextBox
    $box.Style = $window.Resources['NumBox']
    $box.Text = [string]$c
    $DayBoxes[$dk] = $box

    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.Resources['Card']
    $card.Padding = [System.Windows.Thickness]::new(10, 5, 10, 5)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.Children.Add($lbl)
    [void]$grid.Children.Add($box)
    $card.Child = $grid
    $DayRows.Children.Add($card) | Out-Null
}

# ---- 数据填充 / 无数据降级 ----
function Update-Cards {
    $t = 0
    if ($days.ContainsKey($todayKey)) { $t = $days[$todayKey] }
    $TodayCard.Text = [string]$t
    $WeekCard.Text  = [string](Get-WeekCount $days $now)
    $MonthCard.Text = [string](Get-MonthCount $days $now)
    # 累计改为派生：= 全部每日明细合计（保存时同步重写 json.total，
    # 与统计插件显示保持一致；不再提供独立编辑入口，避免手工改数后对不上）
    $sum = 0
    foreach ($v in $days.Values) { $sum += $v }
    $TotalCard.Text = [string]$sum
}

function Get-Snapshot {
    # 当前界面值的快照（供"取消"还原）
    $snap = @{}
    foreach ($e in $DayBoxes.GetEnumerator()) { $snap[$e.Key] = $e.Value.Text }
    return $snap
}

function Apply-Snapshot($snap) {
    $script:SuppressEditEvent = $true
    foreach ($e in $DayBoxes.GetEnumerator()) {
        if ($snap.ContainsKey($e.Key)) { $e.Value.Text = $snap[$e.Key] }
    }
    $script:SuppressEditEvent = $false
}

if ($haveData) {
    Update-Cards
}
else {
    $HintText.Text = $state.Reason + '。请先运行统计插件（pomodoro_stats_launcher）生成数据。'
    $HintText.Foreground = $conv.ConvertFromString('#D9534F')
    foreach ($b in $DayBoxes.Values) { $b.IsEnabled = $false }
}
$script:Snapshot = Get-Snapshot
$script:SuppressEditEvent = $false

# ---- 事件 ----
$TitleBar.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch { }
})

$CloseBtn.Add_Click({ $window.Close() })

# 编辑任意数字后按钮才出现
foreach ($b in $DayBoxes.Values) {
    $b.Add_TextChanged({
        if (-not $script:SuppressEditEvent) { $BtnRow.Visibility = 'Visible' }
    })
}

# 取消：还原到最近一次保存的值，按钮收起
$CancelBtn.Add_Click({
    Apply-Snapshot $script:Snapshot
    $BtnRow.Visibility = 'Collapsed'
    $StatusText.Text = ''
})

$SaveBtn.Add_Click({
    # 校验：每日数值均为非负整数
    $vals = @{}
    $bad = $false
    $normalBrush = $conv.ConvertFromString('#E3DFD6')
    $badBrush    = $conv.ConvertFromString('#D9534F')
    foreach ($e in $DayBoxes.GetEnumerator()) {
        $t = $e.Value.Text.Trim()
        if ($t -match '^\d+$') { $vals[$e.Key] = [int]$t; $e.Value.BorderBrush = $normalBrush }
        else { $e.Value.BorderBrush = $badBrush; $bad = $true }
    }

    if ($bad) {
        $StatusText.Text = '有非法输入（需为非负整数），未保存。'
        $StatusText.Foreground = $badBrush
        return
    }

    try {
        # 合并：仅替换近 7 天，其余历史日期原样保留
        $newDays = [hashtable]$days.Clone()
        foreach ($e in $vals.GetEnumerator()) { $newDays[$e.Key] = $e.Value }
        # 累计 = 全部明细合计（与统计插件计数口径天然一致，杜绝手工改数后对不上）
        $newTotal = 0
        foreach ($v in $newDays.Values) { $newTotal += $v }
        Save-State $j $newDays $newTotal
        $script:days = $newDays
        try { $script:j.total = $newTotal } catch { }

        Update-Cards
        Update-Heatmap   # 热力图跟着校准结果刷新（用户实测：保存后格子不更新）
        $script:Snapshot = Get-Snapshot
        $BtnRow.Visibility = 'Collapsed'
        $StatusText.Foreground = $conv.ConvertFromString('#2E9E63')
        $StatusText.Text = ('已保存。累计已按每日明细自动对账为 {0}。请手动重新运行统计插件（pomodoro_stats_launcher）使修改生效。' -f $newTotal)
    }
    catch {
        $StatusText.Text = '保存失败：' + $_.Exception.Message
        $StatusText.Foreground = $conv.ConvertFromString('#D9534F')
    }
})

# ---- 热力图（V2：近 12 周打卡图，行=周一..周日，列=周，颜色深浅映射当日完成数） ----
$HeatGrid = $window.FindName('HeatGrid')
$HeatLegendNote = $window.FindName('HeatLegendNote')

function Build-Heatmap {
    param($Days, [datetime]$Now)

    $g = New-Object System.Windows.Controls.Grid

    # 列：0=星期标签列，1..12=周；行：0=月份标签行，1..7=周一..周日
    $col0 = [System.Windows.Controls.ColumnDefinition]::new()
    $col0.Width = [System.Windows.GridLength]::new(24)
    [void]$g.ColumnDefinitions.Add($col0)
    for ($c = 0; $c -lt 12; $c++) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $r0 = [System.Windows.Controls.RowDefinition]::new()
    $r0.Height = [System.Windows.GridLength]::new(16)
    [void]$g.RowDefinitions.Add($r0)
    for ($r = 0; $r -lt 7; $r++) {
        $rd = [System.Windows.Controls.RowDefinition]::new()
        $rd.Height = [System.Windows.GridLength]::new(22)
        [void]$g.RowDefinitions.Add($rd)
    }

    # 先求窗口内最大值（透明度映射基准），避免历史单日极值压淡近期数据
    $curWeek = Get-WeekStart $Now
    $max = 1
    for ($c = 0; $c -lt 12; $c++) {
        $ws = $curWeek.AddDays(-7 * (11 - $c))
        for ($r = 0; $r -lt 7; $r++) {
            $dk = $ws.AddDays($r).ToString('yyyy-MM-dd')
            if ($Days.ContainsKey($dk) -and $Days[$dk] -gt $max) { $max = $Days[$dk] }
        }
    }
    $script:HeatMax = $max

    $convH    = [System.Windows.Media.BrushConverter]::new()
    $accent   = $convH.ConvertFromString('#66A6FF')
    $emptyBg  = $convH.ConvertFromString('#EFEDE8')
    $futureBg = $convH.ConvertFromString('#F4F2EC')
    $wd = @('一','二','三','四','五','六','日')

    for ($r = 0; $r -lt 7; $r++) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $wd[$r]
        $lbl.FontSize = 10
        $lbl.Foreground = $convH.ConvertFromString('#B3AEA4')
        $lbl.HorizontalAlignment = 'Center'
        $lbl.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        [System.Windows.Controls.Grid]::SetRow($lbl, $r + 1)
        [void]$g.Children.Add($lbl)
    }

    $prevMonth = -1
    for ($c = 0; $c -lt 12; $c++) {
        $ws = $curWeek.AddDays(-7 * (11 - $c))
        if ($ws.Month -ne $prevMonth) {
            $ml = New-Object System.Windows.Controls.TextBlock
            $ml.Text = $ws.ToString('M月')
            $ml.FontSize = 10
            $ml.Foreground = $convH.ConvertFromString('#9A968C')
            $ml.HorizontalAlignment = 'Left'
            [System.Windows.Controls.Grid]::SetColumn($ml, $c + 1)
            [System.Windows.Controls.Grid]::SetRow($ml, 0)
            [void]$g.Children.Add($ml)
            $prevMonth = $ws.Month
        }
        for ($r = 0; $r -lt 7; $r++) {
            $d = $ws.AddDays($r)
            $dk = $d.ToString('yyyy-MM-dd')
            $future = $d -gt $Now.Date
            $count = 0
            if ($Days.ContainsKey($dk)) { $count = $Days[$dk] }

            $cell = New-Object System.Windows.Controls.Border
            $cell.CornerRadius = [System.Windows.CornerRadius]::new(3)
            if ($future) {
                $cell.Background = $futureBg
            }
            elseif ($count -le 0) {
                $cell.Background = $emptyBg
            }
            else {
                $b = $accent.Clone()
                $b.Opacity = 0.25 + 0.75 * ($count / $max)
                $cell.Background = $b
                $cell.ToolTip = ('{0} 周{1}：{2} 个' -f $d.ToString('MM-dd'), $wd[$r], $count)
            }
            $cell.Margin = [System.Windows.Thickness]::new(1)
            # 格子中间写日期（日），淡灰半透明字体
            $num = New-Object System.Windows.Controls.TextBlock
            $num.Text = [string]$d.Day
            $num.FontSize = 9
            $num.Foreground = $convH.ConvertFromString('#8A8578')
            $num.Opacity = 0.55
            $num.HorizontalAlignment = 'Center'
            $num.VerticalAlignment = 'Center'
            $cell.Child = $num
            [System.Windows.Controls.Grid]::SetColumn($cell, $c + 1)
            [System.Windows.Controls.Grid]::SetRow($cell, $r + 1)
            [void]$g.Children.Add($cell)
        }
    }
    return $g
}

function Update-Heatmap {
    # 重建热力图（保存校准后必须调用，否则格子还是旧数据）
    $HeatGrid.Children.Clear()
    [void]$HeatGrid.Children.Add((Build-Heatmap $days $now))
    # 相对色阶的绝对上下文：图例标注当前窗口峰值
    $HeatLegendNote.Text = ('最深 = 当日 {0} 个' -f $script:HeatMax)
}

if ($haveData) { Update-Heatmap }

# ---- 无头 UI 自检：解析 XAML + 查找命名控件 + 构建热力图，不显示窗口 ----
# 用途：SelfTest 覆盖不了 XAML/热力图构建，此前该段一旦报错只会"进程静默死亡、
# 用户看不到弹窗"。UiCheck 把这段变成可确定性验证的检查（check_dashboard.py E10）。
if ($UiCheck) {
    $probe = Build-Heatmap $days $now
    $missing = @()
    foreach ($n in @('TitleBar','CloseBtn','TodayCard','WeekCard','MonthCard','TotalCard',
                     'HintText','DayRows','BtnRow','SaveBtn','CancelBtn','StatusText',
                     'HeatGrid','MainTabs')) {
        if ($null -eq $window.FindName($n)) { $missing += $n }
    }
    Write-Output ("UICHECK: OK heatmap_children={0} missing={1}" -f $probe.Children.Count, ($missing -join ','))
    exit 0
}

[void]$window.ShowDialog()
