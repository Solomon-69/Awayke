using Microsoft.Win32;

namespace Kit;

/// <summary>
/// Windows light/dark. Two separate settings: apps (AppsUseLightTheme) and the taskbar
/// (SystemUsesLightTheme). Tray icons follow the taskbar one, panels follow the apps one.
/// </summary>
internal sealed class SystemTheme : IDisposable
{
    public const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    private readonly Control uiThread;

    public bool AppsDark { get; private set; }
    public bool TaskbarDark { get; private set; }

    /// <summary>Raised on the UI thread whenever either value changes.</summary>
    public event Action? Changed;

    public SystemTheme(Control uiThread)
    {
        this.uiThread = uiThread;
        (AppsDark, TaskbarDark) = Read();
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
    }

    private async void OnPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is not (UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)) return;
        Post(Refresh);
        await Task.Delay(300);   // the registry can lag the broadcast a little
        Post(Refresh);
    }

    private void Post(Action a)
    {
        try
        {
            if (uiThread.IsHandleCreated && !uiThread.IsDisposed) uiThread.BeginInvoke(a);
        }
        catch (InvalidOperationException)
        {
            // Shutting down.
        }
    }

    public void Refresh()
    {
        var (apps, taskbar) = Read();
        if (apps == AppsDark && taskbar == TaskbarDark) return;
        AppsDark = apps;
        TaskbarDark = taskbar;
        Changed?.Invoke();
    }

    public static (bool apps, bool taskbar) Read()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            var apps = key?.GetValue("AppsUseLightTheme") is int a && a == 0;
            // Missing SystemUsesLightTheme (older Windows 10) means a dark taskbar.
            var taskbar = key?.GetValue("SystemUsesLightTheme") is not int t || t == 0;
            return (apps, taskbar);
        }
        catch
        {
            return (false, true);
        }
    }

    public void Dispose() => SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
}
