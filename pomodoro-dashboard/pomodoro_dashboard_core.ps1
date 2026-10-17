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
param([switch]$SelfTest, [switch]$UiCheck, [int]$RenderTab = -1, [int]$RenderGran = -1, [int]$RenderPeriod = -1)

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
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#55524B"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="#E3DFD6" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LightCombo" TargetType="ComboBox">
      <Setter Property="Height" Value="28"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#2F2F2C"/>
      <Setter Property="Padding" Value="10,0,26,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="ComboBg" CornerRadius="6" Background="{TemplateBinding Background}"
                      BorderBrush="#E3DFD6" BorderThickness="1"/>
              <ToggleButton x:Name="ComboArrow" Focusable="False"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay,
                                        RelativeSource={RelativeSource TemplatedParent}}"
                            HorizontalAlignment="Right" Width="24">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path Data="M 0 0 L 4 4.5 L 8 0 Z" Fill="#8A8578"
                            HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ComboText" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
              <Popup x:Name="ComboPopup" Placement="Bottom" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Slide"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border CornerRadius="6" Background="#FFFFFF" BorderBrush="#E3DFD6"
                        BorderThickness="1" MaxHeight="220" Margin="0,2,0,0">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
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
    <!-- TabControl 干净模板：去掉默认模板的选中连接铬边（它把选中标签右边缘画成
         直线），保留标签条与内容区间距，观感贴近默认布局 -->
    <Style x:Key="CleanTabControl" TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid Background="{TemplateBinding Background}">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TabPanel Grid.Row="0" IsItemsHost="True" Background="Transparent" Margin="0,0,0,10"/>
              <ContentPresenter Grid.Row="1" ContentSource="SelectedContent"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  <!-- 悬停提示：圆角白卡（去掉系统默认黄框与阴影），配合下方 SetInitialShowDelay=0 实现即现 -->
    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="#2F2F2C"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border CornerRadius="6" Background="#FFFFFF" BorderBrush="#E3DFD6"
                    BorderThickness="1" Padding="8,5">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 下拉项：悬停/选中圆角块（默认 WPF 高亮是方角蓝框，与卡片圆角语言不统一） -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Foreground" Value="#2F2F2C"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBg" CornerRadius="4" Background="Transparent" Margin="4,1">
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBg" Property="Background" Value="#E8F2FC"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBg" Property="Background" Value="#D2E7FB"/>
                <Setter Property="Foreground" Value="#1F6BB8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 圆角滚动条（下拉列表用；默认 WPF 滚动条是方角+箭头）。
         注意 Track 的 Decrease/Increase 按钮必须保留（Opacity=0 隐藏但可点），
         否则点击轨道空白处翻页与拖动滑块都会失效 -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinHeight" Value="24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton>
                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageUpCommand" Focusable="False" Opacity="0"/>
              </Track.DecreaseRepeatButton>
              <Track.Thumb>
                <Thumb x:Name="Thumb" Cursor="Hand" Margin="2,1">
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="#C9C3B6"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
              <Track.IncreaseRepeatButton>
                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageDownCommand" Focusable="False" Opacity="0"/>
              </Track.IncreaseRepeatButton>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 关闭按钮：圆角 + 暖色悬停底（默认按钮模板悬停是方角蓝框） -->
    <Style x:Key="CloseBtnStyle" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#9A968C"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bg" CornerRadius="6" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#EFE9E0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  <!-- 小字号文本防锯齿：布局对齐设备像素 + 平滑字形渲染。
         注意不能用 TextFormattingMode=Display：它把字形硬对齐到像素格，
         曲线会出现阶梯状毛刺（用户实测）；半像素落点问题由根 Border 的
         UseLayoutRounding 解决 -->
    <Style TargetType="TextBlock">
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="TextOptions.TextFormattingMode" Value="Ideal"/>
      <Setter Property="TextOptions.TextRenderingMode" Value="ClearType"/>
    </Style>
  </Window.Resources>
  <Border CornerRadius="12" Background="#F7F5F0" BorderBrush="#E7E2D9" BorderThickness="1"
          UseLayoutRounding="True" SnapsToDevicePixels="True">
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
                  Style="{StaticResource CloseBtnStyle}"/>
        </Grid>
      </Border>
      <!-- 标签页：概览 / 热力图（V2） -->
      <TabControl x:Name="MainTabs" Style="{StaticResource CleanTabControl}"
                  Background="Transparent" Margin="0,2,0,0">
        <TabItem Header="概览" Style="{StaticResource PillTab}">
        <StackPanel>
      <!-- 概览卡片 -->
      <UniformGrid Columns="4">
        <Border Style="{StaticResource Card}" Margin="0,0,5,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="今日" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="TodayCard" Text="0" Foreground="#4A90D9" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <!-- Viewbox 统一缩放：三个 Path 必须共享同一变换。
                   若各自 Stretch=Uniform，小几何体(蒂叶)会被单独拉伸填满槽位盖住果身 -->
              <Viewbox Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Grid Width="24" Height="24">
                  <Path Fill="#D94848" Stretch="None" Data="{StaticResource TomatoBody}"/>
                  <Path Stroke="#D94848" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoOutline}"/>
                  <Path Stroke="#5FA85B" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoLeaf}"/>
                </Grid>
              </Viewbox>
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
              <!-- Viewbox 统一缩放：三个 Path 必须共享同一变换。
                   若各自 Stretch=Uniform，小几何体(蒂叶)会被单独拉伸填满槽位盖住果身 -->
              <Viewbox Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Grid Width="24" Height="24">
                  <Path Fill="#D94848" Stretch="None" Data="{StaticResource TomatoBody}"/>
                  <Path Stroke="#D94848" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoOutline}"/>
                  <Path Stroke="#5FA85B" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoLeaf}"/>
                </Grid>
              </Viewbox>
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
              <!-- Viewbox 统一缩放：三个 Path 必须共享同一变换。
                   若各自 Stretch=Uniform，小几何体(蒂叶)会被单独拉伸填满槽位盖住果身 -->
              <Viewbox Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Grid Width="24" Height="24">
                  <Path Fill="#D94848" Stretch="None" Data="{StaticResource TomatoBody}"/>
                  <Path Stroke="#D94848" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoOutline}"/>
                  <Path Stroke="#5FA85B" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoLeaf}"/>
                </Grid>
              </Viewbox>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="5,0,0,0" Padding="0,8">
          <StackPanel>
            <TextBlock Text="累计" Foreground="#9A968C" FontSize="11"
                       HorizontalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
              <TextBlock x:Name="TotalCard" Text="0" Foreground="#4A90D9" FontSize="20"
                         FontWeight="Bold" VerticalAlignment="Center"/>
              <!-- Viewbox 统一缩放：三个 Path 必须共享同一变换。
                   若各自 Stretch=Uniform，小几何体(蒂叶)会被单独拉伸填满槽位盖住果身 -->
              <Viewbox Width="15" Height="15" Margin="4,0,0,0" VerticalAlignment="Center">
                <Grid Width="24" Height="24">
                  <Path Fill="#D94848" Stretch="None" Data="{StaticResource TomatoBody}"/>
                  <Path Stroke="#D94848" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoOutline}"/>
                  <Path Stroke="#5FA85B" StrokeThickness="2"
                        StrokeStartLineCap="Square" StrokeEndLineCap="Square"
                        Stretch="None" Data="{StaticResource TomatoLeaf}"/>
                </Grid>
              </Viewbox>
            </StackPanel>
          </StackPanel>
        </Border>
      </UniformGrid>
      <!-- 每日校准（↑↓ 翻页可校准 400 天内的更早日期） -->
      <Grid Margin="2,4,0,6">
        <TextBlock x:Name="DayHeader" Text="近 7 天" Foreground="#2F2F2C" FontSize="13"
                   FontWeight="Bold" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="DayUp" Content="&#8593;" Style="{StaticResource IconBtn}"
                  Margin="0,0,4,0"/>
          <Button x:Name="DayDown" Content="&#8595;" Style="{StaticResource IconBtn}"/>
        </StackPanel>
      </Grid>
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
      <!-- 提示：颜色与上方"单击数字"保持一致（浅）；无数据时由 else 分支改写为红色错误信息 -->
      <TextBlock x:Name="HintText" Foreground="#B3AEA4" FontSize="11" Margin="2,6,0,0"
                 TextWrapping="Wrap" HorizontalAlignment="Center"
                 Text="校准前请先停止统计插件（从 Catime 菜单启动本面板会自动停止）"/>
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
        <TabItem Header="趋势" Style="{StaticResource PillTab}">
          <StackPanel Margin="0,10,0,0">
            <!-- 控制行：粒度 / 周期 / 年导航（年粒度时显示） -->
            <StackPanel Orientation="Horizontal" Margin="2,0,0,8">
              <ComboBox x:Name="GranCombo" Width="84" Style="{StaticResource LightCombo}"/>
              <ComboBox x:Name="PeriodCombo" Width="210" Margin="8,0,0,0"
                        Style="{StaticResource LightCombo}"/>
              <StackPanel x:Name="YearNav" Orientation="Horizontal" Visibility="Collapsed"
                          Margin="8,0,0,0" VerticalAlignment="Center">
                <Button x:Name="YearPrev" Content="&#60;" Style="{StaticResource IconBtn}"/>
                <TextBlock x:Name="YearLabel" Text="" FontSize="12" Foreground="#2F2F2C"
                           VerticalAlignment="Center" Margin="8,0"/>
                <Button x:Name="YearNext" Content="&#62;" Style="{StaticResource IconBtn}"/>
              </StackPanel>
            </StackPanel>
            <TextBlock x:Name="TrendSummary" Text="" Foreground="#9A968C" FontSize="11" Margin="2,0,0,4"/>
            <Canvas x:Name="TrendCanvas" Height="250" Background="Transparent"/>
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

