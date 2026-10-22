using System.Runtime.InteropServices;
using Kit;

namespace Awayke;

/// <summary>
/// Keeping Windows awake (SetThreadExecutionState) and the lid-close action of the active power plan
/// ("Do nothing" while Awayke is on, put back afterwards).
/// </summary>
internal static class Power
{
    private static Guid subButtons = new("4f971e89-eebd-4455-a8de-9e59040e7347");   // SUB_BUTTONS
    private static Guid lidAction = new("5ca83367-6e45-459f-a27b-476b1d01c936");    // LIDACTION
    private const uint DoNothing = 0;
    private const uint ErrorAccessDenied = 5;

    /// <summary>Must be called on the UI thread: the request belongs to the calling thread and lasts until changed.</summary>
    public static bool KeepAwake(bool on, bool display)
    {
        var flags = Native.ExecutionState.Continuous;
        if (on) flags |= Native.ExecutionState.SystemRequired | (display ? Native.ExecutionState.DisplayRequired : 0);
        return Native.SetThreadExecutionState(flags) != 0;
    }

    public static Guid? ActiveScheme()
    {
        if (Native.PowerGetActiveScheme(IntPtr.Zero, out var ptr) != 0 || ptr == IntPtr.Zero) return null;
        try { return Marshal.PtrToStructure<Guid>(ptr); }
        finally { Native.LocalFree(ptr); }
    }

    /// <summary>Current lid action (0 nothing, 1 sleep, 2 hibernate, 3 shut down) on mains and on battery.</summary>
    public static (uint Ac, uint Dc)? ReadLid(Guid scheme)
    {
        var s = scheme;
        if (Native.PowerReadACValueIndex(IntPtr.Zero, ref s, ref subButtons, ref lidAction, out var ac) != 0) return null;
        if (Native.PowerReadDCValueIndex(IntPtr.Zero, ref s, ref subButtons, ref lidAction, out var dc) != 0) return null;
        return (ac, dc);
    }

    /// <summary>Sets "close the lid: do nothing". Returns the old values to put back, or an error in plain words.</summary>
    public static (LidBackup? Backup, string? Error) LidDoNothing()
    {
        var scheme = ActiveScheme();
        if (scheme == null) return (null, "Windows did not say which power plan is active.");
        var old = ReadLid(scheme.Value);
        if (old == null) return (null, "This PC has no lid setting in its power plan.");
        var error = WriteLid(scheme.Value, DoNothing, DoNothing);
        return error == null
            ? (new LidBackup { Scheme = scheme.Value, Ac = old.Value.Ac, Dc = old.Value.Dc }, null)
            : (null, error);
    }

    public static string? RestoreLid(LidBackup backup) => WriteLid(backup.Scheme, backup.Ac, backup.Dc);

    private static string? WriteLid(Guid scheme, uint ac, uint dc)
    {
        var s = scheme;
        var r1 = Native.PowerWriteACValueIndex(IntPtr.Zero, ref s, ref subButtons, ref lidAction, ac);
        var r2 = Native.PowerWriteDCValueIndex(IntPtr.Zero, ref s, ref subButtons, ref lidAction, dc);
        if (r1 == ErrorAccessDenied || r2 == ErrorAccessDenied)
            return "Windows needs an administrator account to change what the lid does.";
        if (r1 != 0 || r2 != 0) return $"Windows refused the lid setting (error {(r1 != 0 ? r1 : r2)}).";
        // Re-applying the active plan makes the new value take effect straight away.
        var active = ActiveScheme();
        if (active == scheme) Native.PowerSetActiveScheme(IntPtr.Zero, ref s);
        return null;
    }

    // ---- Battery ----

    public sealed record Battery(bool Present, bool OnBattery, int Percent);

    public static Battery ReadBattery()
    {
        var p = SystemInformation.PowerStatus;
        var present = (p.BatteryChargeStatus & BatteryChargeStatus.NoSystemBattery) == 0
                      && p.BatteryChargeStatus != BatteryChargeStatus.Unknown
                      && p.BatteryLifePercent <= 1f;
        var percent = present ? (int)Math.Round(p.BatteryLifePercent * 100) : 100;
        return new Battery(present, p.PowerLineStatus == PowerLineStatus.Offline, percent);
    }
}
