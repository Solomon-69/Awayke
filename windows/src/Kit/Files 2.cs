using System.Text.Json;
using Microsoft.Win32;

namespace Kit;

/// <summary>
/// Everything an app keeps on disk, under %APPDATA%\&lt;App&gt;: settings.json and a small local log.
/// "Open at login" is the per-user HKCU Run key. Nothing leaves the PC.
/// </summary>
internal static class Files
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static string App { get; private set; } = "App";
    public static string Folder { get; private set; } = "";

    public static void Init(string app)
    {
        App = app;
        Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), app);
    }

    public static T Load<T>(string name) where T : new()
    {
        var path = Path.Combine(Folder, name);
        try
        {
            if (File.Exists(path)) return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) ?? new T();
        }
        catch (Exception ex)
        {
            Log($"{name} could not be read, using defaults: {ex.Message}");
        }
        return new T();
    }

    /// <summary>Atomic write (temp file, then replace) so a crash never leaves half a file.</summary>
    public static void Save<T>(string name, T value)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var path = Path.Combine(Folder, name);
            File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, Json));
            File.Move(path + ".tmp", path, overwrite: true);
        }
        catch (Exception ex)
        {
            Log($"Could not write {name}: {ex.Message}");
        }
    }

    public static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.AppendAllText(Path.Combine(Folder, App.ToLowerInvariant() + ".log"),
                               $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never take the app down.
        }
    }

    // ---- Open at login ----

    public static bool LoginEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(App) is string;
        }
        catch (Exception ex)
        {
            Log($"Run key could not be read: {ex.Message}");
            return false;
        }
    }

    public static void SetLogin(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (on) key.SetValue(App, $"\"{ExePath}\"", RegistryValueKind.String);
            else key.DeleteValue(App, throwOnMissingValue: false);
        }
        catch (Exception ex)
        {
            Log($"Open at login change failed: {ex.Message}");
        }
    }

    /// <summary>Keeps the Run entry pointing at this exe after the folder was moved.</summary>
    public static void RefreshLoginPath()
    {
        if (LoginEnabled()) SetLogin(true);
    }

    public static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    /// <summary>Writes a result file for the automated test (any path the test chose).</summary>
    public static void WriteJson(string path, object value)
    {
        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(value, Json));
        }
        catch (Exception ex)
        {
            Log($"Self-test file not written: {ex.Message}");
        }
    }
}

/// <summary>
/// One copy per user session. A second launch signals the running copy instead
/// ("open the panel", or "quit" for <c>--quit</c>) and exits.
/// </summary>
internal sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly EventWaitHandle openEvent;
    private readonly EventWaitHandle quitEvent;
    private RegisteredWaitHandle? openWait, quitWait;

    private SingleInstance(Mutex mutex, EventWaitHandle open, EventWaitHandle quit)
    {
        this.mutex = mutex;
        openEvent = open;
        quitEvent = quit;
    }

    /// <summary>Returns null when another copy is already running (it has been signalled).</summary>
    public static SingleInstance? Claim(string app, bool quitRequested)
    {
        var mutex = new Mutex(initiallyOwned: true, $@"Local\{app}.SingleInstance", out var first);
        if (!first)
        {
            try
            {
                using var signal = EventWaitHandle.OpenExisting(quitRequested ? $@"Local\{app}.Quit" : $@"Local\{app}.Open");
                Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                signal.Set();
            }
            catch (Exception ex)
            {
                Files.Log($"Could not signal the running copy: {ex.Message}");
            }
            mutex.Dispose();
            return null;
        }
        return new SingleInstance(mutex,
            new EventWaitHandle(false, EventResetMode.AutoReset, $@"Local\{app}.Open"),
            new EventWaitHandle(false, EventResetMode.AutoReset, $@"Local\{app}.Quit"));
    }

    public void Listen(Action onOpen, Action onQuit)
    {
        openWait = ThreadPool.RegisterWaitForSingleObject(openEvent, (_, _) => onOpen(), null, Timeout.Infinite, false);
        quitWait = ThreadPool.RegisterWaitForSingleObject(quitEvent, (_, _) => onQuit(), null, Timeout.Infinite, false);
    }

    public void Dispose()
    {
        openWait?.Unregister(null);
        quitWait?.Unregister(null);
        openEvent.Dispose();
        quitEvent.Dispose();
        try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
        mutex.Dispose();
    }
}

/// <summary>Command-line switches used by people (--quit) and by the automated Windows test.</summary>
internal sealed record LaunchArgs(bool TestOpen, bool Quit, string? SelfTestPath, IReadOnlySet<string> Flags)
{
    public static LaunchArgs Parse(string[] args)
    {
        string? path = null;
        var flags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in args)
        {
            if (a.StartsWith("--selftest=", StringComparison.OrdinalIgnoreCase)) path = a["--selftest=".Length..].Trim('"');
            else flags.Add(a);
        }
        return new LaunchArgs(flags.Contains("--test-open"), flags.Contains("--quit"), path, flags);
    }

    public bool Has(string flag) => Flags.Contains(flag);
}