# ---- 7 天编辑行（↑↓ 翻页可校准 400 天内的更早日期） ----
$DayBoxes  = @{}     # 日期键 -> TextBox（仅当前页）
$DayUp     = $window.FindName('DayUp')
$DayDown   = $window.FindName('DayDown')
$DayHeader = $window.FindName('DayHeader')
$script:Overlay   = @{}                    # 未保存的人工修改（翻页不丢）
$script:PageStart = $now.Date             # 当前页首行日期（最新一天在最上，默认今天）

function Build-DayRows {
    $DayRows.Children.Clear()
    $DayBoxes.Clear()
    $start = $script:PageStart
    for ($i = 0; $i -lt 7; $i++) {
        $dt = $start.AddDays(-$i)          # 最新一天在顶行，日期向下递减
        if ($dt -gt $now.Date) { break }    # 不显示未来日期
        $dk = $dt.ToString('yyyy-MM-dd')
        $c = 0
        if ($script:Overlay.ContainsKey($dk)) { $c = $script:Overlay[$dk] }
        elseif ($days.ContainsKey($dk)) { $c = $days[$dk] }

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Style = $window.Resources['DayLabel']
        $name = $dt.ToString('MM-dd') + ' ' + $weekCn[[int]$dt.DayOfWeek]
        if ($dt -eq $now.Date) { $name += '（今天）' }
        $lbl.Text = $name

        $box = New-Object System.Windows.Controls.TextBox
        $box.Style = $window.Resources['NumBox']
        $box.Text = [string]$c
        $box.Add_TextChanged({
            if (-not $script:SuppressEditEvent) { $BtnRow.Visibility = 'Visible' }
        })
        # 点击/ Tab 进入编辑时，光标默认落在数字最右端（追加改数更顺手）
        $box.Add_GotFocus({
            param($sender, $e)
            $sender.CaretIndex = $sender.Text.Length
        })
        $box.Add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            if (-not $sender.IsKeyboardFocusWithin) {
                $sender.Focus()
                $sender.CaretIndex = $sender.Text.Length
                $e.Handled = $true   # 阻止默认的按点击坐标定位，保证光标在末端
            }
        })
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
    # 页眉与翻页按钮状态
    if ($start -eq $now.Date) {
        $DayHeader.Text = '近 7 天'
    }
    else {
        $DayHeader.Text = ('更早 7 天（{0} ~ {1}）' -f $start.AddDays(-6).ToString('MM-dd'), $start.ToString('MM-dd'))
    }
    $DayUp.IsEnabled = ($start -lt $now.Date)
    $DayDown.IsEnabled = ($start -ge $now.Date.AddDays(-381))
}
Build-DayRows

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

