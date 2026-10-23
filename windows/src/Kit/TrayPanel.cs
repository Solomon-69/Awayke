using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Kit;

/// <summary>
/// The tray panel: a borderless, rounded window that opens just above the tray icon (on whichever side
/// the taskbar is), hosting the app's HTML page (embedded in the exe) in WebView2.
/// Page to app: <c>chrome.webview.postMessage({type, ...})</c>. App to page: <see cref="Run"/>.
/// The page reports its own height (<c>{type:'height', h}</c>) so the panel always fits its content.
/// </summary>
internal sealed class TrayPanel : Form
{
    private const int GapDip = 12;
    private const int ReopenGuardMs = 500;   // a tray click that closed the panel must not reopen it at once
    private const int FadeMs = 160;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int CS_DROPSHADOW = 0x00020000;

    private readonly WebView2 web;
    private readonly string origin;
    private readonly string host;
    private readonly Func<string> bootScript;
    private readonly Func<bool> dark;
    private readonly Color lightBack, darkBack;
    private readonly int widthDip;
    private int heightDip;
    private Point anchor;
    private bool hasAnchor;
    private bool quitting;
    private long lastHiddenAt;
    private CoreWebView2Environment? env;

    public bool IsReady { get; private set; }
    /// <summary>Keeps the panel open when it loses focus (used by the automated test only).</summary>
    public bool StayOpen { get; set; }

    public event Action<string, JsonElement>? Message;
    public event Action? Ready;
    public event Action? Shown2;
    public event Action? Hidden;

    public TrayPanel(string app, int widthDip, int heightDip, Func<string> bootScript, Func<bool> dark, Color lightBack, Color darkBack)
    {
        host = app.ToLowerInvariant() + ".example";   // .example never exists on the internet
        origin = "https://" + host + "/";
        this.widthDip = widthDip;
        this.heightDip = heightDip;
        this.bootScript = bootScript;
        this.dark = dark;
        this.lightBack = lightBack;
        this.darkBack = darkBack;

        Text = app;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.None;   // sized per monitor in PanelBounds
        MinimizeBox = MaximizeBox = ControlBox = false;

        web = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(web);
        ApplyColors();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW;   // no taskbar button, no Alt+Tab entry
            if (!Native.IsWindows11) cp.ClassStyle |= CS_DROPSHADOW;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.SetDwmInt(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, Native.DWMWCP_ROUND);
        ApplyColors();
    }

    // ---------- WebView2 ----------

