# Catime 番茄钟统计插件（pomodoro_stats）

在 Catime 窗口实时显示**今日 / 本周 / 累计**完成的番茄数，数据持久化，Catime 重启不丢失。

```
T3 W12 A57        T = 今日(Today)   W = 本周(Week，周一起算)   A = 累计(All)
```

---

## 安装

1. 把这两个文件一起复制到 Catime 插件目录：

   ```
   %LOCALAPPDATA%\Catime\resources\plugins\
   ```

   | 文件 | 作用 |
   |---|---|
   | **`pomodoro_stats.bat`** | **启动入口 —— 在 Catime 菜单里点这个** |
   | `pomodoro_stats_core.ps1` | 真正的统计逻辑（不要点它） |

   （也可以托盘右键 → `插件` → `打开插件文件夹` 打开该目录）

2. 托盘图标右键 → `插件` → 点击 **`pomodoro_stats.bat`** → 首次运行选 **「信任并运行」**。

3. 窗口即显示统计数字。脚本顶部的 `$LabelToday / $LabelWeek / $LabelTotal` 可改显示标签。

> **前置条件：Catime 的通知类型必须是 `CATIME`（默认值）。**
> 在 Catime 设置里：托盘右键 → `通知设置` → `通知方式` → 选 **「Catime通知窗口」**；
> 或直接编辑 `%LOCALAPPDATA%\Catime\config.ini` 中的 `NOTIFICATION_TYPE=CATIME`。
> 若为 `OS`（操作系统通知）或 `SYSTEM_MODAL`，插件无法可靠感知阶段完成事件，
> 会显示 `SET CATIME` 提示而不计数。原因见下文「为什么必须用 CATIME 通知类型」。

### 为什么要多一个 `.bat` 入口？

Catime 启动 `.ps1` 插件时执行的是 `powershell.exe -NoProfile ... -File 脚本`，**靠 PATH
环境变量找 `powershell.exe`**。而 `powershell.exe` 位于
`%SystemRoot%\System32\WindowsPowerShell\v1.0\`，不在 `System32` 根目录——如果系统 PATH
里缺少这一项（有些机器/精简系统会缺），Catime 就会报 **`powershell.exe not found`**，
插件根本不会运行。

`cmd.exe` 位于 `System32`，一定找得到，所以用一个 `.bat` 入口、在里面对 PowerShell
使用**绝对路径**调用，即可绕开该问题、且不依赖任何系统设置改动。

## 依赖

- Windows 10/11 自带的 **PowerShell 5.1**（无需安装任何第三方组件、无需联网）
- Catime（在 v1.5.0 与最新版上均已核对插件与通知机制）

## 数据文件

- `pomodoro_stats.json`：与脚本同目录，保存累计数、每日明细与阶段索引。
  删除该文件即可把统计清零。
- `output.txt`：与脚本同目录，Catime 实时读取该文件用于显示。
- 明细超过 400 天的旧记录会被自动清理。

## 工作原理

1. Catime 每完成一个番茄钟阶段（工作或休息）都会弹一次通知。当通知类型为
   `CATIME` 时，该通知是一个窗口类名为 `CatimeNotificationClass` 的置顶弹窗。
2. 插件每 500 ms 用 `EnumWindows + GetClassName` 检测该窗口是否新出现
   （出现新窗口 = 一个阶段刚刚完成）。该机制经实测比 `FindWindowW` 按类名
   查找更可靠——`FindWindowW` 对非本进程注册的窗口类会返回 0。
3. 结合 `config.ini` 里 `[Pomodoro] POMODORO_TIME_OPTIONS` 的阶段序列，判断
   刚完成的是工作阶段还是休息阶段，**仅工作阶段计数**（即"完成一个阶段"计一个番茄，
   而不是完成整个循环才计）。
4. 为抵抗阶段索引漂移，插件优先用"距上次完成事件的间隔"匹配阶段时长来反推
   刚完成的是哪个阶段；匹配失败时回退到顺序索引；间隔远超任何阶段时长时
   视为开始了新一轮番茄钟。

### 资源占用

常驻一个 PowerShell 进程（Windows 自带），每 500 ms 一次系统调用级的窗口枚举，
无网络访问、无第三方依赖；仅在阶段完成时写一次状态文件，Catime 侧读取
`output.txt` 本身是事件驱动的。

## 为什么必须用 CATIME 通知类型

- Catime 的 `complete_pomodoro_cycles` 只是进程内的内存变量，既不写
  `config.ini` 也不写日志，插件（只通过文件通信）无法直接读取。
- 通知类型为 `CATIME` 时，阶段完成会产生可稳定检测的专属窗口类
  （`CatimeNotificationClass`，v1.5.0 与最新版一致）。
- 通知类型为 `OS` 时，Catime 走的是 `Shell_NotifyIcon` 系统气球，由 Explorer
  渲染，实测**不稳定**：系统会对短时间内重复的气球做节流抑制，且窗口类不专属
  于 Catime，无法作为可靠信号。

## 已知限制

- 使用**普通倒计时**（非番茄钟模式）时，倒计时结束也会弹出同款通知，会被计为
  一次工作阶段完成。建议只在番茄钟模式下使用本插件。
- 番茄钟中途停止再重新开始，阶段索引可能短暂错位，通常会在下一次完成时自纠正。
- Catime 关闭通知（`NOTIFICATION_DISABLED=TRUE`）或通知类型非 `CATIME` 时无法计数。

## 手动验证（约 1 分钟）

1. 确认通知类型为 `CATIME`（见上文前置条件）。
2. 托盘图标**右键** → **`插件`** → 点击 **`pomodoro_stats.bat`** → 弹窗里选 **「信任并运行」**
   （菜单里还会有一个 `pomodoro_stats_core.ps1`，那是逻辑文件，**不要点它**）。
   窗口应显示 `T0 W0 A0`（或已有数据）。
3. 快速触发一次"阶段完成"：**左键**单击托盘图标 → 在「倒计时」输入框输入 **`10s`** 回车
   （倒计时结束弹出的通知与番茄钟阶段完成时完全相同，会被计为 1 个工作阶段）。
   也可以走真实番茄钟，但默认阶段是 45 分钟，太久。
4. 窗口数字应从 `T0 W0 A0` 变为 `T1 W1 A1`（休息阶段完成时数字不变）。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 窗口显示 `powershell.exe not found` | 误点了 `pomodoro_stats_core.ps1`。点 `pomodoro_stats.bat` 那个入口 |
| 窗口显示 `SET CATIME` | 通知类型不是 `CATIME`（见上文前置条件）；改完保存即生效 |
| 通知弹出了但数字不动 | 插件没在运行：托盘右键 → `插件`，确认 `pomodoro_stats.bat` 前有 ✓ |
| 菜单里列出两个 `pomodoro_stats*` | 正常，`.bat` 是入口，`..._core.ps1` 是逻辑文件 |
| 想清零统计 | 删除插件目录下的 `pomodoro_stats.json` |

## License

Apache-2.0（与 Catime 及其官方插件仓库一致），见 [LICENSE](LICENSE)。