function Capture-VisibleEdits {
    # 把当前页输入收进未保存修改表（翻页不丢编辑；非法输入不收，留待保存时校验）
    foreach ($e in $DayBoxes.GetEnumerator()) {
        $t = $e.Value.Text.Trim()
        if ($t -match '^\d+$') { $script:Overlay[$e.Key] = [int]$t }
    }
}

if ($haveData) {
    Update-Cards
}
else {
    $HintText.Text = $state.Reason + '。请先运行统计插件（pomodoro_stats_launcher）生成数据。'
    $HintText.Foreground = $conv.ConvertFromString('#D9534F')
    foreach ($b in $DayBoxes.Values) { $b.IsEnabled = $false }
    $DayUp.IsEnabled = $false
    $DayDown.IsEnabled = $false
}
$script:SuppressEditEvent = $false

# ---- 事件 ----
$TitleBar.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch { }
})

$CloseBtn.Add_Click({ $window.Close() })

# 取消：清除未保存修改，回到今天页，按钮收起
$CancelBtn.Add_Click({
    $script:Overlay.Clear()
    $script:PageStart = $now.Date
    Build-DayRows
    $BtnRow.Visibility = 'Collapsed'
    $StatusText.Text = ''
})

# ↑↓ 翻页（先收当前页编辑，再换页重建；↑=更新，↓=更早）
$DayUp.Add_Click({
    Capture-VisibleEdits
    $newStart = $script:PageStart.AddDays(7)
    if ($newStart -le $now.Date) { $script:PageStart = $newStart }
    Build-DayRows
})
$DayDown.Add_Click({
    Capture-VisibleEdits
    $newStart = $script:PageStart.AddDays(-7)
    if ($newStart -ge $now.Date.AddDays(-388)) { $script:PageStart = $newStart }
    Build-DayRows
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
        # 合并：当前页输入 + 翻页期间其他页的人工修改，其余历史日期原样保留
        $newDays = [hashtable]$days.Clone()
        foreach ($e in $vals.GetEnumerator()) { $newDays[$e.Key] = $e.Value }
        foreach ($e in $script:Overlay.GetEnumerator()) { $newDays[$e.Key] = [int]$e.Value }
        # 累计 = 全部明细合计（与统计插件计数口径天然一致，杜绝手工改数后对不上）
        $newTotal = 0
        foreach ($v in $newDays.Values) { $newTotal += $v }
        Save-State $j $newDays $newTotal
        $script:days = $newDays
        try { $script:j.total = $newTotal } catch { }

        Update-Cards
        Update-Heatmap   # 热力图跟着校准结果刷新（用户实测：保存后格子不更新）
        Update-Trend     # V3：趋势折线同样跟着校准结果刷新
        $script:Overlay.Clear()
        Build-DayRows    # 用已保存值重建当前页
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
                # 悬停即时显示（系统默认延迟 500ms），且悬停期间不自动消失（默认 5s）
                [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($cell, 0)
                [System.Windows.Controls.ToolTipService]::SetShowDuration($cell, 60000)
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

# ---- 趋势标签页（V3：平滑折线，粒度 周/月/年，Canvas 自绘） ----
$GranCombo    = $window.FindName('GranCombo')
$PeriodCombo  = $window.FindName('PeriodCombo')
$YearNav      = $window.FindName('YearNav')
$YearPrev     = $window.FindName('YearPrev')
$YearNext     = $window.FindName('YearNext')
$YearLabel    = $window.FindName('YearLabel')
$TrendSummary = $window.FindName('TrendSummary')
$TrendCanvas  = $window.FindName('TrendCanvas')

$script:TrendPoints   = @()    # 画布坐标点（悬停命中用）
$script:HoverDot      = $null
$script:TipBorder     = $null
$script:YearWindowEnd = (Get-Date).Year
$wdShort = @('一','二','三','四','五','六','日')

# 粒度下拉项（周/月/年）
foreach ($g in @('周','月','年')) {
    $gi = New-Object System.Windows.Controls.ComboBoxItem
    $gi.Content = $g
    [void]$GranCombo.Items.Add($gi)
}

function Get-WeekTrend {
    param([datetime]$AnyDay)
    $ws = (Get-WeekStart $AnyDay)
    $out = @()
    for ($i = 0; $i -lt 7; $i++) {
        $d = $ws.AddDays($i)
        $k = $d.ToString('yyyy-MM-dd')
        $v = 0
        if ($days.ContainsKey($k)) { $v = $days[$k] }
        $out += @{ Label = ('周' + $wdShort[(([int]$d.DayOfWeek) + 6) % 7]); Value = $v }
    }
    return $out
}

function Get-MonthTrend {
    param([datetime]$AnyDay)
    $cnt = [datetime]::DaysInMonth($AnyDay.Year, $AnyDay.Month)
    $out = @()
    for ($i = 1; $i -le $cnt; $i++) {
        $d = Get-Date -Year $AnyDay.Year -Month $AnyDay.Month -Day $i
        $k = $d.ToString('yyyy-MM-dd')
        $v = 0
        if ($days.ContainsKey($k)) { $v = $days[$k] }
        $out += @{ Label = $d.ToString('MM-dd'); Value = $v }
    }
    return $out
}

function Get-YearTrend {
    param([int]$EndYear)
    $out = @()
    for ($y = $EndYear - 4; $y -le $EndYear; $y++) {
        $sum = 0
        foreach ($k in $days.Keys) {
            if ($k.StartsWith([string]$y + '-')) { $sum += $days[$k] }
        }
        $out += @{ Label = [string]$y; Value = $sum }
    }
    return $out
}

function Fill-PeriodCombo {
    $PeriodCombo.Items.Clear()
    $now = Get-Date
    if ($GranCombo.SelectedIndex -eq 0) {
        # 周：最近 12 周（含本周）
        for ($i = 0; $i -lt 12; $i++) {
            $ws = (Get-WeekStart $now).AddDays(-7 * $i)
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = ('{0} ~ {1}{2}' -f $ws.ToString('MM-dd'), $ws.AddDays(6).ToString('MM-dd'),
                             $(if ($i -eq 0) { '（本周）' } else { '' }))
            $item.Tag = $ws.ToString('yyyyMMdd')
            [void]$PeriodCombo.Items.Add($item)
        }
    }
    else {
        # 月：最近 12 个月（含本月）
        for ($i = 0; $i -lt 12; $i++) {
            $m = $now.AddMonths(-$i)
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $m.ToString('yyyy-MM')
            $item.Tag = $m.ToString('yyyy-MM')
            [void]$PeriodCombo.Items.Add($item)
        }
    }
    $PeriodCombo.SelectedIndex = 0
}

function Get-CurrentSeries {
    if ($GranCombo.SelectedIndex -eq 2) { return (Get-YearTrend $script:YearWindowEnd) }
    $item = $PeriodCombo.SelectedItem
    if ($null -eq $item) { return @() }
    $tag = [string]$item.Tag
    if ($GranCombo.SelectedIndex -eq 0) {
        $d = [datetime]::ParseExact($tag, 'yyyyMMdd', $null)
        return (Get-WeekTrend $d)
    }
    $d = [datetime]::ParseExact($tag + '-01', 'yyyy-MM-dd', $null)
    return (Get-MonthTrend $d)
}

# Cardinal 样条插值段集合（每个 PathGeometry 需要独立段，不可共享）
function New-SplineSegments {
    param($Pts)
    $segs = New-Object System.Windows.Media.PathSegmentCollection
    $n = $Pts.Count
    $tension = 0.5
    for ($i = 0; $i -lt $n - 1; $i++) {
        $p0 = if ($i -eq 0) { $Pts[0] } else { $Pts[$i - 1] }
        $p1 = $Pts[$i]
        $p2 = $Pts[$i + 1]
        $p3 = if ($i + 2 -ge $n) { $Pts[$n - 1] } else { $Pts[$i + 2] }
        $c1 = [System.Windows.Point]::new($p1.X + ($p2.X - $p0.X) / 6.0 * $tension,
                                          $p1.Y + ($p2.Y - $p0.Y) / 6.0 * $tension)
        $c2 = [System.Windows.Point]::new($p2.X - ($p3.X - $p1.X) / 6.0 * $tension,
                                          $p2.Y - ($p3.Y - $p1.Y) / 6.0 * $tension)
        [void]$segs.Add((New-Object System.Windows.Media.BezierSegment(
            $c1, $c2, [System.Windows.Point]::new($p2.X, $p2.Y), $true)))
    }
    # -NoEnumerate：PathSegmentCollection 可枚举，直接 return 会被管道拆散成 Object[]
    Write-Output -NoEnumerate $segs
}

function Update-Trend {
    $series = Get-CurrentSeries
    $TrendCanvas.Children.Clear()
    $script:TrendPoints = @()
    $n = $series.Count
    if ($n -eq 0) {
        $TrendSummary.Text = '暂无数据'
        return
    }

    $CW = 456.0; $CH = 250.0
    $padL = 30.0; $padR = 10.0; $padT = 12.0; $padB = 24.0
    $plotW = $CW - $padL - $padR
    $plotH = $CH - $padT - $padB
    $maxV = 1.0
    foreach ($s in $series) { if ([double]$s.Value -gt $maxV) { $maxV = [double]$s.Value } }

    $convT     = [System.Windows.Media.BrushConverter]::new()
    $gridBrush = $convT.ConvertFromString('#EFEDE8')
    $labelBr   = $convT.ConvertFromString('#9A968C')
    $accentBr  = $convT.ConvertFromString('#66A6FF')

    # 横向网格 + Y 轴标签（全 0 数据时用 2 档，避免刻度重复）
    $divs = 3
    if ($maxV -le 1) { $divs = 1 }
    for ($g = 0; $g -le $divs; $g++) {
        $y = $padT + $plotH * $g / $divs
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $padL; $ln.Y1 = $y; $ln.X2 = $CW - $padR; $ln.Y2 = $y
        $ln.Stroke = $gridBrush; $ln.StrokeThickness = 1
        [void]$TrendCanvas.Children.Add($ln)
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = [string][int][math]::Round($maxV * ($divs - $g) / $divs)
        $lb.FontSize = 9; $lb.Foreground = $labelBr
        $lb.Width = 24; $lb.TextAlignment = 'Right'
        [System.Windows.Controls.Canvas]::SetLeft($lb, 0)
        [System.Windows.Controls.Canvas]::SetTop($lb, $y - 7)
        [void]$TrendCanvas.Children.Add($lb)
    }

    # 数据点坐标
    for ($i = 0; $i -lt $n; $i++) {
        $x = $padL + $(if ($n -eq 1) { $plotW / 2.0 } else { $plotW * $i / ($n - 1) })
        $y = $padT + $plotH * (1.0 - ([double]$series[$i].Value / $maxV))
        $script:TrendPoints += @{ X = $x; Y = $y; Label = $series[$i].Label; Value = $series[$i].Value }
    }

    # 面积填充（曲线闭合到底部，淡 accent 8%）
    $figFill = New-Object System.Windows.Media.PathFigure
    $figFill.StartPoint = [System.Windows.Point]::new($script:TrendPoints[0].X, $script:TrendPoints[0].Y)
    $figFill.Segments = (New-SplineSegments $script:TrendPoints)
    $bottomY = $padT + $plotH
    [void]$figFill.Segments.Add((New-Object System.Windows.Media.LineSegment(
        [System.Windows.Point]::new($script:TrendPoints[$n - 1].X, $bottomY), $true)))
    [void]$figFill.Segments.Add((New-Object System.Windows.Media.LineSegment(
        [System.Windows.Point]::new($script:TrendPoints[0].X, $bottomY), $true)))
    $geoFill = New-Object System.Windows.Media.PathGeometry
    [void]$geoFill.Figures.Add($figFill)
    $area = New-Object System.Windows.Shapes.Path
    $area.Data = $geoFill
    $area.Stroke = $null
    $fillBr = [System.Windows.Media.SolidColorBrush]::new()
    $fillBr.Color = [System.Windows.Media.Color]::FromArgb(20, 0x66, 0xA6, 0xFF)
    $area.Fill = $fillBr
    [void]$TrendCanvas.Children.Add($area)

    # 平滑曲线（accent 渐变描边）
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = $figFill.StartPoint
    $fig.Segments = (New-SplineSegments $script:TrendPoints)
    $geo = New-Object System.Windows.Media.PathGeometry
    [void]$geo.Figures.Add($fig)
    $line = New-Object System.Windows.Shapes.Path
    $line.Data = $geo
    $line.StrokeThickness = 2.5
    $line.StrokeLineJoin = 'Round'
    $line.StrokeStartLineCap = 'Round'
    $line.StrokeEndLineCap = 'Round'
    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0'; $grad.EndPoint = '1,0'
    [void]$grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
        [System.Windows.Media.Color]::FromRgb(0x89, 0xF7, 0xFE), 0.0)))
    [void]$grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
        [System.Windows.Media.Color]::FromRgb(0x66, 0xA6, 0xFF), 1.0)))
    $line.Stroke = $grad
    [void]$TrendCanvas.Children.Add($line)

    # 数据圆点（白心 accent 边）
    foreach ($p in $script:TrendPoints) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 5; $dot.Height = 5
        $dot.Fill = [System.Windows.Media.Brushes]::White
        $dot.Stroke = $accentBr; $dot.StrokeThickness = 1.5
        [System.Windows.Controls.Canvas]::SetLeft($dot, $p.X - 2.5)
        [System.Windows.Controls.Canvas]::SetTop($dot, $p.Y - 2.5)
        [void]$TrendCanvas.Children.Add($dot)
    }

    # X 轴标签（月视图抽样约 7 个，周/年全显）
    $step = 1
    if ($GranCombo.SelectedIndex -eq 1) { $step = [int][math]::Ceiling($n / 7.0) }
    for ($i = 0; $i -lt $n; $i += $step) {
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = $series[$i].Label
        $lb.FontSize = 9; $lb.Foreground = $labelBr
        $lb.Width = 44; $lb.TextAlignment = 'Center'
        [System.Windows.Controls.Canvas]::SetLeft($lb, $script:TrendPoints[$i].X - 22)
        [System.Windows.Controls.Canvas]::SetTop($lb, $padT + $plotH + 6)
        [void]$TrendCanvas.Children.Add($lb)
    }

    # 悬停高亮点 + 提示卡（画布内元素，避免 Popup 抢鼠标）
    $hover = New-Object System.Windows.Shapes.Ellipse
    $hover.Width = 9; $hover.Height = 9
    $hover.Fill = $accentBr
    $hover.Visibility = 'Collapsed'
    [void]$TrendCanvas.Children.Add($hover)
    $script:HoverDot = $hover

    $tip = New-Object System.Windows.Controls.Border
    $tip.Background = [System.Windows.Media.Brushes]::White
    $tip.BorderBrush = $convT.ConvertFromString('#ECE8E0')
    $tip.BorderThickness = [System.Windows.Thickness]::new(1)
    $tip.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $tip.Padding = [System.Windows.Thickness]::new(7, 4, 7, 4)
    $tip.Visibility = 'Collapsed'
    $tipTxt = New-Object System.Windows.Controls.TextBlock
    $tipTxt.FontSize = 11; $tipTxt.Foreground = $convT.ConvertFromString('#2F2F2C')
    $tip.Child = $tipTxt
    [void]$TrendCanvas.Children.Add($tip)
    $script:TipBorder = $tip
    $script:TipText = $tipTxt

    # 汇总行
    $sum = 0
    foreach ($s in $series) { $sum += [int]$s.Value }
    $avgLabel = if ($GranCombo.SelectedIndex -eq 2) { '年均' } else { '日均' }
    $TrendSummary.Text = ('区间共 {0} 个 · {1} {2} 个' -f $sum, $avgLabel, [math]::Round($sum / $n, 1))
}

