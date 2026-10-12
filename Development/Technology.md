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
| 分类 | 阶段序列 + **间隔匹配自纠正**（用两次完成的间隔反推阶段），工作阶段才计数 |
| 新会话判定 | 间隔 > 2×最长阶段 + 300s → 视为重新开始，刚完成的算第 1 个（工作）阶段 |
| 持久化 | 脚本同级 `pomodoro_stats.json`（原子写：临时文件 + `Move-Item`），明细保留 400 天 |
| 显示 | `<fps:1>T{今日} W{本周} A{累计}  <catime></catime>`；标签可在脚本顶部改 |
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
  Phase C（.bat 入口链路）4/4、Phase D（catime 标签 + 日志 + 计数）6/6 均通过；
  Phase B（真实 Catime 端到端）因无法稳定自动触发倒计时而未闭环 → 需用户手动验证。
