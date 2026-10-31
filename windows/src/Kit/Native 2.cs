using System.Runtime.InteropServices;

namespace Kit;

/// <summary>The Win32 calls WinForms does not wrap. Shared, identical copy in Nox and Awayke.</summary>
internal static class Native
{
    // ---- DWM ----
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;   // Windows 10 20H1+ / 11
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;  // Windows 11
    public const int DWMWA_BORDER_COLOR = 34;              // Windows 11
    public const int DWMWCP_ROUND = 2;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static void SetDwmInt(IntPtr hwnd, int attribute, int value) =>
        _ = DwmSetWindowAttribute(hwnd, attribute, ref value, sizeof(int));

    public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;

    // ---- Taskbar edge ----
    public const uint ABM_GETTASKBARPOS = 5;
    public const uint ABE_LEFT = 0, ABE_TOP = 1, ABE_RIGHT = 2, ABE_BOTTOM = 3;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct APPBARDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public RECT rc;
        public IntPtr lParam;
    }

    [DllImport("shell32.dll")]
    private static extern UIntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);

    public static uint TaskbarEdge()
    {
        var data = new APPBARDATA { cbSize = (uint)Marshal.SizeOf<APPBARDATA>() };
        return SHAppBarMessage(ABM_GETTASKBARPOS, ref data) != UIntPtr.Zero ? data.uEdge : ABE_BOTTOM;
    }

    // ---- DPI ----
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    /// <summary>Scale factor (1.0 = 96 DPI) of the monitor under a screen point.</summary>
    public static double ScaleAt(Point p)
    {
        var monitor = MonitorFromPoint(new POINT { X = p.X, Y = p.Y }, 2);
        return GetDpiForMonitor(monitor, 0, out var dpiX, out _) == 0 && dpiX > 0 ? dpiX / 96.0 : 1.0;
    }

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    public static extern int GetSystemMetricsForDpi(int index, uint dpi);
    public const int SM_CXSMICON = 49;

    // ---- Focus ----
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AllowSetForegroundWindow(int dwProcessId);
    public const int ASFW_ANY = -1;

    // ---- Tray icon position ----
    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [DllImport("shell32.dll")]
    public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);

    // ---- Settings broadcast ----
    public static readonly IntPtr HWND_BROADCAST = new(0xffff);
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
                                                   uint flags, uint timeout, out UIntPtr result);

    // ---- Window placement without activation ----
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;

    // ---- Keep awake ----
    [Flags]
    public enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        DisplayRequired = 0x00000002,
        Continuous = 0x80000000,
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern ExecutionState SetThreadExecutionState(ExecutionState flags);

    // ---- Power plans (powrprof.dll) ----
    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid scheme);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr mem);

    // ---- Icons ----
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr handle);
}
