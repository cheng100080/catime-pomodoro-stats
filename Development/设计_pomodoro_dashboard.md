# 设计方案：pomodoro_dashboard 显示插件（v1 修订版，已批准执行）

> 修订记录（用户意见，2026-10-13）：
> 1. 砍掉自动拉起统计插件 → 降级为"保存后提示用户手动重新点统计插件"
> 2. 砍掉强调色读取 config.ini → v1 用固定深色 + 固定强调色

## 1. 背景与目标

统计插件（pomodoro_stats）已跑通，持久化在同目录 `pomodoro_stats.json`。
本插件是它的搭档：弹窗展示统计（今日 / 本周 / 累计 / 近 7 天每日），
支持人工校准数值并保存回同一份 json。

## 2. 命名与目录

```
%LOCALAPPDATA%\Catime\resources\plugins\
├── pomodoro_stats_launcher.bat      （统计插件入口，现有，不动）
├── pomodoro_stats_core.ps1          （统计插件逻辑，现有，不动）
├── pomodoro_stats.json|log|output.txt|stats_*.png
└── pomodoro_dashboard\              （新增子目录，避免菜单与文件冲突）
    ├── pomodoro_dashboard_launcher.bat   （入口：定位解释器绝对路径 → 调 core）
    └── pomodoro_dashboard_core.ps1       （逻辑：读 json → WPF 面板 → 校准保存）
```

- 菜单会列出 2 个条目，用户点带 `_launcher` 的那个（两个插件同理）。
- 本机 PATH 缺 WindowsPowerShell 目录 → 入口必须 `.bat`（cmd.exe 必然可找到），
  内部用绝对路径调解释器（error.md E1），并加 `-STA`（WPF 需要）。

## 3. 数据源与路径解析

数据文件：统计插件脚本旁的 `pomodoro_stats.json`，结构：

```json
{"version":1, "total":51, "phase":0, "lastEvent":"...",
 "days":{"2026-10-13":8, "2026-10-12":43}}
```

面板按两级候选解析（第一个存在的生效）：
1. `<面板脚本目录>\..\pomodoro_stats.json`（相对，覆盖默认安装布局）
2. `%LOCALAPPDATA%\Catime\resources\plugins\pomodoro_stats.json`（绝对兜底）

## 4. 校准粒度（核心设计决定）

**编辑单位 = 近 7 天每日计数（含今天，第一行标"今天"）+ 累计（total）。**

- `今日` = `days[今天]`（就是 7 天列表第一行，可编辑）
- `本周` = **只读**，由 days 中属于本周（周一起）的日期现算——它不是存储字段，
  独立编辑必然导致数据不自洽
- `version` / `phase` / `lastEvent` **原样保留不展示、不可编辑**
  （phase 被改动会打乱统计插件的阶段索引判定）
- 输入校验：非负整数，非法输入红框提示且不保存

## 5. 写冲突防护

事实依据：Catime **同时只能运行一个插件**（Technology.md:26）；
统计插件**只在启动时读一次** json，之后用内存副本整份写回。

| 场景 | 防护 |
|---|---|
| 从 Catime 菜单启动面板 | 单槽位自动停掉统计插件，天然无冲突 |
| 从资源管理器直启面板（统计插件仍在跑） | ① 窗口顶部固定提示"若统计插件正在运行，请先停止"；② 写入用**原子写**（临时文件 + Move-Item -Force，与统计插件同款） |
| 读取时恰逢统计插件写回 | try/catch + 2 次重试（间隔 100ms） |

## 6. UI（WPF，零依赖；固定深色主题）

`PresentationFramework` 为 Windows 自带 .NET 组件，**无任何安装依赖**。
配色全部固定，**不读 config.ini**（v1 修订）：

