namespace Awayke;

/// <summary>Saved choices (%APPDATA%\Awayke\settings.json). Awayke always starts switched off.</summary>
internal sealed class Settings
{
    public const int MaxTimerChoices = 5;
    public const int MaxTimerMinutes = 24 * 60;
    public const int FloorMin = 5, FloorMax = 50;

    public bool LidMode { get; set; } = true;
    public bool KeepDisplayAwake { get; set; } = true;
    public List<int> TimerChoices { get; set; } = new() { 15, 30, 60, 120 };
    public int DefaultTimer { get; set; }
    public int FloorPercent { get; set; } = 15;
    public bool ClickToggles { get; set; }
    public string Accent { get; set; } = "Ember";
    public bool MonochromeIcon { get; set; }

    /// <summary>The lid-close action Awayke changed, kept until it is put back (also after a crash).</summary>
    public LidBackup? LidSaved { get; set; }

    /// <summary>Repairs anything out of range in a hand-edited or older file.</summary>
    public Settings Clean()
    {
        TimerChoices = TimerChoices.Where(m => m is >= 5 and <= MaxTimerMinutes).Distinct().Order().Take(MaxTimerChoices).ToList();
        if (DefaultTimer != 0 && !TimerChoices.Contains(DefaultTimer)) DefaultTimer = 0;
        FloorPercent = Math.Clamp(FloorPercent, FloorMin, FloorMax);
        if (!Accents.ContainsKey(Accent)) Accent = "Ember";
        return this;
    }

    /// <summary>Accent colours: (on a light background, on a dark background), as on the Mac.</summary>
    public static readonly Dictionary<string, (Color Light, Color Dark)> Accents = new()
    {
        ["Ember"] = (Color.FromArgb(0xE0, 0x7B, 0x00), Color.FromArgb(0xFF, 0x9F, 0x0A)),
        ["Rose"] = (Color.FromArgb(0xFF, 0x2D, 0x55), Color.FromArgb(0xFF, 0x37, 0x5F)),
        ["Violet"] = (Color.FromArgb(0xAF, 0x52, 0xDE), Color.FromArgb(0xBF, 0x5A, 0xF2)),
        ["Ocean"] = (Color.FromArgb(0x00, 0x7A, 0xFF), Color.FromArgb(0x0A, 0x84, 0xFF)),
        ["Lagoon"] = (Color.FromArgb(0x30, 0xB0, 0xC7), Color.FromArgb(0x40, 0xC8, 0xE0)),
        ["Moss"] = (Color.FromArgb(0x34, 0xC7, 0x59), Color.FromArgb(0x30, 0xD1, 0x58)),
    };
}

internal sealed class LidBackup
{
    public Guid Scheme { get; set; }
    public uint Ac { get; set; }
    public uint Dc { get; set; }
}
