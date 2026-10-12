# Phase A run2：先 seed 状态文件再启动插件，验证新会话重置启发式 + 周统计
# 状态: total=10, phase=3, lastEvent=400秒前(>2*8+300=316 → 判新会话), days 跨本周/上周
import json, os, shutil, sys, time
from datetime import datetime, timedelta

BASE = r"D:\files\works\20051012CatTime插件"
TMP = os.path.join(BASE, "_tmp")
sys.path.insert(0, TMP)
import ctypes
from ctypes import wintypes
TESTDIR = os.path.join(TMP, "testA", "Catime", "resources", "plugins")
CFGDIR = os.path.join(TMP, "testA", "Catime")
REAL_CONFIG = os.path.expandvars(r"%LOCALAPPDATA%\Catime\config.ini")
STATE = os.path.join(TESTDIR, "pomodoro_stats.json")
OUTPUT = os.path.join(TESTDIR, "output.txt")
RESULTS = []

def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
    print(line)
    RESULTS.append(line)
    with open(os.path.join(TMP, "phaseA_run2_result.txt"), "a", encoding="utf-8") as f:
        f.write(line + "\n")

def check(name, cond, detail=""):
    log(f"{'PASS' if cond else 'FAIL'}: {name} {detail}")

# 重建测试环境 + 有界副本（prep 模式或默认模式执行；drive 模式跳过，直接使用已 seed 的环境）
DRIVE_MODE = len(sys.argv) > 1 and sys.argv[1] == "drive"

if not DRIVE_MODE:
    if os.path.exists(os.path.join(TMP, "testA")):
        shutil.rmtree(os.path.join(TMP, "testA"))
    os.makedirs(TESTDIR)
    cfg = open(REAL_CONFIG, encoding="utf-8").read()
    cfg = cfg.replace("NOTIFICATION_TYPE=OS", "NOTIFICATION_TYPE=CATIME")
    cfg = cfg.replace("POMODORO_TIME_OPTIONS=2700,600,2700,1200", "POMODORO_TIME_OPTIONS=8,4,8,4")
    open(os.path.join(CFGDIR, "config.ini"), "w", encoding="utf-8", newline="").write(cfg)
    src = open(os.path.join(BASE, "pomodoro_stats.ps1"), "rb").read()
    assert src.count(b"while ($true) {") == 1
    open(os.path.join(TESTDIR, "pomodoro_stats.ps1"), "wb").write(
        src.replace(b"while ($true) {", b"for ($ti = 0; $ti -lt 240; $ti++) {"))

# seed 状态：lastEvent=400s 前，phase=3（故意错位），days 分布本周与上周
if not DRIVE_MODE:
    today = datetime.now().date()
    days_seed = {
        today.isoformat(): 2,
        (today - timedelta(days=1)).isoformat(): 1,
        (today - timedelta(days=3)).isoformat(): 3,
        (today - timedelta(days=8)).isoformat(): 5,
    }
    json.dump({"version": 1, "total": 10, "phase": 3,
               "lastEvent": (datetime.now().astimezone() - timedelta(seconds=400)).isoformat(),
               "days": days_seed},
              open(STATE, "w", encoding="utf-8"))

today = datetime.now().date()
days_seed = json.load(open(STATE, encoding="utf-8"))["days"]

def monday(d):
    return d - timedelta(days=d.weekday())

expected_week_before = sum(v for k, v in days_seed.items()
                           if monday(today) <= datetime.fromisoformat(k).date() <= today)
expected_today_before = days_seed[today.isoformat()]
log(f"seed: total=10 today={expected_today_before} week={expected_week_before} (lastEvent=400s前)")

if len(sys.argv) > 1 and sys.argv[1] == "prep":
    print("PREP-DONE")
    sys.exit(0)

# 本 run 由外部（PowerShell 工具）启动插件；这里只等待并驱动窗口
log("等待插件启动（6s）...")
time.sleep(6.0)

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

def wndproc(hwnd, msg, wp, lp):
    return user32.DefWindowProcW(hwnd, msg, wp, lp)

CB = WNDPROC(wndproc)

def pop_toast(hold=1.5):
    wc = WNDCLASSEXW()
    wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
    wc.lpfnWndProc = CB
    wc.hInstance = ctypes.windll.kernel32.GetModuleHandleW(None)
    wc.lpszClassName = "CatimeNotificationClass"
    user32.RegisterClassExW(ctypes.byref(wc))
    h = user32.CreateWindowExW(0x80 | 0x8, "CatimeNotificationClass", "Catime Notification",
                               0x80000000, 200, 200, 320, 60, None, None, wc.hInstance, None)
    user32.ShowWindow(h, 5)
    time.sleep(hold)
    user32.DestroyWindow(h)
    user32.UnregisterClassW("CatimeNotificationClass", wc.hInstance)

def read_state(wait=0):
    time.sleep(wait)
    for _ in range(30):
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

# 等待插件启动（由外部启动）
log("等待插件启动（6s）...")
time.sleep(6.0)

out = read_output()
check("R2-0 启动显示 seed 统计", out == f"<fps:1>T{expected_today_before} W{expected_week_before} A10", f"got={out!r}")

pop_toast(1.5)
st = read_state(1.2)
check("R2-1 大间隔判新会话：计工作阶段 total=11", st and st["total"] == 11, f"state={st}")
check("R2-1 phase 重置为 1", st and st["phase"] == 1, f"phase={st and st['phase']}")
out = read_output()
check("R2-1 显示 T3 W7 A11",
      out == f"<fps:1>T{expected_today_before + 1} W{expected_week_before + 1} A11", f"got={out!r}")

log("=== Phase A run2 完成 ===")
with open(os.path.join(TMP, "phaseA_run2_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(RESULTS))
fails = [r for r in RESULTS if "FAIL" in r]
print(f"\n==== RUN2 SUMMARY: {len(RESULTS) - len(fails)} passed, {len(fails)} failed ====")