- 无边框深色卡片窗口（宽 480，高度自适应内容，圆角 12px，底色 #1E2430）
- 标题栏：`Pomodoro Dashboard` + **固定强调渐变 #89F7FE→#66A6FF**，可拖动；右上角 ✕
- 概览区：今日 / 本周(只读) / 累计 三张数字卡片（本周为派生值）
- 7 天编辑区：7 行 `[MM-dd 周几(今天) | 输入框]`，无记录的日期显示 0
- 累计编辑行：1 个输入框
- 底部按钮：**[保存]**（主）＋ [取消]；保存结果显示在窗口底部状态栏
- 中文字体：微软雅黑（系统自带）；窗口文案中文，Catime 窗口内显示英文

## 7. 保存与提示（v1 修订：无自动拉起）

```
用户点「保存」
 1. 校验全部输入（非负整数；非法 → 红框 + 状态栏提示，不保存）
 2. 原子写 json（version/phase/lastEvent 原样带回，临时文件 + Move -Force）
 3. output.txt 写：Saved. Restart Stats.  <catime></catime>
 4. 状态栏显示（绿色）：已保存。请手动重新运行统计插件
    （pomodoro_stats_launcher）使修改生效。
 5. 窗口保持打开，用户阅后自行关闭（✕ / 取消）
```

- 保存成功前面板存活期间 output.txt 为 `Dashboard  <catime></catime>`。
- 统计插件重启后接管 output.txt，显示自然过渡回统计。
- json 不存在 / 损坏：面板正常弹出但显示"未找到统计数据…"提示，
  编辑区与保存按钮禁用，不崩溃；output.txt 写 `No Stats Data  <catime></catime>`。

## 8. Catime 窗口显示

面板存活期间 output.txt 固定英文（ASCII，避免精简字体缺中文字形；
**必须带 `<catime></catime>`**，缺了会在用户开始计时时被杀）：
- 正常：`Dashboard`；保存成功后：`Saved. Restart Stats.`；无数据：`No Stats Data`

## 9. 仓库结构（发布形态，本次只新增 dashboard 部分）

```
仓库根/
├── README.md               （安装说明：把对应文件夹内容复制进 plugins 目录）
├── pomodoro-stats/         （统计插件 2 文件——本次不挪，发布前整理项）
└── pomodoro-dashboard/     （显示插件 2 文件，本次新增）
```

注：统计插件路径全是 `$PSScriptRoot` 相对，**将来**挪进子目录功能不受影响，
但它的 json 需手动迁移一次（否则计数归零）——记入 README 发布注意事项，本次不动。

## 10. 硬性约定（沿用统计插件，缺一不可）

- `.ps1` UTF-8 带 BOM + 纯 CRLF；`.bat` 纯 CRLF + 注释全 ASCII
- 不改统计插件、不改 Catime 源码；不联网、无第三方依赖、不写死机器相关绝对路径
- 每个任务完成提交一次 git；重大节点打 tag

## 11. 验收标准（实现完成的定义）

1. 菜单点 launcher → 信任 → 弹出深色面板，今日/本周/累计/近 7 天为真实数据
2. 改"今天"格与累计 → 保存 → json 原子更新；今日/累计变化；本周自洽；
   phase/lastEvent/version 与改前一致；output.txt 变为 Saved. Restart Stats.
3. 面板状态栏出现"请手动重新运行统计插件"提示（v1 无自动拉起）
4. 删除/改坏 json → 面板显示提示、编辑区禁用、不崩溃
5. 面板打开期间统计插件已停（单槽位验证）
6. 自检通过：语法解析 OK、BOM/CRLF/ASCII 约定、json 异常场景（selftest 验证）

## 12. 明确不做（v1 边界）

- 不做自动拉起统计插件（v1 修订：砍掉，降级为保存后提示手动重启）
- 不做图表/历史曲线（v2 再议）
- 不做"仅保存不关闭"等多按钮变体
- 不做 json 手动重载 / 文件监听
- 不做超过 7 天的日期编辑
- 不读 config.ini（配色固定）
