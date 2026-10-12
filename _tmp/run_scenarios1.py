# Phase A 场景驱动 run1：S0-S3 计数与分类 + S6/S7 类型门禁（运行中不可 seed，重启类场景见 run2）
import ctypes, json, os, time
from ctypes import wintypes
from datetime import datetime

TMP = r"D:\files\works\20051012CatTime插件\_tmp"
TESTDIR = os.path.join(TMP, "testA", "Catime", "resources", "plugins")
CFG = os.path.join(TMP, "testA", "Catime", "config.ini")
STATE = os.path.join(TESTDIR, "pomodoro_stats.json")
OUTPUT = os.path.join(TESTDIR, "output.txt")
RESULTS = []

def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
    print(line)
    RESULTS.append(line)

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

def set_type(t):
    txt = open(CFG, encoding="utf-8").read()
    for old in ("NOTIFICATION_TYPE=CATIME", "NOTIFICATION_TYPE=OS"):
        txt = txt.replace(old, f"NOTIFICATION_TYPE={t}")
    open(CFG, "w", encoding="utf-8", newline="").write(txt)

log("等待插件启动（5s）...")
time.sleep(5.0)

out = read_output()
check("S0 启动显示 T0 W0 A0", out == "<fps:1>T0 W0 A0", f"got={out!r}")
st = read_state()
check("S0 启动即落状态文件 total=0", st is not None and st["total"] == 0, f"state={st}")

t0 = time.time()
pop_toast(1.5)
st = read_state(1.2)
check("S1 首次完成计 1（工作阶段）", st and st["total"] == 1 and st["days"].get(datetime.now().strftime("%Y-%m-%d")) == 1, f"state={st}")
check("S1 phase -> 1", st and st["phase"] == 1, f"phase={st and st['phase']}")
check("S1 显示 T1 W1 A1", read_output() == "<fps:1>T1 W1 A1", f"got={read_output()!r}")

time.sleep(max(0.0, 4.5 - (time.time() - t0)))
t0 = time.time()
pop_toast(1.5)
st = read_state(1.2)
check("S2 休息阶段不计数", st and st["total"] == 1, f"state={st}")
check("S2 phase -> 2", st and st["phase"] == 2, f"phase={st and st['phase']}")

time.sleep(max(0.0, 8.5 - (time.time() - t0)))
pop_toast(1.5)
st = read_state(1.2)
check("S3 工作阶段计数=2", st and st["total"] == 2, f"state={st}")
check("S3 phase -> 3（相同时长下保持连续）", st and st["phase"] == 3, f"phase={st and st['phase']}")
check("S3 显示 T2 W2 A2", read_output() == "<fps:1>T2 W2 A2", f"got={read_output()!r}")

# S6: 类型门禁 — OS 期间不计数，恢复后数字不变
set_type("OS")
time.sleep(2.0)
check("S6 非CATIME显示 SET CATIME", read_output() == "<fps:1>SET CATIME", f"got={read_output()!r}")
pop_toast(1.5)
time.sleep(1.2)
set_type("CATIME")
time.sleep(2.0)
out = read_output()
check("S6 OS期间不计数且恢复后显示原值", out == "<fps:1>T2 W2 A2", f"got={out!r}")

log("=== Phase A run1 完成 ===")
with open(os.path.join(TMP, "phaseA_run1_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(RESULTS))
fails = [r for r in RESULTS if "FAIL" in r]
print(f"\n==== RUN1 SUMMARY: {len(RESULTS) - len(fails)} passed, {len(fails)} failed ====")
