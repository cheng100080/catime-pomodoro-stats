# 验证 .bat 入口链路：cmd.exe /c pomodoro_stats.bat -> 绝对路径 powershell -> core.ps1
import ctypes, json, os, shutil, subprocess, sys, time
from ctypes import wintypes
from datetime import datetime

BASE = r"D:\files\works\20051012CatTime插件"
TMP = os.path.join(BASE, "_tmp")
TESTC = os.path.join(TMP, "testC")
CMD = r"C:\Windows\System32\cmd.exe"
LOG = os.path.join(TMP, "phaseC_result.txt")

def log(m):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
    print(line)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")

def check(name, cond, detail=""):
    log(f"{'PASS' if cond else 'FAIL'}: {name} {detail}")

if os.path.exists(TESTC):
    shutil.rmtree(TESTC)
os.makedirs(TESTC)
shutil.copy(os.path.join(BASE, "pomodoro_stats.bat"), os.path.join(TESTC, "pomodoro_stats.bat"))
src = open(os.path.join(BASE, "pomodoro_stats_core.ps1"), "rb").read()
assert src.count(b"while ($true) {") == 1
open(os.path.join(TESTC, "pomodoro_stats_core.ps1"), "wb").write(
    src.replace(b"while ($true) {", b"for ($ti = 0; $ti -lt 240; $ti++) {"))
log("测试目录就绪（有界副本）")

# 用与 Catime 相同的方式启动：cmd.exe /c xxx.bat
proc = subprocess.Popen([CMD, "/c", os.path.join(TESTC, "pomodoro_stats.bat")],
                        cwd=TESTC, creationflags=0x08000000)
OUT = os.path.join(TESTC, "output.txt")
STATE = os.path.join(TESTC, "pomodoro_stats.json")

def read_output():
    try:
        return open(OUT, encoding="utf-8").read().strip()
    except Exception:
        return None

def read_state():
    try:
        return json.load(open(STATE, encoding="utf-8"))
    except Exception:
        return None

log("等待链路启动（6s）...")
time.sleep(6.0)
out = read_output()
check("C1 .bat 链路成功写出 output.txt", out is not None, f"got={out!r}")
check("C1b 内容为 T0 W0 A0", out == "<fps:1>T0 W0 A0", f"got={out!r}")

# 弹一个模拟 toast 验证计数仍正常
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
wc = WNDCLASSEXW()
wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
wc.lpfnWndProc = CB
wc.hInstance = ctypes.windll.kernel32.GetModuleHandleW(None)
wc.lpszClassName = "CatimeNotificationClass"
user32.RegisterClassExW(ctypes.byref(wc))
h = user32.CreateWindowExW(0x80 | 0x8, "CatimeNotificationClass", "Catime Notification",
                           0x80000000, 200, 200, 320, 60, None, None, wc.hInstance, None)
user32.ShowWindow(h, 5)
time.sleep(1.5)
user32.DestroyWindow(h)
user32.UnregisterClassW("CatimeNotificationClass", wc.hInstance)
time.sleep(1.5)

st = read_state()
check("C2 阶段完成被计数（total=1）", st and st.get("total") == 1, f"state={st}")
check("C2b 显示 T1 W1 A1", read_output() == "<fps:1>T1 W1 A1", f"got={read_output()!r}")

proc.kill()
log("=== Phase C 完成（有界副本将在 120s 内自行退出） ===")
fails = sum(1 for l in open(LOG, encoding="utf-8") if "FAIL" in l)
print(f"\n==== PHASE C: {fails} failed ====")
