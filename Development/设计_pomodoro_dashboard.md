# 设计方案：pomodoro_dashboard 显示插件（v1 修订版，已批准执行）

> 修订记录（用户意见，2026-10-13）：
> 1. 砍掉自动拉起统计插件 → 降级为"保存后提示用户手动重新点统计插件"
> 2. 砍掉强调色读取 config.ini → v1 用固定深色
> 3. v1.1 浅色卡片风重构（图吧工具箱风格）、按钮编辑后才出现、底部统一提示
> 4. v1.2 概览加"本月"卡片、整体缩小更接近正方形
> 5. v1.3 累计改为派生只读（=明细合计），保存时重写 json.total——
>    修复"手动改每日数后累计对不上" + 固定强调色

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

**编辑单位 = 近 7 天每日计数（含今天，第一行标"今天"）。其余全部派生。**

- `今日` = `days[今天]`（就是 7 天列表第一行，可编辑）
- `本周` / `本月` = 由 days 现算（周一起 / 自然月），只读
- `累计` = **派生只读**（= 全部每日明细合计）。v1.3 修订：原设计允许独立编辑
  累计，但用户实测"手动改每日数后累计对不上"（16+43=59 vs 累计=57）——
  累计与每日明细本应永远一致（统计插件每次都是两个一起 +1），独立编辑入口
  必然产生不一致。保存时同步重写 json 的 total，统计插件显示的累计自动跟随。
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

## 13. 已规划待办（用户主导排期，未开工）

### V2 方向：多标签页
面板计划扩展为多标签页：**概览 / 热力图 / 趋势**，热力图（近 7 天/更长时间的
每日完成度格子）作为 V2 第一个落地功能。开工时间由用户决定。

### 图表库选型结论（2026-10-13 已定：自绘原生 WPF，不用图表库）

评估对象：LiveCharts2 / LiveCharts 0.9 / OxyPlot / ScottPlot / WinForms Chart /
WebView2+ECharts / 自绘。标准：WPF 可用、轻量（零安装依赖）、现代质感、支持热力图+折线。

**决定：自绘（Canvas/UniformGrid + Polyline/Path），不引入任何图表库。**

理由：
1. **硬约束一票否决**：项目红线"只依赖 Windows 自带组件、不引入第三方依赖"。
   所有现成图表库都要随插件携带 DLL——LiveCharts2 甚至要求 .NET 6+（PS 5.1 跑不了），
   老版 LiveCharts 无热力图且已停维护；WebView2 运行时虽自带但 SDK DLL 仍需携带。
2. **数据规模太小**：热力图 ≤ 几百个格子、折线 ≤ 30 个点，图表库是杀鸡用牛刀。
3. **质感完全可控**：直接复用 v1.1 浅色卡片配色（#F7F5F0/#FFFFFF/#ECE8E0 +
   accent 渐变），与现有界面同源，不会有"第三方库默认画风"的违和。
4. **实现成本可控**：热力图 = UniformGrid + Border 矩阵（完成度→accent 透明度映射 +
   ToolTip）；折线 = Canvas + Polyline + 网格线 + 日期轴 + 圆点 ToolTip。
   各约 100~150 行，无版本/兼容/维护负担。

**备选（仅当用户放宽零依赖约束时启用）**：OxyPlot（支持 .NET Framework、
HeatMapSeries+LineSeries 齐全、维护活跃）——但需随插件带 2 个 DLL，违反红线，搁置。

V2 实现时按此结论执行，不再重新评估（除非用户明确放宽依赖约束）。

### V2/V3 视觉参考（用户指定，仅参考不移植代码）
- **趋势折线**：ECharts line-bump（https://echarts.apache.org/examples/zh/editor.html?c=line-bump）
  参考点：平滑曲线、圆点、淡色网格、端标签、适中线宽
- **热力图**：ECharts heatmap-punchcard（https://echarts.apache.org/examples/zh/editor.html?c=heatmap-punchcard）
  参考点：格子矩阵、颜色深浅映射数值、悬停提示、颜色条
- 一律用 WPF 原生自绘实现（§13 选型结论），配色与 v1 浅色卡片同源

### 图标调研结论（2026-10-13 实证）
- **TDesign 有 tomato**（MIT，24×24 线性描边，几何极简）——四库之外新增来源的
  最佳候选，SVG 已取回（`_tmp/icons/tdesign_tomato.svg`）
- Tabler / Lucide / Font Awesome Free **均无** tomato（404 实证；
  FA 的 tomato 为 Pro 专属，非 Free）；四库 strawberry 皆无
- SVG Silh / SVG Repo / Iconfont：本轮未能实证（官网 404/验证页拦截/需账号）
- 替代方案：Tabler/Lucide/TDesign 的 apple、cherry 均有（线性描边）；
  相似度 apple 中高（圆果+蒂）、cherry 中（双果需取舍）
- 候选 SVG 与对比预览在 `_tmp/icons/`（preview_extended.html）

### 顶部卡片番茄图标（v1.4 已实现：TDesign tomato）
- 已采用 **TDesign tomato**（MIT，24×24 线性描边）：SVG path 直转 XAML
  `PathGeometry` 资源（TomatoBody/TomatoStem），四卡片数字后 15px 图标，
  色 #D94848，零依赖。License 备案：MIT，Tencent/tdesign-icons。
- WPF 注意：`Path` 无 SVG 的 `StrokeLineCap` 属性，用
  `StrokeStartLineCap`/`StrokeEndLineCap` 替代。

### 已实现注意点（v1.4，后续 V3 折线图必须遵守）
- **派生视图必须在保存后刷新**：用户实测“保存校准后热力图不更新”已修
  （Update-Heatmap 重建）。V3 趋势折线图接入时，保存流程中必须同步调用
  折线视图的更新函数，不得只在启动时构建一次。
- 热力图为**相对色阶**：基准 = 当前 12 周窗口内最大值（透明度 0.25~0.75
  线性映射），避免历史单日极值压淡近期数据；如需绝对色阶再议。
- **内容**：顶部四张卡片（今日/本周/本月/累计）的数字后面加番茄图标作为单位，
  替换默认 emoji 或纯文本
- **图标来源**：用户自行寻找开源可商用 SVG（候选：Tabler Icons、Lucide、
  Font Awesome Free、Twemoji），并记录来源与 License（写入 README 或源码注释）
- **技术路线**：WPF 不直接支持 SVG → 转 XAML Path 直接嵌入，保持零依赖，
  尺寸与颜色可调
- **执行约定**：用户找到 SVG 并把 XAML 内容发来、或明确指示后再动手；
  在此之前任何人不要提前实现
