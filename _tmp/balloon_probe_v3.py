# 只读实验 v3：精确时间戳 + 50ms 快轮询 + 两次间隔 40s 的气球
# 判定标准：若气球产生可检测窗口，该窗口必须在发布后 ~1s 内出现
import ctypes
from ctypes import wintypes
import time, sys

user32 = ctypes.WinDLL("user32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

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
psapi.GetProcessImageFileNameW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD]
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE

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
icon = user32.LoadIconW(None, ctypes.c_void_p(32512))

nid = NOTIFYICONDATAW()
nid.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
nid.hWnd = hwnd
nid.uID = 1
nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
nid.uCallbackMessage = WM_USER + 1
nid.hIcon = icon
nid.szTip = "probe"
shell32.Shell_NotifyIconW(NIM_ADD, ctypes.byref(nid))
time.sleep(0.5)

EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def snapshot():
    out = []
    def cb_enum(h, lp):
        if user32.IsWindowVisible(h):
            c = ctypes.create_unicode_buffer(256); user32.GetClassNameW(h, c, 256)
            t = ctypes.create_unicode_buffer(256); user32.GetWindowTextW(h, t, 256)
            pid = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
            out.append((f"{c.value}|{t.value}|pid={pid.value}", pid.value))
        return True
    user32.EnumWindows(EnumWindowsProc(cb_enum), 0)
    return out

def procpath(pid):
    h = kernel32.OpenProcess(0x1000, False, pid)
    if not h: return "?"
    buf = ctypes.create_unicode_buffer(260)
    psapi.GetProcessImageFileNameW(h, buf, 260)
    kernel32.CloseHandle(h)
    return buf.value

def post_balloon(text):
    nid.uFlags = NIF_INFO
    nid.szInfo = text
    nid.szInfoTitle = ""
    nid.dwInfoFlags = NIIF_NONE
    nid.uTimeout = 3000
    shell32.Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(nid))

baseline = set(k for k, _ in snapshot())
print(f"baseline: {len(baseline)} windows")

def trial(label, text, duration=20):
    print(f"--- {label}: post balloon, fast poll {duration}s ---")
    seen = {}
    post_balloon(text)
    t0 = time.time()
    while time.time() - t0 < duration:
        for w, pid in snapshot():
            if w not in baseline and w not in seen:
                seen[w] = time.time() - t0
                print(f"  NEW t+{time.time()-t0:5.2f}s  {w}  proc={procpath(pid)}")
        time.sleep(0.05)
    if not seen:
        print("  (no new window)")
    return seen

trial("T1", "45m Pomodoro completed (Cycle1/1 Round 1/4)")
print("sleep 40s to avoid balloon throttling...")
time.sleep(40)
trial("T2", "10m Pomodoro completed (Cycle1/1 Round 2/4)")

nid.uFlags = 0
shell32.Shell_NotifyIconW(NIM_DELETE, ctypes.byref(nid))
user32.DestroyWindow(hwnd)
user32.UnregisterClassW("CatimeProbeMsgWindow", cls.hInstance)
print("probe done, cleaned up")