# 悬停命中：按 X 距离找最近点
$TrendCanvas.Add_MouseMove({
    if ($script:TrendPoints.Count -eq 0 -or $null -eq $script:HoverDot) { return }
    $pos = [System.Windows.Input.Mouse]::GetPosition($TrendCanvas)
    $best = $null
    $bestD = [double]::MaxValue
    foreach ($p in $script:TrendPoints) {
        $d = [math]::Abs($p.X - $pos.X)
        if ($d -lt $bestD) { $bestD = $d; $best = $p }
    }
    if ($null -ne $best) {
        [System.Windows.Controls.Canvas]::SetLeft($script:HoverDot, $best.X - 4.5)
        [System.Windows.Controls.Canvas]::SetTop($script:HoverDot, $best.Y - 4.5)
        $script:HoverDot.Visibility = 'Visible'
        $script:TipText.Text = ('{0}：{1} 个' -f $best.Label, $best.Value)
        $tx = $best.X - 30
        if ($tx -lt 0) { $tx = 0 }
        if ($tx -gt 320) { $tx = 320 }
        [System.Windows.Controls.Canvas]::SetLeft($script:TipBorder, $tx)
        [System.Windows.Controls.Canvas]::SetTop($script:TipBorder, $best.Y - 38)
        $script:TipBorder.Visibility = 'Visible'
    }
})
$TrendCanvas.Add_MouseLeave({
    if ($null -ne $script:HoverDot) { $script:HoverDot.Visibility = 'Collapsed' }
    if ($null -ne $script:TipBorder) { $script:TipBorder.Visibility = 'Collapsed' }
})

