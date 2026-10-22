using System.Drawing.Drawing2D;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Kit;

/// <summary>
/// The tray icon: a glyph drawn in code at the exact tray size (so it stays crisp at any DPI),
/// a right-click menu that follows Windows light/dark, and the icon's position on screen.
/// </summary>
internal sealed class Tray : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly ContextMenuStrip menu;
    private Icon? current;

    public event Action<Point>? LeftClick;
    public event Action? Opening;

    public Tray(string text, ToolStripItem[] items, Func<bool> menuDark)
    {
        menu = new ContextMenuStrip { ShowImageMargin = false, ShowCheckMargin = true };
        menu.Items.AddRange(items);
        menu.Opening += (_, _) =>
        {
            Opening?.Invoke();
            MenuStyle.Apply(menu, menuDark());
        };
        icon = new NotifyIcon { Text = text, ContextMenuStrip = menu };
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) LeftClick?.Invoke(Center() ?? Cursor.Position);
        };
    }

    public bool Visible
    {
        get => icon.Visible;
        set => icon.Visible = value;
    }

    public string Text
    {
        set => icon.Text = value.Length > 127 ? value[..127] : value;
    }

    /// <summary>Draws a new glyph. <paramref name="draw"/> paints into a square of the given pixel size.</summary>
    public void SetGlyph(Action<Graphics, float> draw)
    {
        var px = TraySize();
        using var bmp = new Bitmap(px, px);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            draw(g, px);
        }
        var handle = bmp.GetHicon();
        var next = (Icon)Icon.FromHandle(handle).Clone();
        Native.DestroyIcon(handle);
        icon.Icon = next;
        current?.Dispose();
        current = next;
    }

    /// <summary>
    /// Test aid: draws each glyph at tray sizes on a dark and a light taskbar colour into one PNG,
    /// so the automated test can show what the icon looks like at 100-400% scale.
    /// </summary>
    public static void SaveSheet(string path, IReadOnlyList<Action<Graphics, float, bool>> glyphs)
    {
        int[] sizes = { 16, 20, 24, 32, 64 };
        const int cell = 72;
        using var sheet = new Bitmap(cell * sizes.Length * 2, cell * glyphs.Count);
        using var g = Graphics.FromImage(sheet);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        for (var row = 0; row < glyphs.Count; row++)
        {
            for (var half = 0; half < 2; half++)
            {
                var darkBar = half == 0;
                using var back = new SolidBrush(darkBar ? Color.FromArgb(0x20, 0x20, 0x20) : Color.FromArgb(0xF3, 0xF3, 0xF3));
                g.FillRectangle(back, half * cell * sizes.Length, row * cell, cell * sizes.Length, cell);
                for (var i = 0; i < sizes.Length; i++)
                {
                    var px = sizes[i];
                    var state = g.Save();
                    g.TranslateTransform(half * cell * sizes.Length + i * cell + (cell - px) / 2f, row * cell + (cell - px) / 2f);
                    glyphs[row](g, px, darkBar);
                    g.Restore(state);
                }
            }
        }
        sheet.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    public void Balloon(string title, string text) => icon.ShowBalloonTip(4000, title, text, ToolTipIcon.None);

    private static int TraySize()
    {
        try
        {
            return Math.Max(16, Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, Native.GetDpiForSystem()));
        }
        catch
        {
            return SystemInformation.SmallIconSize.Width;
        }
    }

    /// <summary>Screen rectangle of the icon, or null when Windows will not say (hidden in the overflow).</summary>
    public Rectangle? Bounds()
    {
        try
        {
            IntPtr hwnd = IntPtr.Zero;
            uint? id = null;
            foreach (var f in typeof(NotifyIcon).GetFields(BindingFlags.Instance | BindingFlags.NonPublic))
            {
                var v = f.GetValue(icon);
                if (v is NativeWindow nw) hwnd = nw.Handle;
                else if (f.Name.TrimStart('_').Equals("id", StringComparison.OrdinalIgnoreCase) && v != null) id = Convert.ToUInt32(v);
            }
            if (hwnd == IntPtr.Zero || id == null) return null;
            var nid = new Native.NOTIFYICONIDENTIFIER
            {
                cbSize = (uint)Marshal.SizeOf<Native.NOTIFYICONIDENTIFIER>(),
                hWnd = hwnd,
                uID = id.Value,
            };
            if (Native.Shell_NotifyIconGetRect(ref nid, out var rc) != 0) return null;
            var r = Rectangle.FromLTRB(rc.Left, rc.Top, rc.Right, rc.Bottom);
            return r.Width > 0 && r.Height > 0 ? r : null;
        }
        catch (Exception ex)
        {
            Files.Log($"Tray position unknown: {ex.Message}");
            return null;
        }
    }

    public Point? Center()
    {
        var b = Bounds();
        return b is { } r ? new Point(r.Left + r.Width / 2, r.Top + r.Height / 2) : null;
    }

    public void Dispose()
    {
        icon.Visible = false;   // no ghost icon left behind
        icon.Dispose();
        menu.Dispose();
        current?.Dispose();
    }
}

/// <summary>Tray menu colours that follow Windows light/dark (WinForms menus are always light otherwise).</summary>
internal static class MenuStyle
{
    private static readonly Colors LightColors = new(false), DarkColors = new(true);
    private static readonly ToolStripProfessionalRenderer LightRenderer = new(LightColors) { RoundedEdges = true };
    private static readonly ToolStripProfessionalRenderer DarkRenderer = new(DarkColors) { RoundedEdges = true };

    public static void Apply(ContextMenuStrip menu, bool dark)
    {
        var c = dark ? DarkColors : LightColors;
        menu.Renderer = dark ? DarkRenderer : LightRenderer;
        menu.BackColor = c.Back;
        foreach (ToolStripItem item in menu.Items) item.ForeColor = c.Text;
    }

    private sealed class Colors : ProfessionalColorTable
    {
        public Color Back { get; }
        public Color Text { get; }
        private readonly Color hover, line;

        public Colors(bool dark)
        {
            UseSystemColors = false;
            Back = dark ? Color.FromArgb(0x2B, 0x2B, 0x2B) : Color.FromArgb(0xF9, 0xF9, 0xF9);
            Text = dark ? Color.FromArgb(0xF2, 0xF2, 0xF2) : Color.FromArgb(0x1A, 0x1A, 0x1A);
            hover = dark ? Color.FromArgb(0x3D, 0x3D, 0x3D) : Color.FromArgb(0xE9, 0xE9, 0xE9);
            line = dark ? Color.FromArgb(0x48, 0x48, 0x48) : Color.FromArgb(0xDD, 0xDD, 0xDD);
        }

        public override Color ToolStripDropDownBackground => Back;
        public override Color MenuBorder => line;
        public override Color MenuItemBorder => hover;
        public override Color MenuItemSelected => hover;
        public override Color MenuItemSelectedGradientBegin => hover;
        public override Color MenuItemSelectedGradientEnd => hover;
        public override Color ImageMarginGradientBegin => Back;
        public override Color ImageMarginGradientMiddle => Back;
        public override Color ImageMarginGradientEnd => Back;
        public override Color SeparatorDark => line;
        public override Color SeparatorLight => Back;
        public override Color CheckBackground => hover;
        public override Color CheckSelectedBackground => hover;
        public override Color CheckPressedBackground => hover;
    }
}
