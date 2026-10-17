# 开发文档（DEVELOPMENT）

本文面向想二次开发 / 排错的开发者，整合了设计与实现的关键结论。
安装与使用见 `README.md`；法律条款见 `LICENSE`（Apache 2.0）。

## 1. 项目概览

为 [Catime](https://github.com/vladelaina/Catime)（Windows 纯 C 托盘计时器）开发的两个搭档插件：

| 插件 | 作用 | 形态 |
|---|---|---|
| `pomodoro_stats` | 在 Catime 窗口实时显示 今日/本周/(本月)/(累计) 番茄数 | 常驻 PowerShell 循环 |
| `pomodoro-dashboard` | WPF 弹窗面板：查看统计、校准近 7 天、热力图、趋势图 | 一次性 WPF 窗口 |

**硬约束**：不改 Catime 源码，只通过文件与 Catime 通信；只依赖 Windows 自带组件
（PowerShell 5.1 + WPF）；不联网、不引入第三方依赖、不写死机器相关绝对路径。

## 2. 仓库与安装布局

```
仓库/
├── README.md / DEVELOPMENT.md / LICENSE / .gitignore
├── pomodoro_stats_launcher.bat      # 统计插件入口（菜单里点这个）
├── pomodoro_stats_core.ps1          # 统计插件逻辑
└── pomodoro-dashboard/
    ├── pomodoro_dashboard_launcher.bat   # 面板入口（-STA，WPF 需要）
    └── pomodoro_dashboard_core.ps1       # 面板逻辑
```

安装 = 把上述内容复制进 `%LOCALAPPDATA%\Catime\resources\plugins\`：

- 统计插件两个文件放 **plugins 根目录**；
- 面板整个文件夹放 **plugins\pomodoro_dashboard\**；
- `pomodoro_stats.json` 写在统计脚本同级，面板从 `..\pomodoro_stats.json` 解析
  （失败时回退 `%LOCALAPPDATA%\Catime\resources\plugins\pomodoro_stats.json`）；
- Catime 菜单会同时列出 `_launcher.bat` 与 `_core.ps1` 两项，**必须点 launcher**。

## 3. Catime 插件机制（源码核对，v1.5.0）

**加载**：插件目录扫描脚本，白名单为扩展名列表（`*.bat *.cmd *.ps1`，**不含 `*.psm1`**），
**递归扫描子目录**、不跳过隐藏文件；首次运行弹信任框；同时只能运行一个插件；
Catime 用 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）管理插件进程树，
退出时整棵树被杀（所以 `.bat` 套一层是安全的）。

**output.txt 契约**：必须写在被启动文件的**同级目录**；UTF-8 无 BOM；
Catime 事件驱动监听 + 防抖读取；支持 `<fps:N>`、`<catime></catime>`、`<color:>`、
`<font:>`、`<md>`、`![](图片)`、`<exit>`、`<notify>` 等标签。

**`<catime></catime>` 是生死线**：Catime 在开始任何计时动作前调用
`CleanupBeforeTimerAction()`，其中

```c
if (!PluginData_HasCatimeTag()) PluginManager_StopAllPlugins();
```

输出文本不含该标签的插件会被直接杀掉（表现：一按倒计时插件就消失、统计不到、重开仍是 T0 W0 A0）。
副作用是正面的：该标签处由 Catime 渲染当前计时/时间，插件模式下也能看到倒计时。

**关键窗口类名**：主窗口 `CatimeWindowClass`；通知弹窗 `CatimeNotificationClass`
（通知类型为 `CATIME` 时，每个阶段完成都会创建该窗口）。

**缩放**：`PLUGIN_SCALE` 是插件模式的独立缩放档位，直接作为字体乘数，
窗口尺寸随之线性变化；编辑模式拖拽/滚轮会写回该值。

**通知窗口**：只有一行文字；字号 = 窗口高度 × `NOTIFICATION_FONT_SIZE`(10~60%)，
宽度上限 1600 → 长消息要么加宽、要么降低百分比，否则被省略号截断。

## 4. 番茄钟语义（源码结论）

- `complete_pomodoro_cycles` 是**进程内内存变量**，不写 config、无 IPC，插件读不到；
- 每个阶段（工作/休息）结束都会弹一次通知，整轮结束再额外通知一次；
- **整轮结束的额外通知会被检测机制误判成"又一次阶段完成"**（v0.20.1 修复）：
  `TimerEvents_HandlePomodoroCompletion` 在循环结束时连弹两个 toast（阶段完成 +
  "All Pomodoro cycles completed!"），第二个 toast 产生新窗口句柄 → 幽灵事件：
  假计数 +1（索引绕回 0 判成工作段）、相位污染、计时推断重置（结束后幽灵显示
  `2/4` 一个短段长）。守卫规则：距上次完成事件的间隔 **< 最短段长 - 1s**
  （1s = 500ms 轮询抖动余量）时判为幽灵，直接忽略——真实段长 ≥ 最短段、
  暂停只增不减，规则安全；等长测试序列（如 5,5,5,5）下间隔自纠正无法分辨
  索引，幽灵污染的相位会带偏整轮，故守卫必须在相位推进之前。
- 阶段序列来自 `config.ini [Pomodoro] POMODORO_TIME_OPTIONS`（**秒**，逗号分隔）；
- **Catime 不记录工作/休息属性**：`current_pomodoro_phase` 只会是 `IDLE`/`WORK`
  （`BREAK`/`LONG_BREAK` 枚举从未使用），通知文本只含时长与轮次
  → 工作/休息只能靠约定推断。

## 5. 架构与数据流

### 5.1 统计插件（单一无限循环）

```
CatimeNotificationClass 新窗口（500ms 轮询，EnumWindows + GetClassName）
  → 按 POMODORO_TIME_OPTIONS + 间隔匹配判定阶段类型（自纠正索引）
  → 工作段计数 → 原子写 pomodoro_stats.json → 刷 output.txt + 渲染统计 PNG
```

### 5.2 显示面板（一次性 WPF 窗口）

读 json → 三标签面板（概览 / 热力图 / 趋势）→ 校准近 7 天每日数 → 原子写回。

- 概览：四张数字卡（今日 / 本周 / 本月 / 累计，accent 蓝 `#4A90D9` + TDesign 番茄图标）
  + 近 7 天可编辑列表（↑↓ 翻页可校准更早日期，跨页保留未保存修改）；
- 热力图：近 12 周打卡图，相对色阶（窗口峰值基准）；
- 趋势：Cardinal 样条平滑折线，周(7 点) / 月(每日点) / 年(5 年合计点 + `<>` 平移) 三粒度，悬停就近命中提示；
- **派生视图必须在保存后刷新**（今日=明细；本周/本月/累计/热力图/趋势均为派生只读，
  累计保存时重写 `json.total`）；`version`/`phase`/`lastEvent` 原样保留、不可编辑
  （`phase` 被打乱会影响统计插件的阶段索引判定）。

## 6. 关键技术决策

| 决策 | 内容与理由 |
|---|---|
| 语言 | PowerShell 5.1（系统自带、零依赖、单进程常驻） |
| 入口 | `.bat` + 绝对路径调解释器。本机 PATH 缺 `WindowsPowerShell\v1.0`，Catime 启动 `.ps1` 靠 PATH 找 `powershell.exe` 会失败；`cmd.exe` 必在 System32，`.bat` 必然可被找到 |
| 检测 | 500ms 轮询 `EnumWindows + GetClassName` 找通知窗口**新句柄**。**不要用 `FindWindowW`**（实测跨进程按类名返回 0，而 EnumWindows 稳定） |
| 阶段分类 | 序列 + **间隔匹配自纠正**（用两次完成的间隔反推阶段）；`$PhaseTypes` 显式模板（`'WBWB'` 等）处理特殊序列，留空=自动模式（第 1、3、5… 段为工作）；长度不符自动回退 + 记日志。**已否决"按时长推断"**：经典 `25 5 25 5 25 5 25 30` 的最长段是长休息会误判 |
| 计数口径 | `$CountUnit='work'`：每完成一个工作段计 1 个（正统番茄工作法）；另有 `'cycle'`（整轮计 1 个，Catime 口径），改一行切换 |
| 新会话判定 | 距上次完成 > 2×最长阶段 + 300s → 视为重新开始，刚完成的算第 1 个工作段 |
| 持久化 | 脚本同级 `pomodoro_stats.json`，原子写（临时文件 + `Move-Item`），明细保留 400 天 |
| 门禁 | `NOTIFICATION_TYPE != CATIME` → 显示 `SET CATIME` 且不计数（OS 系统通知走 Explorer 气球，窗口会被节流抑制、类名不专属，不可作检测信号） |
| 日志 | `pomodoro_stats.log`：启动参数、每次计数、循环异常（同类只记一次，>64KB 重建）。**没有日志时静默故障无法定位** |
| 资源 | 每 500ms 一次 EnumWindows（微秒级）；仅事件发生时写盘；无网络。实测 CPU≈0%，内存为 PS5.1+WPF 地板（统计约 72MB / 面板约 86MB） |

## 7. 显示与布局机制（与 Catime 耦合的关键）

- **窗口高 = 行数 × 行高**（行高随 `PLUGIN_SCALE` 放大）→ 想去"高矩形"，唯一办法是减少行数。
  最终为**单行输出**：`<catime></catime><md>![WxH](stats.png)ZWSP</md>`
  （时间与统计图同行；图片渲染失败回退 `<md>###### 文本</md>`）。
- **统计图保持绝对像素**：`spec = PNG宽高 ÷ PLUGIN_SCALE`，显示尺寸 = PNG 原始像素，
  不随缩放变。曾试过"跟随缩放"被否决（比例固定不可用），已 revert。
- **`<catime></catime>` 恒被替换为当前时间文本**，插件**不得自写空闲时钟**
  （与 Catime 自带时间必然重复，已实现又移除）。
- **配色/字体与时钟同源**：读 `[Display] CLOCK_TEXT_COLOR`（支持双色渐变，
  `#89F7FE_#66A6FF` 下划线分隔 → `LinearGradientBrush`）与 `FONT_FILE_NAME`；
  缓存键含二者，改色/改字体自动重绘，不需重启插件。
- **插件不热更新**：改文件后必须重开插件（用"进程启动时间 vs 文件修改时间"可核对用户反馈对的是哪一版）。

## 8. 数据格式

```json
{"version":1,"total":51,"phase":0,"lastEvent":"ISO8601","days":{"2026-10-13":8}}
```

- `days` 仅保留 400 天内明细；`phase`/`lastEvent` 供阶段索引自纠正——**外部改动需原样保留**；
- 累计 = 明细合计（派生只读，保存时重写 `json.total`）。

## 9. 硬性约定（改动前必读）

- `.ps1` 一律 **UTF-8 带 BOM + CRLF**（PS 5.1 无 BOM 时按 ANSI/GBK 读中文 → 解析失败，且别写成双 BOM）；
  `.bat` 纯 CRLF，**注释只用 ASCII**（cmd 对 `rem` 行做重定向解析，乱码字节可能引发副作用）；
- 输出文本末尾必须含 `<catime></catime>`（见 §3）；
- 不改 Catime 源码、不改统计插件的 json 语义；不联网、无第三方依赖；
- 每个任务完成提交一次 git，提交信息写清改了什么、为什么；重大节点打 tag；
- 大文件（上游源码浅克隆 `upstream/`）、本地工作笔记（`Development/`、`AGENTS.md`）、
  测试脚本（`_tmp/`）与运行产物（`output.txt`、`*.json`、`*.log`、`*.png`）**不进仓库**（见 `.gitignore`）。

## 10. 测试方法（可复现）

- `_tmp/check_dashboard.py`：11 项静态断言（XAML/控件/事件挂载/热力图/提示零延迟/输出格式）+ 
  `-RenderTab/-RenderGran/-RenderPeriod` 无头渲染回归（整窗 PNG 存 TEMP）；
- `_tmp/robust_check.py`：33 项（语法/状态损坏/配置异常/字体缺失/大状态/日志裁剪/编码约定/关键标签恒在）；
- 模拟阶段完成：Python + ctypes 注册同名窗口类 `CatimeNotificationClass` 并显示/销毁即可驱动插件
  （需带消息泵避免查询阻塞）；
- 真实端到端：在 Catime 里跑一轮番茄钟确认存活与计数。

**已知坑（改代码前扫一眼）**：
- XAML 能解析 ≠ 渲染正确（`Stretch=Uniform` 多 Path 各自拉伸、TabControl 默认模板铬边遮圆角、
  WPF 无 `StrokeLineCap`）；
- 新增控件容易漏挂事件处理器（↑↓ 翻页、周期切换各漏过一次，静默失效）；
- 文字毛刺两类：半像素落点 → `UseLayoutRounding`+`SnapsToDevicePixels`；
  字形硬对齐阶梯 → 是 `TextFormattingMode=Display` 的代价，应保持 `Ideal` 平滑渲染；
- PS 函数返回可枚举对象（如 `PathSegmentCollection`）会被管道拆散 → 须 `Write-Output -NoEnumerate`；
- 安装后必须 `ls` 校验目录结构（一条 `cp` 带两个源 + 目录目标会把文件复制到根目录）。

## 11. 已知限制（Catime 无对应信号，无法根治）

- 普通倒计时结束与番茄阶段完成产生**相同**通知 → 普通倒计时也会被计为一次工作段
  （建议只在番茄钟模式下使用）；
- 番茄钟中途重置会使阶段索引短暂错位（多数情况能自纠正）；
- 番茄钟通知**文案不可改**（Catime 本地化字符串编译进 exe，从内嵌资源加载）；
- 统计图会随刷新累积遗留 PNG（Catime 永久锁定正在显示的图片，删不掉，每个约 2KB），
  **Catime 重启后自动清理**，属设计内自愈。

## 12. 图标来源

顶部卡片番茄图标采用 **TDesign tomato**（MIT License，Tencent/tdesign-icons，
24×24 线性描边）：SVG path 直转 XAML `PathGeometry` 内嵌，色 `#D94848`，零依赖。

## 13. 路线图 / 已否决

**候选（未排期）**：
- 脚本旁 `pomodoro_stats.ini` 暴露显示开关与图片字号，免改脚本；
- 中断检测：通知窗口消失后长时间无新阶段 → 判定番茄钟被手动中断；
- 数据导出 json → CSV；周起始日可配（周一/周日）；跨午夜的番茄段归属显式化。

**已否决（勿重做）**：
- 插件自写空闲时钟（与 Catime 自带时间必然重复）；
- 引入图表库（LiveCharts2 要求 .NET 6+，PS 5.1 跑不了；老版 LiveCharts 无热力图且停维护；
  OxyPlot 需带 DLL——全部违反零依赖红线。数据量小（折线 ≤30 点），WPF 自绘完全可控）；
- 面板自动拉起统计插件（Catime 单槽位，降级为保存后提示手动重启）；
- 读取/依赖 Catime 源码级信息（保持纯文件通信）；联网同步。
