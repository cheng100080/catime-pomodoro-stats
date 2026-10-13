# 开发文档：pomodoro_stats 番茄钟统计插件

> 本文档是统计插件的开发说明与路线图（将要做哪些功能）。
> 机制与踩坑记录见 `Technology.md` / `error.md`；显示插件设计见
> `设计_pomodoro_dashboard.md`。修改本文档请追加"修订记录"。

## 1. 定位

为 Catime（Windows 纯 C 托盘计时器）开发的番茄钟统计插件，**不改 Catime 源码**，
只通过文件与 Catime 通信。窗口实时显示：今日 / 本周 / 累计完成的番茄数
（统计行渲染成 PNG 贴在计时上方），数据持久化、重启不丢。

## 2. 架构现状（v0.18）

```
pomodoro_stats_launcher.bat   入口：绝对路径调解释器（绕开 PATH 缺失，error.md E1）
pomodoro_stats_core.ps1       逻辑：检测→分类→计数→显示（755 行，单一无限循环）
pomodoro_stats.json           状态持久化（原子写：临时文件 + Move -Force）
pomodoro_stats.log            轻量日志（启动参数/每次计数/循环异常，同类只记一次）
output.txt / stats_*.png      Catime 显示输入 / 统计行图片（Catime 锁定旧图）
```

数据流：`CatimeNotificationClass` 通知窗口（500ms 轮询，EnumWindows）→
按 `POMODORO_TIME_OPTIONS` + 间隔匹配判定阶段类型 → 工作段计数 → 写 json → 刷显示。

### 可配置项（core.ps1 顶部）

| 配置项 | 默认 | 说明 |
|---|---|---|
| `$LabelToday/Week/Month/Total` | T/W/M/A | 显示标签（ASCII，避免字体缺字形） |
| `$ShowWeek/Month/Total` | true/false/false | 显示开关（后台照常记录） |
| `$DisplayLayout` | stacked | stacked=两行 / single=单行 |
| `$StatsAsImage` | true | 统计行渲染 PNG |
| `$StatsImageScreenPx` | 27 | 统计行**屏幕字号**（图片固定大小，v0.18 起不随时钟缩放漂移） |
| `$TimerDisplayMode` | both | both / timer |
| `$CountUnit` | work | work=每个工作段 / cycle=整轮 |
| `$PhaseTypes` | ''（自动） | 特殊序列显式标注 W/B |
| `$PollMs` | 500 | 通知窗口轮询间隔 |
| `$ShowOwnTimeWhenIdle` | true（仅计时后补写） | 已实现又裁剪，见 MEMORY.md（勿恢复自写时钟） |

### 数据格式

```json
{"version":1,"total":51,"phase":0,"lastEvent":"ISO8601","days":{"2026-10-13":8}}
```
`days` 仅保留 400 天内明细；`phase`/`lastEvent` 供阶段索引自纠正——**外部改动需原样保留**。

### 质量基线

`_tmp/robust_check.py`：33 项（语法/状态损坏/配置异常/字体缺失/大状态/日志裁剪/
日期统计/图片渲染/编码约定/关键标签恒在）全过，改动后必须重跑。

### 已知限制（无法根治，Catime 无信号）

- 普通倒计时结束也会被计为工作段（无法区分番茄钟模式与普通倒计时）
- 番茄钟中途重置会使阶段索引短暂错位（多数能自纠正）
- Catime 永久锁定正在显示的图片 → 每次重绘遗留一个旧 png（重启后清理）

## 3. 路线图（将要加入的功能）

### v0.19（下一个版本）
- **统计行图片大小可调**：新增脚本旁 `pomodoro_stats.ini`（用户可编辑，
  `StatsImageScreenPx=27` 等），core 启动与配置热重载时读取；
  ini 不存在/缺键时用脚本内默认值。不做 Catime 内 UI，先手改文件。
- ini 同时暴露 `$ShowMonth/$ShowTotal` 等显示开关，免改脚本。

### v0.2x（候选，按需求排期）
- **中断检测**：通知窗口消失后长时间无新阶段 → 判定番茄钟被手动中断，
  停止"推断计时中"状态（改善 `timer` 模式体验）
- **月度默认显示**：`$ShowMonth` 默认 true（等 ini 机制落地后再改默认值）
- **数据导出**：json → CSV（日期,计数），供 Excel 分析
- **周起始日可配**：周一/周日（ini 项，影响 Get-WeekStart）
- **时区/午夜跨界处理**：跨午夜的番茄段归属哪一天，显式化并记录日志

### 不做（否决记录）
- 插件自写空闲时钟（已实现又移除，commit e71d27b：与 Catime 自带时间必然重复）
- 读取/依赖 Catime 源码级信息（保持纯文件通信）
- 联网同步、第三方依赖

## 4. 修订记录

- 2026-10-13 初版（对应 v0.18：图片缓存键加入缩放值，统计行固定屏幕大小）
