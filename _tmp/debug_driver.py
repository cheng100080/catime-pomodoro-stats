# 驱动调试：启动 debug_plugin，中间弹出模拟 toast 窗口，最后读日志
import ctypes, subprocess, time
from ctypes import wintypes

PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
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

def pop_toast(hold):
    wc = WNDCLASSEXW()
    wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
    wc.lpfnWndProc = CB
    wc.hInstance = ctypes.windll.kernel32.GetModuleHandleW(None)
    wc.lpszClassName = "CatimeNotificationClass"
    ok = user32.RegisterClassExW(ctypes.byref(wc))
    print("RegisterClassExW ->", ok, "lastErr=", ctypes.get_last_error())
    h = user32.CreateWindowExW(0x80 | 0x8, "CatimeNotificationClass", "Catime Notification",
                               0x80000000, 200, 200, 320, 60, None, None, wc.hInstance, None)
    print("CreateWindowExW -> hwnd =", h)
    user32.ShowWindow(h, 5)
    # 弹出期间从 Python 侧也验证一次可查找性
    f = user32.FindWindowW("CatimeNotificationClass", None)
    print("Python FindWindowW during pop ->", f)
    time.sleep(hold)
    user32.DestroyWindow(h)
    user32.UnregisterClassW("CatimeNotificationClass", wc.hInstance)
    print("window destroyed")

proc = subprocess.Popen([PS, "-NoProfile", "-NonInteractive", "-File",
                         r"D:\files\works\20051012CatTime插件\_tmp\debug_plugin.ps1"],
                        creationflags=0x08000000)
time.sleep(4.0)
print("plugin alive?", proc.poll() is None)
print("--- popping toast for 4s ---")
pop_toast(4.0)
time.sleep(3.0)
print("plugin alive at end?", proc.poll() is None)
time.sleep(4.0)
try:
    proc.kill()
except Exception:
    pass
import os
print(open(os.path.expandvars(r"%TEMP%\catime_dbg.log"), encoding="utf-8").read())
