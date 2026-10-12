# 准备 Phase A 测试环境：隔离目录 + 自有 config.ini + 有界循环插件副本（240 tick x 500ms = 120s）
import json, os, shutil

BASE = r"D:\files\works\20051012CatTime插件"
TMP = os.path.join(BASE, "_tmp")
TESTDIR = os.path.join(TMP, "testA", "Catime", "resources", "plugins")
CFGDIR = os.path.join(TMP, "testA", "Catime")
REAL_CONFIG = os.path.expandvars(r"%LOCALAPPDATA%\Catime\config.ini")

if os.path.exists(os.path.join(TMP, "testA")):
    shutil.rmtree(os.path.join(TMP, "testA"))
os.makedirs(TESTDIR)

# 用户真实 config 改写为测试专用：短阶段序列 8s/4s + CATIME 通知
cfg = open(REAL_CONFIG, encoding="utf-8").read()
cfg = cfg.replace("NOTIFICATION_TYPE=OS", "NOTIFICATION_TYPE=CATIME")
cfg = cfg.replace("POMODORO_TIME_OPTIONS=2700,600,2700,1200", "POMODORO_TIME_OPTIONS=8,4,8,4")
open(os.path.join(CFGDIR, "config.ini"), "w", encoding="utf-8", newline="").write(cfg)

# 插件副本：while ($true) -> for ($ti=0; $ti -lt 240; $ti++)，其余逐字节一致
src = open(os.path.join(BASE, "pomodoro_stats.ps1"), "rb").read()
assert src.count(b"while ($true) {") == 1
dst = src.replace(b"while ($true) {", b"for ($ti = 0; $ti -lt 240; $ti++) {")
open(os.path.join(TESTDIR, "pomodoro_stats.ps1"), "wb").write(dst)
print("prep done:", TESTDIR)
print("config type:", [l for l in cfg.splitlines() if "NOTIFICATION_TYPE" in l])
print("config pattern:", [l for l in cfg.splitlines() if "POMODORO_TIME_OPTIONS" in l])
