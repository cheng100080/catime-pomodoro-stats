# Phase A 逻辑测试：隔离目录 + 自有 config.ini + 模拟 CatimeNotificationClass 窗口
# 验证：工作/休息分类、间隔匹配自纠正、新会话重置、周统计、通知类型门禁
import ctypes, json, os, shutil, subprocess, sys, time
from ctypes import wintypes
from datetime import datetime, timedelta

BASE = r"D:\files\works\20051012CatTime插件\_tmp"
TESTDIR = os.path.join(BASE, "testA", "Catime", "resources", "plugins")
CFGDIR = os.path.join(BASE, "testA", "Catime")
PLUGIN_SRC = os.path.join(BASE, "..", "pomodoro_stats.ps1")
REAL_CONFIG = os.path.expandvars(r"%LOCALAPPDATA%\Catime\config.ini")
RESULTS = []

def log(msg):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line)
    RESULTS.append(line)

def check(name, cond, detail=""):
    log(f"{'PASS' if cond else 'FAIL'}: {name} {detail}")
    return cond

# ---------- Win32 ----------
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
user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
user32.FindWindowW.restype = wintypes.HWND

def wndproc(hwnd, msg, wp, lp):
    return user32.DefWindowProcW(hwnd, msg, wp, lp)

CB = WNDPROC(wndproc)

def pop_toast(hold=1.5):
    """创建并销毁一个类名为 CatimeNotificationClass 的可见顶层窗口（模拟 Catime toast）"""
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

def toast_visible():
    return user32.FindWindowW("CatimeNotificationClass", None) != 0

# ---------- 测试环境 ----------
if os.path.exists(os.path.join(BASE, "testA")):
    shutil.rmtree(os.path.join(BASE, "testA"))
os.makedirs(TESTDIR)

# 读取用户真实 config，改写成本测试专用（短阶段序列 8s/4s + CATIME 通知）
cfg_text = open(REAL_CONFIG, "r", encoding="utf-8").read()
cfg_text = cfg_text.replace("NOTIFICATION_TYPE=OS", "NOTIFICATION_TYPE=CATIME")
cfg_text = cfg_text.replace("POMODORO_TIME_OPTIONS=2700,600,2700,1200", "POMODORO_TIME_OPTIONS=8,4,8,4")
open(os.path.join(CFGDIR, "config.ini"), "w", encoding="utf-8", newline="").write(cfg_text)

shutil.copy(PLUGIN_SRC, os.path.join(TESTDIR, "pomodoro_stats.ps1"))

state_path = os.path.join(TESTDIR, "pomodoro_stats.json")
output_path = os.path.join(TESTDIR, "output.txt")

def read_state():
    for _ in range(20):
        try:
            return json.load(open(state_path, encoding="utf-8"))
        except Exception:
            time.sleep(0.25)
    return None

def read_output():
    try:
        return open(output_path, encoding="utf-8").read().strip()
    except Exception:
        return None

def seed_state(total, phase, lastEvent=None, days=None):
    st = {"version": 1, "total": total, "phase": phase,
          "lastEvent": lastEvent, "days": days or {}}
    json.dump(st, open(state_path, "w", encoding="utf-8"))

def monday_week_start(d):
    return (d - timedelta(days=(d.weekday()))).date()

PS_EXE = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

# ---------- 启动插件（与 Catime 相同的启动方式） ----------
log("启动插件（powershell -NoProfile -NonInteractive -File）...")
proc = subprocess.Popen(
    [PS_EXE, "-NoProfile", "-NonInteractive", "-File",
     os.path.join(TESTDIR, "pomodoro_stats.ps1")],
    creationflags=0x08000000)
time.sleep(5.0)

