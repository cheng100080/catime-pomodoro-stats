# Phase B：真实 Catime 端到端测试
# 1. 备份 config.ini，临时将 NOTIFICATION_TYPE 改为 CATIME
# 2. 插件从 _tmp/testB 运行（配置回退到 %LOCALAPPDATA%\Catime\config.ini）
# 3. CLI 启动 8 秒倒计时 -> 真实 toast -> 验证检测与计数
# 4. 恢复 config.ini，验证 SET CATIME 提示
import ctypes, json, os, shutil, subprocess, sys, time
from ctypes import wintypes
from datetime import datetime

BASE = r"D:\files\works\20051012CatTime插件"
TMP = os.path.join(BASE, "_tmp")
TESTB = os.path.join(TMP, "testB")
REAL_CONFIG = os.path.expandvars(r"%LOCALAPPDATA%\Catime\config.ini")
BACKUP = os.path.join(TMP, "config.ini.bak")
CATIME_EXE = r"D:\app\app\catime_1.5.0.exe\catime_1.5.0.exe"
RESULTS = []

def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
    print(line)
    RESULTS.append(line)
    with open(os.path.join(TMP, "phaseB_result.txt"), "a", encoding="utf-8") as f:
        f.write(line + "\n")

def check(name, cond, detail=""):
    log(f"{'PASS' if cond else 'FAIL'}: {name} {detail}")

user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p)

class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("style", wintypes.UINT), ("lpfnWndProc", WNDPROC),
                ("cbClsExtra", ctypes.c_int), ("cbWndExtra", ctypes.c_int), ("hInstance", wintypes.HINSTANCE),
                ("hIcon", wintypes.HICON), ("hCursor", wintypes.HANDLE), ("hbrBackground", wintypes.HBRUSH),
                ("lpszMenuName", wintypes.LPCWSTR), ("lpszClassName", wintypes.LPCWSTR), ("hIconSm", wintypes.HICON)]

user32.DefWindowProcW.restype = ctypes.c_longlong
user32.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p]
user32.CreateWindowExW.restype = wintypes.HWND
user32.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
                                   ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, ctypes.c_void_p]
user32.RegisterClassExW.argtypes = [ctypes.POINTER(WNDCLASSEXW)]
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.DestroyWindow.argtypes = [wintypes.HWND]
user32.UnregisterClassW.argtypes = [wintypes.LPCWSTR, wintypes.HINSTANCE]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]

def wndproc(hwnd, msg, wp, lp):
    return user32.DefWindowProcW(hwnd, msg, wp, lp)

CB = WNDPROC(wndproc)

def window_pid(h):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
    return pid.value

def find_by_class(cls):
    """EnumWindows 查找类名窗口，返回 (hwnd, pid) 或 (None, None)"""
    result = [None, None]
    def cb_enum(h, lp):
        sb = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(h, sb, 256)
        if sb.value == cls:
            result[0] = h
            result[1] = window_pid(h)
            return False
        return True
    proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)(cb_enum)
    user32.EnumWindows(proc, 0)
    return result[0], result[1]

user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]

# ---------- 准备 ----------
MODE = sys.argv[1] if len(sys.argv) > 1 else "drive"

if MODE == "prep":
    if os.path.exists(TESTB):
        shutil.rmtree(TESTB)
    os.makedirs(TESTB)
    # 备份真实配置
    shutil.copy2(REAL_CONFIG, BACKUP)
    log(f"配置已备份 -> {BACKUP}")
    # 临时切换通知类型为 CATIME
    data = open(REAL_CONFIG, "rb").read()
    assert data.count(b"NOTIFICATION_TYPE=OS") == 1
    open(REAL_CONFIG, "wb").write(data.replace(b"NOTIFICATION_TYPE=OS", b"NOTIFICATION_TYPE=CATIME"))
    log("已将 NOTIFICATION_TYPE 临时改为 CATIME")
    # 有界插件副本（平铺目录 -> 配置回退到 LOCALAPPDATA）
    src = open(os.path.join(BASE, "pomodoro_stats.ps1"), "rb").read()
    assert src.count(b"while ($true) {") == 1
    open(os.path.join(TESTB, "pomodoro_stats.ps1"), "wb").write(
        src.replace(b"while ($true) {", b"for ($ti = 0; $ti -lt 300; $ti++) {"))
    log("测试副本就绪: _tmp/testB/pomodoro_stats.ps1")
    print("PREP-DONE")
    sys.exit(0)

STATE = os.path.join(TESTB, "pomodoro_stats.json")
OUTPUT = os.path.join(TESTB, "output.txt")

def read_state(wait=0):
    time.sleep(wait)
    for _ in range(40):
        try:
            return json.load(open(STATE, encoding="utf-8"))
        except Exception:
            time.sleep(0.25)
    return None

def read_output():
    try:
        return open(OUTPUT, encoding="utf-8").read().strip()
    except Exception:
        return None

# ---------- 驱动 ----------
log("等待插件启动（6s）...")
time.sleep(6.0)

catime_hwnd, catime_pid = find_by_class("CatimeWindowClass")
log(f"Catime 主窗口 hwnd={catime_hwnd} pid={catime_pid}")
check("B0 Catime 正在运行", catime_hwnd is not None)

out = read_output()
check("B1 插件启动显示 T0 W0 A0", out == "<fps:1>T0 W0 A0", f"got={out!r}")

log("启动 8 秒倒计时（CLI: catime 0:08）...")
r = subprocess.run([CATIME_EXE, "0:08"], capture_output=True, timeout=30)
log(f"CLI 返回码={r.returncode}")

# 等待并捕获真实 toast 窗口
toast_seen = None
deadline = time.time() + 30
while time.time() < deadline:
    h, pid = find_by_class("CatimeNotificationClass")
    if h is not None:
        toast_seen = (h, pid)
        log(f"真实 toast 窗口出现: hwnd={h} pid={pid} (catime pid={catime_pid})")
        break
    time.sleep(0.1)

check("B2 真实 Catime toast 窗口被检测到", toast_seen is not None)
if toast_seen:
    check("B2b toast 属于 Catime 进程", toast_seen[1] == catime_pid,
          f"toast_pid={toast_seen[1]} catime_pid={catime_pid}")

time.sleep(2.5)
st = read_state()
check("B3 倒计时完成被计为 1 个番茄", st and st["total"] == 1 and st["days"].get(datetime.now().strftime("%Y-%m-%d")) == 1,
      f"state={st}")
out = read_output()
check("B3b 显示 T1 W1 A1", out == "<fps:1>T1 W1 A1", f"got={out!r}")

# 恢复配置
log("恢复 config.ini...")
shutil.copy2(BACKUP, REAL_CONFIG)
time.sleep(2.5)
out = read_output()
check("B4 恢复OS类型后显示 SET CATIME", out == "<fps:1>SET CATIME", f"got={out!r}")
restored = open(REAL_CONFIG, encoding="utf-8").read()
check("B4b 配置已还原（NOTIFICATION_TYPE=OS）", "NOTIFICATION_TYPE=OS" in restored)

log("=== Phase B 完成 ===")
fails = [r for r in RESULTS if "FAIL" in r]
print(f"\n==== PHASE B SUMMARY: {len(RESULTS) - len(fails)} passed, {len(fails)} failed ====")
