using System.Text.Json;
using Kit;
using Microsoft.Win32;

namespace Awayke;

/// <summary>
/// Awayke for Windows: a candle in the tray. On = Windows stays awake (and, if chosen, keeps running with
/// the lid closed). Auto-off timer, battery cut-off, open at login. Always starts switched off.
/// </summary>
internal sealed class AwaykeApp : ApplicationContext
{
    public const string Version = "1.5.0";
    private const int TickMs = 10_000;

    private static readonly Color LightBack = Color.FromArgb(0xF3, 0xF3, 0xF3);
    private static readonly Color DarkBack = Color.FromArgb(0x24, 0x24, 0x26);

    private readonly LaunchArgs args;
    private readonly Settings s;
    private readonly Control invoker = new();
    private readonly SystemTheme theme;
    private readonly TrayPanel panel;
    private readonly Tray tray;
    private readonly ToolStripMenuItem awakeItem;
    private readonly System.Windows.Forms.Timer tick = new() { Interval = TickMs };

    private bool on;
    private DateTime? since, offAt;
    private int timer;
    private string? lidError;
    private string? notice;
    private bool exiting;

    public AwaykeApp(LaunchArgs args)
    {
        this.args = args;
        _ = invoker.Handle;
        s = Files.Load<Settings>("settings.json").Clean();
        if (s.LidSaved != null)
        {
            // Left over from a crash or power cut: put the lid back the way it was.
            Files.Log("Restoring the lid setting left by the last run.");
            RestoreLid();
        }
        timer = s.DefaultTimer;
        Files.RefreshLoginPath();

        theme = new SystemTheme(invoker);
        panel = new TrayPanel("Awayke", 340, 460, BootScript, () => theme.AppsDark, LightBack, DarkBack);
        panel.Message += OnMessage;
        panel.Ready += OnReady;
        theme.Changed += () => { panel.ApplyColors(); UpdateTray(); Push(); };

        awakeItem = new ToolStripMenuItem("Keep awake", null, (_, _) => SetOn(!on));
        var openItem = new ToolStripMenuItem("Open Awayke", null, (_, _) => panel.ShowPanel(tray!.Center()));
        openItem.Font = new Font(openItem.Font, FontStyle.Bold);
        var quitItem = new ToolStripMenuItem("Quit", null, (_, _) => Quit());
        tray = new Tray("Awayke", new ToolStripItem[] { awakeItem, openItem, new ToolStripSeparator(), quitItem }, () => theme.TaskbarDark);
        tray.Opening += () => awakeItem.Checked = on;
        tray.LeftClick += at =>
        {
            if (s.ClickToggles) SetOn(!on);
            else panel.Toggle(at);
        };
        UpdateTray();
        tray.Visible = true;

        tick.Tick += (_, _) => Tick();
        tick.Start();
        SystemEvents.SessionEnding += OnSessionEnding;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        Application.Idle += StartOnce;
    }

    private void StartOnce(object? sender, EventArgs e)
    {
        Application.Idle -= StartOnce;
        _ = panel.InitializeAsync();
    }

    // ---------- Awake on / off ----------

    private void SetOn(bool want)
    {
        if (want == on || exiting) { Push(); return; }
        notice = null;
        if (want)
        {
            var battery = Power.ReadBattery();
            if (battery.Present && battery.OnBattery && battery.Percent <= s.FloorPercent)
            {
                notice = $"Battery is at {battery.Percent}%, at or below your {s.FloorPercent}% cut-off.";
                Push();
                return;
            }
            if (!Power.KeepAwake(true, s.KeepDisplayAwake)) Files.Log("SetThreadExecutionState failed.");
            on = true;
            since = DateTime.Now;
            offAt = timer > 0 ? DateTime.Now.AddMinutes(timer) : null;
            if (s.LidMode) ApplyLid();
        }
        else
        {
            Power.KeepAwake(false, false);
            RestoreLid();
            on = false;
            since = offAt = null;
        }
        UpdateTray();
        Push();
    }

    private void ApplyLid()
    {
        if (s.LidSaved != null) return;
        var (backup, error) = Power.LidDoNothing();
        lidError = error;
        if (error != null) Files.Log($"Lid: {error}");
        if (backup == null) return;
        s.LidSaved = backup;
        Save();
    }

