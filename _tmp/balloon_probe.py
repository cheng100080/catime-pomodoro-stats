# 只读实验（Python/ctypes 版）：复刻 Catime 的 Shell_NotifyIconW(NIM_MODIFY, NIF_INFO) 气球调用
# 前后快照枚举所有可见顶层窗口，判断 OS 气球弹出时是否出现插件可检测的窗口。
# 只操作本进程创建的临时消息窗口+托盘图标，不碰 Catime、不碰用户配置。
import ctypes
from ctypes import wintypes
import time, sys

user32 = ctypes.WinDLL("user32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_longlong, wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p)

class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("style", wintypes.UINT), ("lpfnWndProc", WNDPROC),
                ("cbClsExtra", ctypes.c_int), ("cbWndExtra", ctypes.c_int), ("hInstance", wintypes.HINSTANCE),
                ("hIcon", wintypes.HICON), ("hCursor", wintypes.HANDLE), ("hbrBackground", wintypes.HBRUSH),
                ("lpszMenuName", wintypes.LPCWSTR), ("lpszClassName", wintypes.LPCWSTR), ("hIconSm", wintypes.HICON)]

class NOTIFYICONDATAW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("hWnd", wintypes.HWND), ("uID", wintypes.UINT),
                ("uFlags", wintypes.UINT), ("uCallbackMessage", wintypes.UINT), ("hIcon", wintypes.HICON),
                ("szTip", wintypes.WCHAR * 128), ("dwState", wintypes.DWORD), ("dwStateMask", wintypes.DWORD),
                ("szInfo", wintypes.WCHAR * 256), ("uTimeout", wintypes.UINT), ("szInfoTitle", wintypes.WCHAR * 64),
                ("dwInfoFlags", wintypes.DWORD), ("guidItem", ctypes.c_byte * 16), ("hBalloonIcon", wintypes.HICON)]

user32.DefWindowProcW.restype = ctypes.c_longlong
user32.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p]
user32.CreateWindowExW.restype = wintypes.HWND
user32.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
                                   ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, ctypes.c_void_p]
user32.RegisterClassExW.argtypes = [ctypes.POINTER(WNDCLASSEXW)]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.LoadIconW.argtypes = [wintypes.HINSTANCE, ctypes.c_void_p]
user32.LoadIconW.restype = wintypes.HICON
shell32.Shell_NotifyIconW.argtypes = [wintypes.DWORD, ctypes.POINTER(NOTIFYICONDATAW)]

NIM_ADD, NIM_MODIFY, NIM_DELETE = 0, 1, 2
NIF_MESSAGE, NIF_ICON, NIF_TIP, NIF_INFO = 1, 2, 4, 0x10
NIIF_NONE = 0
WM_USER = 0x0400
HWND_MESSAGE = -3

def wndproc(hwnd, msg, wp, lp):
    return user32.DefWindowProcW(hwnd, msg, wp, lp)

cb = WNDPROC(wndproc)
cls = WNDCLASSEXW()
cls.cbSize = ctypes.sizeof(WNDCLASSEXW)
cls.lpfnWndProc = cb
cls.hInstance = kernel32.GetModuleHandleW(None)
cls.lpszClassName = "CatimeProbeMsgWindow"
user32.RegisterClassExW(ctypes.byref(cls))

hwnd = user32.CreateWindowExW(0, "CatimeProbeMsgWindow", "probe", 0, 0, 0, 0, 0,
                              wintypes.HWND(HWND_MESSAGE), None, cls.hInstance, None)
if not hwnd:
    print("CreateWindowExW failed:", ctypes.get_last_error()); sys.exit(1)

icon = user32.LoadIconW(None, ctypes.c_void_p(32512))  # IDI_APPLICATION
nid = NOTIFYICONDATAW()
nid.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
nid.hWnd = hwnd
nid.uID = 1
nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
nid.uCallbackMessage = WM_USER + 1
nid.hIcon = icon
nid.szTip = "probe"
if not shell32.Shell_NotifyIconW(NIM_ADD, ctypes.byref(nid)):
    print("NIM_ADD failed:", ctypes.get_last_error()); sys.exit(1)
time.sleep(0.5)

EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def snapshot():
    out = []
    def cb_enum(h, lp):
        if user32.IsWindowVisible(h):
            c = ctypes.create_unicode_buffer(256); user32.GetClassNameW(h, c, 256)
            t = ctypes.create_unicode_buffer(256); user32.GetWindowTextW(h, t, 256)
            pid = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
            out.append(f"{c.value}|{t.value}|pid={pid.value}")
        return True
    user32.EnumWindows(EnumWindowsProc(cb_enum), 0)
    return out

baseline = snapshot()
print(f"baseline visible top-level windows: {len(baseline)}")

# 复刻 Catime OS 通知路径: NIF_INFO + NIIF_NONE + 空标题 + 3s 超时
def post_balloon(text):
    nid.uFlags = NIF_INFO
    nid.szInfo = text
    nid.szInfoTitle = ""
    nid.dwInfoFlags = NIIF_NONE
    nid.uTimeout = 3000
    shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(nid))

def procname(pid):
    snap = ctypes.create_unicode_buffer(260)
    h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return "?"
    n = ctypes.windll.psapi.GetProcessImageFileNameW(h, snap, 260) if hasattr(ctypes.windll, "psapi") else 0
    kernel32.CloseHandle(h)
    return snap.value if n else "?"

print("--- balloon #1 ---")
post_balloon("45m Pomodoro completed (Cycle1/1 Round 1/4)")
seen = {}
alive = {}
t0 = time.time()
def watch(duration):
    deadline = time.time() + duration
    while time.time() < deadline:
        for w in snapshot():
            key = w
            if w not in baseline and w not in seen:
                seen[key] = True
                alive[key] = True
                pid = int(w.rsplit("pid=", 1)[1])
                print(f"NEW t+{time.time()-t0:.1f}s: {w} proc={procname(pid)}")
            elif key in alive:
                alive[key] = True
        # 清理本周期未出现的窗口
        for k in list(alive):
            if k not in snapshot():
                pass
        time.sleep(0.2)

watch(12)
print("--- balloon #2 (6s 后) ---")
time.sleep(6)
post_balloon("10m Pomodoro completed (Cycle1/1 Round 2/4)")
watch(12)
print("--- 再监控 12s 观察弹窗消失 ---")
gone = {}
t1 = time.time()
while time.time() - t1 < 12:
    cur = snapshot()
    for k in list(alive):
        if k not in cur and k not in gone:
            gone[k] = True
            print(f"GONE t+{time.time()-t1:.1f}s: {k}")
    time.sleep(0.2)

if not seen:
    print("RESULT: no new visible top-level window appeared during balloon")

nid.uFlags = 0
shell32.Shell_NotifyIconW(NIM_DELETE, ctypes.byref(nid))
user32.DestroyWindow(hwnd)
user32.UnregisterClassW("CatimeProbeMsgWindow", cls.hInstance)
print("probe done, tray icon cleaned up")