# 年导航
$YearPrev.Add_Click({
    $script:YearWindowEnd--
    $YearLabel.Text = ('{0} - {1}' -f ($script:YearWindowEnd - 4), $script:YearWindowEnd)
    Update-Trend
})
$YearNext.Add_Click({
    $script:YearWindowEnd++
    $YearLabel.Text = ('{0} - {1}' -f ($script:YearWindowEnd - 4), $script:YearWindowEnd)
    Update-Trend
})

# 粒度切换：重建周期下拉 / 显隐年导航 / 重画
$GranCombo.Add_SelectionChanged({
    $isYear = ($GranCombo.SelectedIndex -eq 2)
    $PeriodCombo.Visibility = $(if ($isYear) { 'Collapsed' } else { 'Visible' })
    $YearNav.Visibility = $(if ($isYear) { 'Visible' } else { 'Collapsed' })
    if ($isYear) {
        $YearLabel.Text = ('{0} - {1}' -f ($script:YearWindowEnd - 4), $script:YearWindowEnd)
    }
    else {
        Fill-PeriodCombo
    }
    Update-Trend
})

# 周期切换（选具体哪周/哪月）：重画
$PeriodCombo.Add_SelectionChanged({ Update-Trend })

# 初始：选"周"触发 SelectionChanged → 填周期下拉 + 画当前周
$GranCombo.SelectedIndex = 0

