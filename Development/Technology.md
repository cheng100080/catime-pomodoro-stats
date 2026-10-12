# 技术文档

> 分工见 Development.md：环境、配置结论、技术细节写这里；涉及对应模块时查。

## 1. 本机环境（实测）

| 项 | 值 |
|---|---|
| Catime 版本 | **v1.5.0**（`catime_1.5.0.exe`，32 位） |
| 程序本体 | `D:\app\app\catime_1.5.0.exe\catime_1.5.0.exe`（开机快捷方式指向此路径） |
| 数据/配置目录 | `%LOCALAPPDATA%\Catime\`（config.ini、Catime_Logs.log、resources\） |
| 插件目录 | `%LOCALAPPDATA%\Catime\resources\plugins\` |
| 界面语言 | 简体中文（`LANGUAGE=Chinese_Simplified`） |
| **PATH 异常** | **不含 `%SystemRoot%\System32\WindowsPowerShell\v1.0`**（详见 error.md E1），因此任何靠 PATH 找 `powershell.exe` 的调用都会失败 → 插件入口必须用 `.bat` + 绝对路径 |
| PATH 中可用的解释器目录 | `D:\app\app\Python\3.14.6\`（含 python/pythonw）、`D:\app\app\node-v24.18.1-x64`、Git、mingw64 等 |
| 上游参考源码 | `upstream/Catime`（浅克隆，可 `git show v1.5.0:路径` 查 v1.5.0 实现）、`upstream/Catime-Plugins`（官方插件仓库，含 `i18n/PLUGIN_GUIDE_zh-CN.md` 权威指南） |

## 2. Catime 插件机制（源码核对）

**加载**
- 插件目录下扫描脚本文件；白名单为**扩展名列表**（`include/plugin/plugin_extensions.h`，
  含 `*.bat *.cmd *.ps1` 等，**不含 `*.psm1`**），**递归扫描子目录**，不跳过隐藏文件。
- 解释器映射（v1.5.0 `src/plugin/plugin_process.c`）：`.ps1 → powershell.exe -NoProfile ... -File`、
  `.bat/.cmd → cmd.exe /c`、`.py/.pyw → pythonw.exe`、`.js → node.exe` 等。
- 首次运行弹"插件安全"信任框（`信任并运行` / `仅运行一次` / `取消`）；文件修改后会再问一次。
- 同时只能运行一个插件；Catime 用 **Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）**
  管理插件进程树 → Catime 退出/停插件时**整棵进程树被杀**（所以 `.bat` 套一层是安全的）。
- 停止插件：菜单里再点一次（带 ✓ 表示运行中）；另有热重载（文件变更后重跑）。

**output.txt 契约**
- 必须写在**被启动的插件文件同级目录**（Catime 用 `PluginData_SetOutputDirectoryFromPluginPath` 设定）。
- 编码 **UTF-8 无 BOM**；Catime 用 `FindFirstChangeNotification` 事件驱动监听 + 防抖读取。
- 支持标签：`<fps:N>`（刷新频率，默认 2）、`<catime></catime>`（渲染当前计时）、
  `<color:...>`、`<font:...>`、`<md>`、`![](图片)`、`<exit>N</exit>`、
  `<notify[:catime|os|modal][:超时ms]>消息</notify>`（插件触发通知）。
- **`<catime>` 标签有特殊语义：不带它的插件会在开始计时时被停掉**（见 error.md E2）。

**关键窗口类名**（v1.5.0 与最新版一致）
- 主窗口：`CatimeWindowClass`
- 通知弹窗：`CatimeNotificationClass`（标题 `Catime Notification`）
- 通知类型 `CATIME` 时，每个阶段完成都会创建该窗口；`NOTIFICATION_TIMEOUT_MS` 决定存活时长。

**缩放与位置（`config.ini [Display]`）**
- `WINDOW_SCALE`：正常时间显示的缩放；`PLUGIN_SCALE`：**插件模式的独立缩放档位**
  （渲染时 `PluginData_IsActive() ? PLUGIN_FONT_SCALE_FACTOR : CLOCK_FONT_SCALE_FACTOR`，
  `drawing_render.c:684`）。默认 `1.0`，因此插件显示常比正常时间小很多。
  数值直接作为字体乘数（`CalculateRenderFontSize = 基准字号 × scale`），窗口尺寸随之线性变化
  （本机实测：1.00→179×12、2.00→268×22、4.00→445×42、8.00→797×82）。
- 位置 `CLOCK_WINDOW_POS_X/Y` 两种模式共用（特殊值：X=-1 居中、61.8% 处等；Y=默认值 → 顶部），
  并有 `ClampWindowPositionToMonitor` 保证不出屏。在插件模式下缩放/拖动会写回 `PLUGIN_SCALE` 与位置。
- 本机：`WINDOW_SCALE=11.48`、`PLUGIN_SCALE` 由 1.00 → **4.00**（2026-10-12）。
- 插件文本支持标签：`<fps:N>` `<catime>` `<exit>N` `<color:>` `<font:路径>` `<md>` `![](图片)`
  —— **没有字号标签**，字号只能通过缩放的粒度控制。

**通知窗口（`config.ini [Notification]`）**
- 尺寸：`NOTIFICATION_WINDOW_WIDTH` 350~1600、`_HEIGHT` 48~900（`ClampNotificationWidth/Height`）；
  未配置时宽度按文本自动算、高度固定 80。
- 字号：`NOTIFICATION_FONT_SIZE` 是**窗口高度的百分比**，范围 10~60（60 即上限）→ 想放大字只能调高窗口高度。
- 位置：`NOTIFICATION_WINDOW_X/Y` ≥ 0 时用该**左上角绝对坐标**（**不做边界钳制**，给大了会出屏）；
  否则 `CalculateNotificationPosition` = 工作区右下角减 `NOTIFICATION_RIGHT/BOTTOM_MARGIN`(20)。
- **只有一行文字**（`NOTIFICATION_HEIGHT 80 — Fixed height accommodates single-line content`），
  字号 = 高度 × `NOTIFICATION_FONT_SIZE`(10~60%)，宽度上限 1600 →
  **高度变大 → 字号变大 → 长消息会被省略号截断**；要让长消息完整只能加宽 + 降低百分比。
  实测字符宽 ≈ 字号 × 0.464（本机 ProFont）。
- 本机原为 `350×80 @ (2190,1404)`（宽度正好是最小值，导致长消息截断）；
  2026-10-12 调整为 `1600×350`、`FONT_SIZE=23`（字号 ≈80px）、位置 `(940,855)`
  —— 实测长消息 `45m Pomodoro completed (Cycle1/1 Round 1/4)` 完整显示，且位于插件窗口上方约 215px。

## 3. 番茄钟语义（源码结论）

- `complete_pomodoro_cycles` 是**进程内内存变量**（`timer_events_state.c`），
  **不写 config.ini、不写日志、无 IPC** → 插件无法直接读取；且它数的是**整轮循环**。
- 每个阶段（工作/休息）结束**都会弹一次通知**（`TimerEvents_HandlePomodoroCompletion`
  由 `timer_events_main.c` 在每个区间结束时调用），整轮结束再额外通知一次
  （`All Pomodoro cycles completed!`）。→ "每阶段提醒一次"是 Catime 原生行为。
- 阶段序列来自 `config.ini [Pomodoro] POMODORO_TIME_OPTIONS`（**秒**，逗号分隔，
  本机为 `2700,600,2700,1200`），索引 0 起始为工作阶段，工作/休息按序交替。
- 开始计时/启动番茄钟会触发 `CleanupBeforeTimerAction`（见 error.md E2）。

## 4. 本插件的技术决策（改动需谨慎）

| 决策 | 内容与理由 |
|---|---|
| 语言 | PowerShell 5.1（系统自带、零依赖、单进程常驻；BAT 做日期运算/Win32 调用不现实） |
| 入口 | `.bat` + 绝对路径解释器（绕开 PATH 缺项，见 E1） |
| 检测 | 500ms 轮询 `EnumWindows + GetClassName` 找 `CatimeNotificationClass` **新句柄**（见 E3-1） |
| 分类 | 阶段序列 + **间隔匹配自纠正**（用两次完成的间隔反推阶段） |
| 阶段类型判定 | `$PhaseTypes` 模板（`'WBWB'`，W=工作/B=休息，逐段对应序列）。留空 = 自动模式（第 1、3、5… 段 = 工作）。**前提事实：Catime 不记录工作/休息属性**——`current_pomodoro_phase` 只会是 `IDLE`/`WORK`（`BREAK`/`LONG_BREAK` 枚举从未使用），通知文本只含时长与轮次，故只能靠约定推断。模板长度与序列不一致 → 自动回退 + 记日志。曾评估"按时长推断"（长=工作）并否决：经典 `25 5 25 5 25 5 25 30` 的最长段是长休息会误判 |
| 计数口径 | `$CountUnit = 'work'`（**用户 2026-10-12 定案**：每完成一个工作阶段计 1 个，即正统番茄工作法口径）。另有 `'cycle'`（整轮含休息计 1，Catime `complete_pomodoro_cycles` 口径），改一行即可切换，两种口径各测 6/6 |
| 新会话判定 | 间隔 > 2×最长阶段 + 300s → 视为重新开始，刚完成的算第 1 个（工作）阶段 |
| 持久化 | 脚本同级 `pomodoro_stats.json`（原子写：临时文件 + `Move-Item`），明细保留 400 天 |
| 显示 | `<fps:1>T{今日} W{本周} [M{本月}] [A{累计}]  <catime></catime>`；M/A 默认不显示但照常统计（开关 `$ShowWeek/$ShowMonth/$ShowTotal`） |
| 显示模式 | `$TimerDisplayMode`：`'timer'`（默认，推断计时期间只显示计时）/ `'both'`（始终"统计+计时"）。**Catime 不提供"计时开始"信号**（计时开始不写 config、不建窗口、无 IPC，已核对 v1.5.0 源码），故 `'timer'` 只能靠"上次完成 + 段时长"推断 → 第 1 段切不了、手动中断后要等该段预期结束才恢复统计 |
| 窗口贴角 | `$PluginAnchor`（默认 `'bottomright'`）：插件运行时用 `SetWindowPos` 把 Catime 窗口贴到工作区角落，退出后恢复正常位置。**实测：外部进程可移动 Catime 窗口，且 Catime 不会拉回**（移到别处 6 秒无反应）→ 因此可实现"插件模式独立位置"，弥补 `CLOCK_WINDOW_POS_X/Y` 两模式共用的限制。仅在窗口尺寸变化时重贴，不与手动拖动打架 |
| 门禁 | `NOTIFICATION_TYPE != CATIME` → 显示 `SET CATIME` 且不计数 |
| 日志 | `pomodoro_stats.log`：启动参数、每次计数、循环异常（同类只记一次，>64KB 重建） |
| 资源占用 | 每 500ms 一次 `EnumWindows`（微秒级）；仅事件发生时写盘；无网络 |

**已知限制**：普通倒计时完成与番茄阶段完成会产生**相同**的通知，无法从外部区分
→ 会被计为一次工作阶段（建议只在番茄钟模式下使用）；番茄钟中途重置会使阶段索引
短暂错位（多数情况可自愈）。

## 5. 产物位置（工作区外，按 Development.md「存储偏好」告知）

| 路径 | 内容 | 性质 |
|---|---|---|
| `%LOCALAPPDATA%\Catime\resources\plugins\pomodoro_stats.bat` | 插件入口 | 必须放 C 盘（Catime 约定位置） |
| `%LOCALAPPDATA%\Catime\resources\plugins\pomodoro_stats_core.ps1` | 插件逻辑 | 同上 |
| 同目录 `output.txt` / `pomodoro_stats.json` / `pomodoro_stats.log` | 运行期产物（显示内容/统计/日志） | 可随时删除 |
| `%TEMP%\catime_dbg*.log`、`%TEMP%\path_dump.txt` | 诊断过程产生的临时文件 | 可清理 |
| `upstream/Catime`、`upstream/Catime-Plugins` | 上游源码浅克隆（gitignore） | 仅本地参考 |

> 配置备份：`_tmp/config.ini.bak2`（改动前的原文件）、`_tmp/_tmp_flag_pre_catime.bak`。
> 当前 `NOTIFICATION_TYPE` 已被改为 `CATIME`（为测试/让插件可用），需恢复时用上述备份。

## 6. 测试方法（可复现）

测试脚本与结果都在 `_tmp/`，按 `前置 → 启动 → 驱动` 三段式：

- **模拟 toast**：Python + ctypes 注册同名窗口类 `CatimeNotificationClass` 并显示/销毁，
  即可驱动插件（见 `_tmp/pop_pump.py`；带消息泵，避免查询被阻塞）。
- **启动插件**：用 PowerShell 工具的 `run_in_background` 跑**有界副本**
  （`while ($true)` → `for ($ti=0; $ti -lt 240; $ti++)`，约 120s 自动退出）。
- **分层结果**：Phase A（模拟：分类/自纠正/周统计/门禁）19/19、
  Phase C（.bat 入口链路）4/4、Phase D（`<catime>` 标签 + 日志 + 计数）6/6、
  Phase E（cycle 口径，序列 8s/4s）6/6、Phase F（序列 8,4,8,4,8 = 3 个工作段，
  work 口径边跑边计）9/9 均通过；
  Phase B（真实 Catime 端到端）因无法稳定自动触发倒计时而未闭环 → 已由用户实机确认成功
  （2026-10-12 20:34-20:44：插件存活并计数 3 次，界面显示 `T3 W3 A3`）。