    public async Task InitializeAsync()
    {
        try
        {
            _ = Handle;
            _ = web.Handle;
            var userData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Files.App, "WebView2");
            env = await CoreWebView2Environment.CreateAsync(null, userData);
            await web.EnsureCoreWebView2Async(env);
            var core = web.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.IsPinchZoomEnabled = false;   // trackpad pinch: nothing
            // Whatever gets through (Ctrl+wheel, Ctrl +/-/0) is put straight back: the page is never zoomed.
            web.ZoomFactorChanged += (_, _) => { if (Math.Abs(web.ZoomFactor - 1.0) > 0.001) web.ZoomFactor = 1.0; };
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;
            core.Settings.AreDevToolsEnabled = false;

            core.AddWebResourceRequestedFilter(origin + "*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += ServeEmbedded;
            await core.AddScriptToExecuteOnDocumentCreatedAsync(bootScript());
            core.WebMessageReceived += OnWebMessage;
            core.NavigationStarting += (_, e) =>
            {
                if (!e.Uri.StartsWith(origin, StringComparison.OrdinalIgnoreCase)) e.Cancel = true;
            };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.NavigationCompleted += (_, e) =>
            {
                IsReady = e.IsSuccess;
                if (!e.IsSuccess) { Files.Log($"Page failed to load: {e.WebErrorStatus}"); return; }
                Ready?.Invoke();
            };
            core.ProcessFailed += (_, e) =>
            {
                Files.Log($"WebView2 process failed: {e.ProcessFailedKind}");
                if (e.ProcessFailedKind is CoreWebView2ProcessFailedKind.RenderProcessExited
                    or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)
                    core.Navigate(origin + "panel.html");
            };
            core.Navigate(origin + "panel.html");
        }
        catch (Exception ex)
        {
            Files.Log($"WebView2 start failed: {ex}");
            MessageBox.Show($"{Files.App} could not start its panel (Microsoft Edge WebView2).\n\n{ex.Message}",
                            Files.App, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void ServeEmbedded(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        if (env == null) return;
        var path = Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri) ? uri.AbsolutePath.TrimStart('/') : "";
        if (path.Length == 0) path = "panel.html";
        var stream = Resources.Open("web/" + path);
        e.Response = stream == null
            ? env.CreateWebResourceResponse(null, 404, "Not Found", "")
            : env.CreateWebResourceResponse(stream, 200, "OK", $"Content-Type: {Resources.Mime(path)}\nCache-Control: no-store");
    }

    /// <summary>Runs JavaScript in the page (ignored until it has loaded).</summary>
    public void Run(string js)
    {
        if (web.CoreWebView2 == null) return;
        web.ExecuteScriptAsync(js).ContinueWith(
            t => Files.Log($"Script failed: {t.Exception?.GetBaseException().Message}"),
            CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
    }

    /// <summary>Test aid: writes the zoom/layout state, waits for the test to press keys and scroll, writes it again (twice).</summary>
    public async Task ZoomProbe(string basePath)
    {
        async Task Write(string name)
        {
            var page = await Eval("JSON.stringify({w:innerWidth,h:innerHeight,dpr:devicePixelRatio})");
            var b = Bounds;
            File.WriteAllText(basePath + name, JsonSerializer.Serialize(new
            {
                zoom = web.ZoomFactor,
                page = JsonSerializer.Deserialize<string>(page),
                bounds = new[] { b.X, b.Y, b.Width, b.Height },
            }));
        }
        async Task Gate(string go)
        {
            for (var i = 0; i < 400 && !File.Exists(basePath + go); i++) await Task.Delay(150);
            await Task.Delay(800);
        }
        await Task.Delay(1200);
        await Write(".z0");
        await Gate(".go1"); await Write(".z1");
        await Gate(".go2"); await Write(".z2");
    }

    public async Task<string> Eval(string js) =>
        web.CoreWebView2 == null ? "null" : await web.ExecuteScriptAsync(js);

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!e.Source.StartsWith(origin, StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var msg = doc.RootElement.Clone();
            if (msg.ValueKind != JsonValueKind.Object || !msg.TryGetProperty("type", out var t) || t.ValueKind != JsonValueKind.String) return;
            var type = t.GetString()!;
            if (type == "height")
            {
                if (msg.TryGetProperty("h", out var h) && h.TryGetDouble(out var hv))
                {
                    var next = Math.Clamp((int)Math.Ceiling(hv), 120, 2000);
                    if (next != heightDip)
                    {
                        heightDip = next;
                        if (Visible) Bounds = PanelBounds();
                    }
                }
                return;
            }
            // Leave the WebView2 event first: handlers may close or dispose things.
            BeginInvoke(() => Message?.Invoke(type, msg));
        }
        catch (JsonException ex)
        {
            Files.Log($"Bad message from page: {ex.Message}");
        }
    }

    // ---------- Colours ----------

    public void ApplyColors()
    {
        var isDark = dark();
        var back = isDark ? darkBack : lightBack;
        BackColor = back;
        web.DefaultBackgroundColor = back;
        if (IsHandleCreated)
        {
            Native.SetDwmInt(Handle, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, isDark ? 1 : 0);
            // Thin border in the panel's own tone instead of the accent colour Windows might use.
            var border = isDark ? Color.FromArgb(0x3A, 0x3A, 0x44) : Color.FromArgb(0xD8, 0xD6, 0xE0);
            Native.SetDwmInt(Handle, Native.DWMWA_BORDER_COLOR, border.R | (border.G << 8) | (border.B << 16));
        }
    }

    // ---------- Show and hide ----------

    public void Toggle(Point? at)
    {
        if (Visible) { HidePanel(); return; }
        if (Environment.TickCount64 - lastHiddenAt < ReopenGuardMs) return;
        ShowPanel(at);
    }

    public void ShowPanel(Point? at = null)
    {
        if (quitting) return;
        if (at.HasValue) { anchor = at.Value; hasAnchor = true; }
        else if (!hasAnchor)
        {
            var work = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
            anchor = new Point(work.Right - 1, work.Bottom - 1);
        }
        Bounds = PanelBounds();
        if (!Visible) Show();
        Activate();
        Native.SetForegroundWindow(Handle);
        web.Focus();
        if (IsReady) Run("window.kit && kit.opened()");
        Shown2?.Invoke();
    }

    public void HidePanel()
    {
        if (!Visible) return;
        Hide();
        lastHiddenAt = Environment.TickCount64;
        if (IsReady) Run("window.kit && kit.closed()");
        Hidden?.Invoke();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!quitting && !StayOpen) HidePanel();   // click anywhere else = close
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        e.Cancel = true;   // sized by hand per monitor
        base.OnDpiChanged(e);
        if (Visible) BeginInvoke(() => Bounds = PanelBounds());
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { HidePanel(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    /// <summary>Panel rectangle in physical pixels: DIP size times the monitor scale, docked to the taskbar side.</summary>
    private Rectangle PanelBounds()
    {
        var screen = Screen.FromPoint(anchor);
        var work = screen.WorkingArea;
        var scale = Native.ScaleAt(anchor);
        var gap = (int)Math.Round(GapDip * scale);
        var w = Math.Min((int)Math.Round(widthDip * scale), work.Width - gap * 2);
        var h = Math.Min((int)Math.Round(heightDip * scale), work.Height - gap * 2);
        var edge = TaskbarEdge(screen);
        if (work == screen.Bounds)
        {
            // Auto-hidden taskbar: leave room for it to slide in.
            var reserve = (int)Math.Round(48 * scale);
            work = edge switch
            {
                Native.ABE_LEFT => new Rectangle(work.Left + reserve, work.Top, work.Width - reserve, work.Height),
                Native.ABE_TOP => new Rectangle(work.Left, work.Top + reserve, work.Width, work.Height - reserve),
                Native.ABE_RIGHT => new Rectangle(work.Left, work.Top, work.Width - reserve, work.Height),
                _ => new Rectangle(work.Left, work.Top, work.Width, work.Height - reserve),
            };
        }
        int x, y;
        switch (edge)
        {
            case Native.ABE_LEFT: x = work.Left + gap; y = anchor.Y - h / 2; break;
            case Native.ABE_RIGHT: x = work.Right - gap - w; y = anchor.Y - h / 2; break;
            case Native.ABE_TOP: x = anchor.X - w / 2; y = work.Top + gap; break;
            default: x = anchor.X - w / 2; y = work.Bottom - gap - h; break;
        }
        x = Math.Clamp(x, work.Left + gap, Math.Max(work.Left + gap, work.Right - gap - w));
        y = Math.Clamp(y, work.Top + gap, Math.Max(work.Top + gap, work.Bottom - gap - h));
        return new Rectangle(x, y, w, h);
    }

    private static uint TaskbarEdge(Screen screen)
    {
        var b = screen.Bounds;
        var w = screen.WorkingArea;
        if (w.Bottom < b.Bottom) return Native.ABE_BOTTOM;
        if (w.Top > b.Top) return Native.ABE_TOP;
        if (w.Left > b.Left) return Native.ABE_LEFT;
        if (w.Right < b.Right) return Native.ABE_RIGHT;
        return Native.TaskbarEdge();
    }

    // ---------- Quit ----------

    /// <summary>Fades the page out (if showing) and hides the panel, ready for the app to exit.</summary>
    public async Task FadeOutAsync()
    {
        if (quitting) return;
        quitting = true;
        try
        {
            if (Visible && IsReady)
            {
                await web.ExecuteScriptAsync($"window.kit && kit.fadeOut({FadeMs})");
                await Task.Delay(FadeMs + 30);
            }
        }
        catch (Exception ex)
        {
            Files.Log($"Quit fade skipped: {ex.Message}");
        }
        Hide();
    }
}

/// <summary>Files embedded in the exe (the panel's HTML, CSS and JS, and anything else listed in the project).</summary>
internal static class Resources
{
    private static readonly Dictionary<string, string> Names = typeof(Resources).Assembly.GetManifestResourceNames()
        .ToDictionary(n => n.Replace('\\', '/'), n => n, StringComparer.OrdinalIgnoreCase);

    public static Stream? Open(string path)
    {
        if (path.Contains("..")) return null;
        return Names.TryGetValue(path.Replace('\\', '/'), out var real)
            ? typeof(Resources).Assembly.GetManifestResourceStream(real)
            : null;
    }

    public static IEnumerable<string> Under(string prefix) =>
        Names.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));

    public static string Mime(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".json" => "application/json",
        ".png" => "image/png",
        ".svg" => "image/svg+xml",
        _ => "application/octet-stream",
    };
}