# ---- 视觉回归测试模式：跑完整代码 + 切标签 + 渲染存图，不弹窗 ----
# 用法：-RenderTab 0|1|2 [-RenderGran 0|1|2]，输出到 $env:TEMP
if ($RenderTab -ge 0) {
    if ($RenderGran -ge 0 -and $RenderGran -le 2) { $GranCombo.SelectedIndex = $RenderGran }
    if ($RenderPeriod -ge 0 -and $RenderPeriod -lt $PeriodCombo.Items.Count) {
        $PeriodCombo.SelectedIndex = $RenderPeriod
    }
    $tabsCtrl = $window.FindName('MainTabs')
    $tabsCtrl.SelectedIndex = $RenderTab
    $c2 = $window.Content
    # 按窗口实际宽度 520 强制排列（否则内容按自然宽度收窄，画布右侧被裁）
    $c2.Measure([System.Windows.Size]::new(520, 1000))
    $hh = [math]::Max($c2.DesiredSize.Height, 420)
    $c2.Arrange([System.Windows.Rect]::new(0, 0, 520, $hh))
    $c2.UpdateLayout()
    $sc2 = 3.0
    $w2 = 1560
    $h2 = [int][math]::Ceiling($hh * $sc2)
    $bm2 = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w2, $h2, 192.0, 192.0, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bm2.Render($c2)
    $enc2 = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc2.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bm2))
    $out2 = Join-Path $env:TEMP ('dash_render_tab{0}_g{1}.png' -f $RenderTab, $(if ($RenderGran -ge 0) { $RenderGran } else { -1 }))
    $fs2 = [System.IO.File]::Create($out2)
    $enc2.Save($fs2); $fs2.Close()
    # 附带裁剪标签条区域（验证圆角）
    try {
        $cr = New-Object System.Windows.Int32Rect(50, 170, 720, 150)
        $crBmp = New-Object System.Windows.Media.Imaging.CroppedBitmap($bm2, $cr)
        $enc3 = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc3.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($crBmp))
        $out3 = Join-Path $env:TEMP ('dash_render_tab{0}_g{1}_strip.png' -f $RenderTab, $(if ($RenderGran -ge 0) { $RenderGran } else { -1 }))
        $fs3 = [System.IO.File]::Create($out3)
        $enc3.Save($fs3); $fs3.Close()
    } catch { }
    Write-Output ("RENDERED: $out2")
    exit 0
}

