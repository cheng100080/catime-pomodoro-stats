# 测试 -File 参数是否接受非 .ps1 扩展名（用于判断能否隐藏逻辑文件不出现在插件菜单）
import subprocess, os

PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
os.makedirs("psm1test", exist_ok=True)
open("psm1test/t.psm1", "w", encoding="utf-8").write('Write-Output "PSM1-RAN-OK"\n')
open("psm1test/t2.txt", "w", encoding="utf-8").write('Write-Output "TXT-RAN-OK"\n')

for f in ["psm1test/t.psm1", "psm1test/t2.txt"]:
    try:
        r = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-File", os.path.abspath(f)],
                           capture_output=True, text=True, timeout=30)
        print(f, "| rc=", r.returncode, "| out=", (r.stdout or "").strip()[:60],
              "| err=", (r.stderr or "").strip().replace("\n", " ")[:100])
    except Exception as e:
        print(f, "| EX:", e)
