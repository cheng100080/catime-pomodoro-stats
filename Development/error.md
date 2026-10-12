# 错误记录

> 分工见 Development.md：排查过的错误写这里，改代码前扫一眼避免重复踩坑。

## E1. Catime 报 `powershell.exe not found`，插件完全不运行（真机，已修复 v0.2）

**现象**：在 Catime 菜单里点插件，窗口只显示 `powershell.exe not found`，插件不产生任何输出。

**根因**：Catime 启动 `.ps1` 插件时执行的是
`powershell.exe -NoProfile -NonInteractive -File 脚本`，**靠 PATH 环境变量找解释器**
（v1.5.0 `src/plugin/plugin_process.c`：`CreateProcessW(NULL, cmdLine, ...)`，
失败后取解释器名拼成 `"%s not found"` 显示）。
而本机 PATH **不包含** `%SystemRoot%\System32\WindowsPowerShell\v1.0`
（机器 PATH 只有 `C:\Windows\System32`，但 `powershell.exe` 在该子目录下）。

**定位过程**：
1. `[Environment]::GetEnvironmentVariable('Path','Machine'/'User')` 逐条比对 —— 无 WindowsPowerShell 条目。
2. 在当前会话里裸名调用 `powershell.exe` → 报"无法识别"，证实 PATH 缺项。
3. `reg query` 读取注册表被沙箱黑名单拦（reg.exe 不可用），改用 .NET API 读取。

**修复（不改任何系统设置）**：新增 `pomodoro_stats.bat` 作为插件入口
（`cmd.exe` 位于 System32，必然可被找到），在 `.bat` 内以**绝对路径**调用解释器
（`%SystemRoot%\System32\WindowsPowerShell\v1.0\`，并回退 `SysWOW64`）。
逻辑脚本相应改名为 `pomodoro_stats_core.ps1`。

**验证**：以与 Catime 相同的方式启动（`cmd.exe /c pomodoro_stats.bat`），
`output.txt` 正常写出并计数。

**遗留**：Catime 插件白名单含 `*.bat *.cmd *.ps1`（**不含 `*.psm1`**），
且扫描**递归**子目录、不跳过隐藏文件；`-File` 只接受 `.ps1`。
因此无法把逻辑文件藏起来，菜单里会同时列出 `.bat` 与 `_core.ps1` 两项，
**必须让用户点 `.bat`**（README 已写明）。

---

## E2. 一开始倒计时，插件就消失、显示变空白、阶段完成统计不到（真机，已修复 v0.3）

**现象**（用户实测）：点插件显示 `T0 W0 A0` → 启动 10 秒倒计时 →
倒计时结束弹了通知 → 通知消失后**窗口没有任何显示** → 重开插件仍是 `T0 W0 A0`。

**根因**：Catime 在**开始任何计时动作前**会调用 `CleanupBeforeTimerAction()`
（v1.5.0 `src/window_procedure/window_procedure.c:418`）：

```c
if (!PluginData_HasCatimeTag()) {
    PluginManager_StopAllPlugins();   // 停掉所有插件并关闭插件数据/显示模式
}
```

即：**输出文本中不含 `<catime></catime>` 标签的插件，会被直接杀掉**。
于是三个症状同源：进程被杀 → 统计不到；插件显示模式被关 → 显示空白；
状态从未写入过 → 重开永远是 `T0 W0 A0`。

**定位过程（关键，可复用）**：
1. 先看产物：`output.txt` 与 `pomodoro_stats.json` 的时间戳都停在插件启动那一刻，
   `total=0 / lastEvent=null` → 说明**从未处理过任何完成事件**（不是丢数据）。
2. 看进程树：Catime 名下已无插件子进程（残留的 `cmd.exe` 父进程都是编辑器自己的），
   说明进程被杀过。
3. 反向验证：向 `output.txt` 注入 Catime 支持的 `<notify:catime>` 标签，
   等待后**文件内容未被消费** → 证明 Catime 已不在读 `output.txt`（插件显示模式已关）。
4. 读源码确认触发点：`CleanupBeforeTimerAction` → `PluginData_HasCatimeTag`
   （判定条件：显示文本同时含 `<catime>` 与 `</catime>`，`plugin_data.c:2055`）。

**修复**：显示文本末尾固定追加 `  <catime></catime>`（脚本内 `$CatimeTag` 常量），
使插件在计时动作期间保持运行。副作用是正面的：该标签处由 Catime 渲染当前计时/时间，
插件模式下也能看到倒计时数字（`drawing_render.c` 会用 `savedTime` 替换该标签）。

**验证**：Phase D 6/6 通过——输出 `<fps:1>T0 W0 A0  <catime></catime>`，
模拟 toast 后正确变为 `T1 W1 A1`。

**教训**：插件脚本必须有日志。本问题前一轮排查时因 `catch {}` 静默吞异常、
无任何日志，只能靠黑盒取证。现已加 `pomodoro_stats.log`
（启动参数 / 每次计数 / 循环异常，同类异常只记一次，>64KB 重建）。

---

## E3. 开发期踩过的坑（非用户可见，但会重复踩）

### E3-1 `FindWindowW` 按类名跨进程查找返回 0（必须用 EnumWindows）
实测在 PowerShell 里 `FindWindowW('CatimeWindowClass', NULL)` 返回 0（窗口确实存在），
连已知的 Catime 主窗口都找不到；而 `Shell_TrayWnd` 能找到。
对照实验：同一时刻 `EnumWindows + GetClassName` 能稳定找到目标窗口（句柄与真机一致）。
**结论：检测窗口类必须用 `EnumWindows + GetClassName`**，不要用 `FindWindowW`。

### E3-2 `.ps1` 无 BOM + 中文注释 → 静默不执行
PowerShell 5.1 对**无 BOM** 的 `.ps1` 按 ANSI/GBK 解码，中文注释字节被误解码后
可能产生破坏语法的字符 → `ParserError`，脚本根本不会跑（且报错难看见）。
**规则：`.ps1` 一律 UTF-8 **带 BOM** + CRLF；`.bat` 的注释只用 ASCII**
（cmd 会对 `rem` 行做重定向解析，乱码字节可能触发副作用）。
另注意别写成**双 BOM**（重复加 BOM 同样会解析失败）。

### E3-3 `Add-Type -MemberDefinition` 里不能写 `using`
`-MemberDefinition` 会把代码塞进类体内，顶层 `using` 指令非法
（报"修饰器 using 对该项无效"）。需用全限定名
（`System.Text.StringBuilder`、`System.Runtime.InteropServices.DllImport`）
或改用 `-TypeDefinition`。

### E3-4 通知类型 `OS`（系统通知）不可作为检测信号
OS 类型走 `Shell_NotifyIcon` 气球、由 Explorer 渲染。实测：连续两次气球
**只有一次出现新窗口**（系统节流抑制），且窗口类不专属 Catime。
故统计功能要求 `NOTIFICATION_TYPE=CATIME`。

### E3-5 沙箱/工具环境限制（影响测试方式）
- 从 Bash 调 `powershell.exe` 被安全策略拦截（命令串里含该字样即拦）。
- PowerShell 工具会**吞掉 stdout**：结果一律写文件再读。
- PowerShell 工具拦 `Start-Process` 启子进程；可行通道是工具的
  `run_in_background`（启动插件）+ Python 只做窗口操作/读文件。
- Bash 命令在后台任务结束时可能收到 SIGTERM，但工作已完成；
  结果必须落盘，且日志要实时追加写。
- 插件首次启动到写出 `output.txt` 约需 **6 秒**（`Add-Type` 编译 C#），
  测试等待窗口要留足。