try:
    # S0: 启动初始显示
    out = read_output()
    check("S0 启动显示 T0 W0 A0", out == "<fps:1>T0 W0 A0", f"got={out!r}")
    st = read_state()
    check("S0 初始状态 total=0", st and st["total"] == 0)

    # S1: 第一次完成 → 阶段0（工作）→ 计 1
    t0 = time.time()
    pop_toast(1.5)
    time.sleep(1.2)
    st = read_state()
    check("S1 首次完成计 1 个番茄（工作阶段）", st and st["total"] == 1 and st["days"].get(datetime.now().strftime("%Y-%m-%d")) == 1,
          f"state={st}")
    check("S1 phase 推进到 1", st and st["phase"] == 1, f"phase={st and st['phase']}")
    out = read_output()
    check("S1 显示 T1 W1 A1", out == "<fps:1>T1 W1 A1", f"got={out!r}")

    # S2: 间隔 ~4.5s 后完成 → 间隔匹配阶段1=4s（休息）→ 不计数
    time.sleep(max(0, 4.5 - (time.time() - t0)))
    t0 = time.time()
    pop_toast(1.5)
    time.sleep(1.2)
    st = read_state()
    check("S2 休息阶段不计数", st and st["total"] == 1, f"state={st}")
    check("S2 phase 推进到 2", st and st["phase"] == 2, f"phase={st and st['phase']}")

    # S3: 间隔 ~8.5s 后完成 → 间隔匹配阶段0=8s（工作）→ 计 2
    time.sleep(max(0, 8.5 - (time.time() - t0)))
    pop_toast(1.5)
    time.sleep(1.2)
    st = read_state()
    check("S3 工作阶段计数=2", st and st["total"] == 2, f"state={st}")
    check("S3 phase 推进到 3", st and st["phase"] == 3, f"phase={st and st['phase']}")

    # S4: 间隔 400s（> 2*8+300=316）→ 判定为新会话 → 阶段0（工作）→ 计 3
    seed_state(2, 3, lastEvent=(datetime.now().astimezone() - timedelta(seconds=400)).isoformat(),
               days={datetime.now().strftime("%Y-%m-%d"): 2})
    time.sleep(0.5)
    pop_toast(1.5)
    time.sleep(1.2)
    st = read_state()
    check("S4 大间隔判定新会话并计工作阶段", st and st["total"] == 3, f"state={st}")
    check("S4 phase 重置为 1", st and st["phase"] == 1, f"phase={st and st['phase']}")

    # S5: 周统计（周一为一周开始）
    today = datetime.now().date()
    days_seed = {
        today.isoformat(): 2,
        (today - timedelta(days=1)).isoformat(): 1,
        (today - timedelta(days=3)).isoformat(): 3,
        (today - timedelta(days=8)).isoformat(): 5,   # 上周
    }
    expected_week = sum(v for k, v in days_seed.items()
                        if monday_week_start(today) <= datetime.fromisoformat(k).date() <= today) + 1  # +1 = 本次完成
    seed_state(10, 0, lastEvent=None, days=days_seed)
    time.sleep(0.5)
    pop_toast(1.5)
    time.sleep(1.2)
    out = read_output()
    check("S5 周统计正确", out == f"<fps:1>T3 W{expected_week} A11", f"got={out!r} expected_week={expected_week}")
    st = read_state()
    check("S5 total=11", st and st["total"] == 11, f"state={st}")

    # S6: 通知类型门禁 — 改为 OS 后显示 SET CATIME 且不计数
    cfg_test = os.path.join(CFGDIR, "config.ini")
    txt = open(cfg_test, encoding="utf-8").read().replace("NOTIFICATION_TYPE=CATIME", "NOTIFICATION_TYPE=OS")
    open(cfg_test, "w", encoding="utf-8", newline="").write(txt)
    time.sleep(2.0)
    out = read_output()
    check("S6 非CATIME类型显示 SET CATIME", out == "<fps:1>SET CATIME", f"got={out!r}")
    pop_toast(1.5)
    time.sleep(1.2)
    st = read_state()
    check("S6 非CATIME类型不计数", st and st["total"] == 11, f"state={st}")

    # S7: 恢复 CATIME 后恢复统计显示
    open(cfg_test, "w", encoding="utf-8", newline="").write(
        open(cfg_test, encoding="utf-8").read().replace("NOTIFICATION_TYPE=OS", "NOTIFICATION_TYPE=CATIME"))
    time.sleep(2.0)
    out = read_output()
    check("S7 恢复CATIME后恢复统计显示", out and out.startswith("<fps:1>T3 W"), f"got={out!r}")

    # S8: 持久化 — 杀掉插件重启，状态保留
    proc.kill(); proc.wait()
    time.sleep(1.0)
    proc2 = subprocess.Popen(
        [PS_EXE, "-NoProfile", "-NonInteractive", "-File",
         os.path.join(TESTDIR, "pomodoro_stats.ps1")],
        creationflags=0x08000000)
    time.sleep(5.0)
    out = read_output()
    check("S8 重启后统计保留", out and out.startswith("<fps:1>T3 W") and out.endswith("A11"), f"got={out!r}")
    proc2.kill(); proc2.wait()

finally:
    try:
        proc.kill()
    except Exception:
        pass

log("=== Phase A 完成 ===")
with open(os.path.join(BASE, "phaseA_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(RESULTS))
fails = [r for r in RESULTS if r.startswith("[") and "FAIL" in r]
print(f"\n==== SUMMARY: {len(RESULTS)-len(fails)} passed, {len(fails)} failed ====")