    private void RestoreLid()
    {
        if (s.LidSaved == null) return;
        var error = Power.RestoreLid(s.LidSaved);
        if (error != null) { Files.Log($"Lid restore: {error}"); return; }
        s.LidSaved = null;
        Save();
    }

    private void Tick()
    {
        if (on && offAt is { } t && DateTime.Now >= t)
        {
            SetOn(false);
            tray.Balloon("Awayke", "Timer finished. Your PC can sleep normally again.");
        }
        var battery = Power.ReadBattery();
        if (on && battery.Present && battery.OnBattery && battery.Percent <= s.FloorPercent)
        {
            SetOn(false);
            tray.Balloon("Awayke", $"Battery at {battery.Percent}%. Awayke switched off so your PC can sleep.");
        }
        Push();
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.StatusChange) invoker.BeginInvoke(Tick);
    }

    private void OnSessionEnding(object? sender, SessionEndingEventArgs e)
    {
        // Signing out or shutting down: the lid must behave normally from the next start.
        try { invoker.Invoke(RestoreLid); } catch (Exception ex) { Files.Log($"Session end: {ex.Message}"); }
    }

    // ---------- Tray ----------

    private Color Accent(bool darkBackground)
    {
        var (light, dark) = Settings.Accents[s.Accent];
        return darkBackground ? dark : light;
    }

    private void UpdateTray()
    {
        var fg = theme.TaskbarDark ? Color.White : Color.FromArgb(0x1A, 0x1A, 0x1A);
        var color = on && !s.MonochromeIcon ? Accent(theme.TaskbarDark) : fg;
        tray.SetGlyph((g, px) => Glyph.Draw(g, px, on, color));
        tray.Text = on ? "Awayke: awake" : "Awayke: sleeps normally";
    }

    // ---------- Page bridge ----------

    private string BootScript() => $"window.__BOOT__ = {StateJson()};";

    private void Push()
    {
        if (panel.IsReady) panel.Run($"window.app && app.update({StateJson()})");
    }

    private string StateJson()
    {
        static long? Ms(DateTime? d) => d is { } v ? new DateTimeOffset(v).ToUnixTimeMilliseconds() : null;
        var battery = Power.ReadBattery();
        var accent = Accent(theme.AppsDark);
        return JsonSerializer.Serialize(new
        {
            on,
            since = Ms(since),
            offAt = Ms(offAt),
            timer,
            lidMode = s.LidMode,
            lidError,
            notice,
            display = s.KeepDisplayAwake,
            choices = s.TimerChoices,
            defaultTimer = s.DefaultTimer,
            floor = s.FloorPercent,
            battery = new { present = battery.Present, onBattery = battery.OnBattery, percent = battery.Percent },
            login = Files.LoginEnabled(),
            clickToggles = s.ClickToggles,
            accent = s.Accent,
            accentColor = $"#{accent.R:X2}{accent.G:X2}{accent.B:X2}",
            accents = Settings.Accents.ToDictionary(a => a.Key, a =>
            {
                var c = theme.AppsDark ? a.Value.Dark : a.Value.Light;
                return $"#{c.R:X2}{c.G:X2}{c.B:X2}";
            }),
            mono = s.MonochromeIcon,
            dark = theme.AppsDark,
            version = Version,
            maxChoices = Settings.MaxTimerChoices,
        });
    }

    private static bool Bool(JsonElement m, string name) => m.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static int Int(JsonElement m, string name, int fallback = 0) =>
        m.TryGetProperty(name, out var v) && v.TryGetInt32(out var i) ? i : fallback;

    private void OnMessage(string type, JsonElement m)
    {
        switch (type)
        {
            case "toggle": SetOn(Bool(m, "on")); return;
            case "timer":
                var minutes = Int(m, "minutes");
                timer = minutes == 0 || s.TimerChoices.Contains(minutes) ? minutes : timer;
                if (on) offAt = timer > 0 ? DateTime.Now.AddMinutes(timer) : null;
                break;
            case "lid":
                s.LidMode = Bool(m, "on");
                lidError = null;
                if (on) { if (s.LidMode) ApplyLid(); else RestoreLid(); }
                break;
            case "display":
                s.KeepDisplayAwake = Bool(m, "on");
                if (on) Power.KeepAwake(true, s.KeepDisplayAwake);
                break;
            case "floor": s.FloorPercent = Math.Clamp(Int(m, "percent", 15), Settings.FloorMin, Settings.FloorMax); break;
            case "login": Files.SetLogin(Bool(m, "on")); break;
            case "clickToggles": s.ClickToggles = Bool(m, "on"); break;
            case "addTimer":
                var add = Int(m, "minutes");
                if (add is >= 5 and <= Settings.MaxTimerMinutes && s.TimerChoices.Count < Settings.MaxTimerChoices && !s.TimerChoices.Contains(add))
                    s.TimerChoices = s.TimerChoices.Append(add).Order().ToList();
                break;
            case "removeTimer":
                var remove = Int(m, "minutes");
                s.TimerChoices = s.TimerChoices.Where(x => x != remove).ToList();
                if (s.DefaultTimer == remove) s.DefaultTimer = 0;
                if (timer == remove) timer = 0;
                break;
            case "defaultTimer":
                var d = Int(m, "minutes");
                s.DefaultTimer = d == 0 || s.TimerChoices.Contains(d) ? d : 0;
                break;
            case "accent":
                var name = m.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                if (Settings.Accents.ContainsKey(name)) s.Accent = name;
                break;
            case "mono": s.MonochromeIcon = Bool(m, "on"); break;
            case "close": panel.HidePanel(); return;
            case "quit": Quit(); return;
            default: return;
        }
        Save();
        UpdateTray();
        Push();
    }

    private void Save() => Files.Save("settings.json", s);

    // ---------- Start-up test hooks and outside signals ----------

    private async void OnReady()
    {
        Push();
        if (args.Has("--test-on")) SetOn(true);
        if (args.TestOpen)
        {
            panel.StayOpen = true;
            panel.ShowPanel(tray.Center());
        }
        if (args.Has("--test-settings")) panel.Run("document.getElementById('openSettings').click()");
        if (args.Has("--test-zoomprobe") && args.SelfTestPath != null) { await panel.ZoomProbe(args.SelfTestPath); return; }
        if (args.SelfTestPath != null)
        {
            await Task.Delay(2500);
            WriteSelfTest(args.SelfTestPath);
            static Color Fg(bool darkBar) => darkBar ? Color.White : Color.FromArgb(0x1A, 0x1A, 0x1A);
            Tray.SaveSheet(Path.ChangeExtension(args.SelfTestPath, ".icons.png"), new Action<Graphics, float, bool>[]
            {
                (g, px, darkBar) => Glyph.Draw(g, px, false, Fg(darkBar)),
                (g, px, darkBar) => Glyph.Draw(g, px, true, Accent(darkBar)),
                (g, px, darkBar) => Glyph.Draw(g, px, true, Fg(darkBar)),
            });
        }
    }

    private void WriteSelfTest(string path)
    {
        var scheme = Power.ActiveScheme();
        var lid = scheme is { } g ? Power.ReadLid(g) : null;
        var b = panel.Bounds;
        Files.WriteJson(path, new
        {
            app = "Awayke",
            pid = Environment.ProcessId,
            ready = panel.IsReady,
            panelVisible = panel.Visible,
            panelBounds = new[] { b.X, b.Y, b.Width, b.Height },
            tray = tray.Bounds() is { } r ? new[] { r.X, r.Y, r.Width, r.Height } : null,
            on,
            lidMode = s.LidMode,
            lidError,
            lidSaved = s.LidSaved,
            lidNow = lid is { } l ? new[] { l.Ac, l.Dc } : null,
            battery = Power.ReadBattery(),
        });
    }

    public void OpenFromOutside() => Post(() => panel.ShowPanel(tray.Center()));

    public void QuitFromOutside() => Post(Quit);

    private void Post(Action a)
    {
        try { if (!exiting) invoker.BeginInvoke(a); }
        catch (Exception ex) when (ex is ObjectDisposedException or InvalidOperationException) { }
    }

    // ---------- Quit ----------

    private async void Quit()
    {
        if (exiting) return;
        exiting = true;
        tick.Stop();
        await panel.FadeOutAsync();
        Power.KeepAwake(false, false);
        RestoreLid();
        SystemEvents.SessionEnding -= OnSessionEnding;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        tray.Dispose();
        theme.Dispose();
        panel.Dispose();
        tick.Dispose();
        ExitThread();
    }
}
