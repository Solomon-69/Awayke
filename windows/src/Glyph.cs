using System.Drawing.Drawing2D;

namespace Awayke;

/// <summary>
/// The tray candle, drawn in code (same shapes as the Mac Glyph.swift).
/// AWAKE = a lit candle with a teardrop flame. OFF = an unlit candle with a thin wisp of smoke.
/// </summary>
internal static class Glyph
{
    public static void Draw(Graphics g, float px, bool awake, Color color)
    {
        // The tallest state (lit) reaches 0.85 of h, so h can be larger than the icon square.
        var h = px * 1.1f;
        var bottom = px * 0.97f;
        var cx = px / 2f;
        var lw = Math.Max(1f, px / 13f);
        float Y(float up) => bottom - up;   // the Mac draws y-up; GDI+ is y-down

        using var brush = new SolidBrush(color);
        using var pen = new Pen(color, lw * 0.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round };

        // Candle body.
        float bodyW = h * 0.40f, bodyH = h * 0.38f;
        using (var body = RoundedRect(new RectangleF(cx - bodyW / 2, Y(bodyH), bodyW, bodyH), lw * 0.9f))
            g.FillPath(brush, body);

        // Wick.
        var wickTop = bodyH + h * (awake ? 0.13f : 0.05f);
        g.DrawLine(pen, cx, Y(bodyH), cx, Y(wickTop));

        if (awake)
        {
            float fh = h * 0.36f, fw = h * 0.30f;
            var baseY = wickTop - h * 0.02f;
            var tipY = Math.Min(h, baseY + fh);
            using var flame = new GraphicsPath(FillMode.Alternate);
            flame.AddBezier(cx, Y(tipY), cx + fw * 0.95f, Y(baseY + fh * 0.30f), cx + fw * 0.55f, Y(baseY), cx, Y(baseY));
            flame.AddBezier(cx, Y(baseY), cx - fw * 0.55f, Y(baseY), cx - fw * 0.95f, Y(baseY + fh * 0.30f), cx, Y(tipY));
            flame.CloseFigure();
            var core = fw * 0.34f;
            flame.AddEllipse(cx - core / 2, Y(baseY + fh * 0.12f + core * 1.35f), core, core * 1.35f);   // hollow core
            g.FillPath(brush, flame);
        }
        else
        {
            var sy = wickTop + h * 0.06f;
            using var smoke = new Pen(color, lw * 0.75f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawBezier(smoke, cx, Y(sy), cx + h * 0.16f, Y(sy + h * 0.07f), cx - h * 0.14f, Y(sy + h * 0.16f),
                         cx + h * 0.02f, Y(Math.Min(h, sy + h * 0.24f)));
        }
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var d = Math.Max(0.5f, radius * 2);
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
