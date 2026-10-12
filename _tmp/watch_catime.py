# 诊断：监控 Catime 进程在倒计时完成前后创建的顶层窗口（类名/标题）
# 同时确认配置文件类型切换是否被运行中的实例接受
import ctypes, os, subprocess, sys, time
from ctypes import wintypes
from datetime import datetime

BASE = r"D:\files\works\20051012CatTime插件"
TMP = os.path.join(BASE, "_tmp")
REAL_CONFIG = os.path.expandvars(r"%LOCALAPPDATA%\Catime\config.ini")
BACKUP = os.path.join(TMP, "config.ini.bak2")
CATIME_EXE = r"D:\app\app\catime_1.5.0.exe\catime_1.5.0.exe"
LOG = os.path.join(TMP, "watch_result.txt")

def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {m}"
    print(line)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindowVisible.argtypes = [wintypes.HWND]

EnumProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def windows_of_pid(pid):
    out = []
    def cb(h, lp):
        p = wintypes.DWORD()
        user32.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid:
            c = ctypes.create_unicode_buffer(256); user32.GetClassNameW(h, c, 256)
            t = ctypes.create_unicode_buffer(256); user32.GetWindowTextW(h, t, 256)
            out.append((c.value, t.value, bool(user32.IsWindowVisible(h))))
        return True
    user32.EnumWindows(EnumProc(cb), 0)
    return out

if len(sys.argv) > 1 and sys.argv[1] == "setcatime":
    import shutil
    shutil.copy2(REAL_CONFIG, BACKUP)
    data = open(REAL_CONFIG, "rb").read()
    assert data.count(b"NOTIFICATION_TYPE=OS") == 1
    open(REAL_CONFIG, "wb").write(data.replace(b"NOTIFICATION_TYPE=OS", b"NOTIFICATION_TYPE=CATIME"))
    log("已临时切换 NOTIFICATION_TYPE=CATIME（已备份）")
    sys.exit(0)

if len(sys.argv) > 1 and sys.argv[1] == "restore":
    import shutil
    shutil.copy2(BACKUP, REAL_CONFIG)
    log("已还原 config.ini")
    sys.exit(0)

open(LOG, "w").close()
# 找到 Catime 主窗口 PID
pid = None
for c, t, v in [(c, t, v) for c, t, v in []]:
    pass
# 直接扫描：找 CatimeWindowClass
def find_cls(cls):
    res = [None]
    def cb(h, lp):
        c = ctypes.create_unicode_buffer(256); user32.GetClassNameW(h, c, 256)
        if c.value == cls:
            p = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(p))
            res[0] = (h, p.value)
            return False
        return True
    user32.EnumWindows(EnumProc(cb), 0)
    return res[0]

found = find_cls("CatimeWindowClass")
if not found:
    log("未找到 Catime 主窗口，退出")
    sys.exit(1)
_, pid = found
log(f"Catime PID = {pid}")

baseline = set((c, t) for c, t, v in windows_of_pid(pid))
log(f"基线窗口数={len(baseline)}: " + "; ".join(sorted(c for c, t in baseline)))

# 启动 10 秒倒计时
log("启动 CLI 倒计时 0:10")
r = subprocess.run([CATIME_EXE, "0:10"], capture_output=True, timeout=30)
log(f"CLI rc={r.returncode}")

seen = set(baseline)
deadline = time.time() + 35
while time.time() < deadline:
    for c, t, v in windows_of_pid(pid):
        key = (c, t)
        if key not in seen:
            seen.add(key)
            log(f"新窗口: class={c!r} title={t!r} visible={v}")
    time.sleep(0.15)
log("监控结束")
