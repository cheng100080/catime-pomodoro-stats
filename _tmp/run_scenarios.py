# Phase A 场景驱动（纯 Python：造窗口 + 读文件，不起任何进程）
# 前置：插件测试副本已通过 PowerShell 工具后台运行
import ctypes, json, os, time
from ctypes import wintypes
from datetime import datetime, timedelta

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

# ---------- Win32 造窗口 ----------
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

def seed_state(total, phase, lastEvent=None, days=None):
    json.dump({"version": 1, "total": total, "phase": phase, "lastEvent": lastEvent, "days": days or {}},
              open(STATE, "w", encoding="utf-8"))

def monday(d):
    if isinstance(d, str):
        d = datetime.fromisoformat(d).date()
    elif isinstance(d, datetime):
        d = d.date()
    return d - timedelta(days=d.weekday())

def set_type(t):
    txt = open(CFG, encoding="utf-8").read()
    for old in ("NOTIFICATION_TYPE=CATIME", "NOTIFICATION_TYPE=OS"):
        txt = txt.replace(old, f"NOTIFICATION_TYPE={t}")
    open(CFG, "w", encoding="utf-8", newline="").write(txt)

# ---------- 场景 ----------
log("等待插件启动（5s）...")
time.sleep(5.0)

out = read_output()
check("S0 启动显示 T0 W0 A0", out == "<fps:1>T0 W0 A0", f"got={out!r}")
st = read_state()
check("S0 初始状态文件 total=0", st is not None and st["total"] == 0, f"state={st}")

# S1: 第一次完成 → 阶段0（工作）→ 计 1
t0 = time.time()
pop_toast(1.5)
st = read_state(1.2)
check("S1 首次完成计 1（工作阶段）", st and st["total"] == 1 and st["days"].get(datetime.now().strftime("%Y-%m-%d")) == 1, f"state={st}")
check("S1 phase -> 1", st and st["phase"] == 1, f"phase={st and st['phase']}")
check("S1 显示 T1 W1 A1", read_output() == "<fps:1>T1 W1 A1", f"got={read_output()!r}")

# S2: 间隔 ~4.5s → 匹配阶段1=4s（休息）→ 不计数
time.sleep(max(0.0, 4.5 - (time.time() - t0)))
t0 = time.time()
pop_toast(1.5)
st = read_state(1.2)
check("S2 休息阶段不计数", st and st["total"] == 1, f"state={st}")
check("S2 phase -> 2", st and st["phase"] == 2, f"phase={st and st['phase']}")

# S3: 间隔 ~8.5s → 匹配阶段0=8s（工作）→ 计 2
time.sleep(max(0.0, 8.5 - (time.time() - t0)))
pop_toast(1.5)
st = read_state(1.2)
check("S3 工作阶段计数=2", st and st["total"] == 2, f"state={st}")
check("S3 phase -> 3", st and st["phase"] == 3, f"phase={st and st['phase']}")

# S4: 大间隔 400s（>2*8+300=316）→ 新会话 → 阶段0（工作）→ 计 3
seed_state(2, 3, lastEvent=(datetime.now().astimezone() - timedelta(seconds=400)).isoformat(),
           days={datetime.now().strftime("%Y-%m-%d"): 2})
time.sleep(0.5)
pop_toast(1.5)
st = read_state(1.2)
check("S4 大间隔判新会话计工作阶段", st and st["total"] == 3, f"state={st}")
check("S4 phase 重置为 1", st and st["phase"] == 1, f"phase={st and st['phase']}")

# S5: 周统计（周一为周始）
today = datetime.now().date()
days_seed = {
    today.isoformat(): 2,
    (today - timedelta(days=1)).isoformat(): 1,
    (today - timedelta(days=3)).isoformat(): 3,
    (today - timedelta(days=8)).isoformat(): 5,
}
expected_week = sum(v for k, v in days_seed.items() if monday(k) <= today) + 1
seed_state(10, 0, lastEvent=None, days=days_seed)
time.sleep(0.5)
pop_toast(1.5)
out = read_output()
check("S5 周统计正确", out == f"<fps:1>T3 W{expected_week} A11", f"got={out!r} expected_week={expected_week}")
st = read_state()
check("S5 total=11", st and st["total"] == 11, f"state={st}")

# S6: 通知类型门禁 → OS 时显示 SET CATIME 且不计数
set_type("OS")
time.sleep(2.0)
check("S6 非CATIME显示 SET CATIME", read_output() == "<fps:1>SET CATIME", f"got={read_output()!r}")
pop_toast(1.5)
st = read_state(1.2)
check("S6 非CATIME不计数", st and st["total"] == 11, f"state={st}")

# S7: 恢复 CATIME → 恢复统计显示
set_type("CATIME")
time.sleep(2.0)
check("S7 恢复CATIME恢复统计", (read_output() or "").startswith("<fps:1>T3 W"), f"got={read_output()!r}")

log("=== Phase A 场景完成 ===")
with open(os.path.join(TMP, "phaseA_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(RESULTS))
fails = [r for r in RESULTS if "FAIL" in r]
print(f"\n==== SUMMARY: {len(RESULTS) - len(fails)} passed, {len(fails)} failed ====")