# 无头 UI 自检：解析 XAML + 查找命名控件 + 构建热力图，不显示窗口 ----
# 用途：SelfTest 覆盖不了 XAML/热力图构建，此前该段一旦报错只会"进程静默死亡、
# 用户看不到弹窗"。UiCheck 把这段变成可确定性验证的检查（check_dashboard.py E10）。
if ($UiCheck) {
    $probe = Build-Heatmap $days $now
    # 取第一个带提示的格子（Grid 首个子元素是星期标签，不是格子）
    $probeCell = $null
    foreach ($ch in $probe.Children) {
        if ($ch.ToolTip) { $probeCell = $ch; break }
    }
    $tipDelay = -1
    $tipDur = -1
    if ($probeCell) {
        $tipDelay = [System.Windows.Controls.ToolTipService]::GetInitialShowDelay($probeCell)
        $tipDur = [System.Windows.Controls.ToolTipService]::GetShowDuration($probeCell)
    }
    $missing = @()
    foreach ($n in @('TitleBar','CloseBtn','TodayCard','WeekCard','MonthCard','TotalCard',
                     'HintText','DayRows','BtnRow','SaveBtn','CancelBtn','StatusText',
                     'HeatGrid','MainTabs','GranCombo','PeriodCombo','YearNav','YearPrev',
                     'YearNext','YearLabel','TrendSummary','TrendCanvas',
                     'DayHeader','DayUp','DayDown')) {
        if ($null -eq $window.FindName($n)) { $missing += $n }
    }
    Write-Output ("UICHECK: OK heatmap_children={0} missing={1} tip_delay={2} tip_dur={3}" -f `
        $probe.Children.Count, ($missing -join ','), $tipDelay, $tipDur)
    exit 0
}

[void]$window.ShowDialog()
