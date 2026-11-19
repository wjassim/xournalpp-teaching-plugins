# Runs a Lua file with Xournal++'s own Lua 5.5 (lua55.dll), without Xournal++.
# Use this one for tests that touch real GTK: Python's own libffi-8.dll shadows the one LuaGObject needs
# (same file name), which breaks GTK calls that return a decimal number (get_value, get_upper).
#   powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
param([Parameter(Mandatory = $true)][string]$File)
$X = Join-Path $env:LOCALAPPDATA "Programs\Xournal++"
$bin = Join-Path $X "bin"
$env:PATH = "$bin;$env:PATH"
foreach ($k in "LUA_PATH", "LUA_CPATH", "LUA_PATH_5_5", "LUA_CPATH_5_5") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Lua55 {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDllDirectory(string p);
    [DllImport("lua55.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
    [DllImport("lua55.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void luaL_openselectedlibs(IntPtr L, int load, int preload);
    [DllImport("lua55.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int luaL_loadstring(IntPtr L, byte[] s);
    [DllImport("lua55.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int lua_pcallk(IntPtr L, int nargs, int nresults, int msgh, IntPtr ctx, IntPtr k);
    [DllImport("lua55.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr L, int idx, IntPtr len);
}
"@
[void][Lua55]::SetDllDirectory($bin)
$share = (Join-Path $X "share\lua\5.5") -replace "\\", "/"
$lib = (Join-Path $X "lib\lua\5.5") -replace "\\", "/"
$pre = "package.path = `"$share/?.lua;$share/?/init.lua`"; package.cpath = `"$lib/?.dll`"`n"
$src = $pre + [IO.File]::ReadAllText((Resolve-Path $File), [Text.Encoding]::UTF8)
$bytes = [Text.Encoding]::UTF8.GetBytes($src + "`0")
$L = [Lua55]::luaL_newstate()
[Lua55]::luaL_openselectedlibs($L, -1, 0)
$rc = [Lua55]::luaL_loadstring($L, $bytes)
if ($rc -eq 0) { $rc = [Lua55]::lua_pcallk($L, 0, 1, 0, [IntPtr]::Zero, [IntPtr]::Zero) }
"rc $rc"
$p = [Lua55]::lua_tolstring($L, -1, [IntPtr]::Zero)
if ($p -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p) }
