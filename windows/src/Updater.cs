using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Awayke;

/// <summary>"Update now" (Windows). Asks GitHub for the newest release, downloads Awayke-windows.zip, checks its SHA-256
/// against the release's SHA256SUMS, unzips to a temp folder, then a small PowerShell helper waits for Awayke to exit,
/// copies the new files over the install folder and starts Awayke again. Any failure leaves the installed app untouched.</summary>
internal static class Updater
{
    public const string Repo = "Solomon-69/Awayke";
    public const string ZipName = "Awayke-windows.zip";
    public sealed record Offer(string Tag, Uri Zip, Uri Sums);

    private static readonly HttpClient Http = MakeClient();
    private static readonly TimeSpan Stall = TimeSpan.FromSeconds(30);

    private static HttpClient MakeClient()
    {
        var h = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(20) }) { Timeout = Timeout.InfiniteTimeSpan };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("Awayke-Windows/" + AwaykeApp.Version);
        return h;
    }

    public static bool Allowed(Uri u) => u.Scheme == Uri.UriSchemeHttps &&
        (u.Host is "github.com" or "api.github.com" || u.Host.EndsWith(".githubusercontent.com", StringComparison.OrdinalIgnoreCase));

    /// <summary>"hash  name" lines (sha256sum style, a leading * on the name allowed).</summary>
    public static string? ExpectedHash(string sums, string name)
    {
        foreach (var raw in sums.Split('\n'))
        {
            var line = raw.Trim();
            var cut = line.IndexOfAny(new[] { ' ', '\t' });
            if (cut != 64) continue;
            var hash = line[..64].ToLowerInvariant();
            if (line[64..].Trim(' ', '\t', '*') == name && hash.All(Uri.IsHexDigit)) return hash;
        }
        return null;
    }

    /// <summary>Newest release: its tag plus the Windows zip and checksum links. Null links mean "no Windows build yet".</summary>
    public static async Task<(string Tag, Offer? Offer)> LatestAsync()
    {
        using var cts = new CancellationTokenSource(Stall);
        using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
        req.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var res = await Http.SendAsync(req, cts.Token);
        var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(cts.Token));
        var tag = doc.RootElement.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "";
        if (!res.IsSuccessStatusCode || tag.Length == 0) throw new InvalidOperationException("GitHub did not answer.");
        Uri? zip = null, sums = null;
        if (doc.RootElement.TryGetProperty("assets", out var assets))
            foreach (var a in assets.EnumerateArray())
            {
                var n = a.GetProperty("name").GetString() ?? "";
                var u = new Uri(a.GetProperty("browser_download_url").GetString() ?? "https://invalid/");
                if (n == ZipName) zip = u;
                else if (n.Contains("SHA256SUMS", StringComparison.OrdinalIgnoreCase)) sums = u;
            }
        return (tag, zip != null && sums != null ? new Offer(tag, zip, sums) : null);
    }

    /// <summary>Downloads and checks the zip, unzips it, returns the folder that holds Awayke.exe. Nothing is installed here.</summary>
    public static async Task<string> DownloadAsync(Offer o, IProgress<double> progress)
    {
        if (!Allowed(o.Zip) || !Allowed(o.Sums)) throw new InvalidOperationException("source not allowed");
        var work = Path.Combine(Path.GetTempPath(), "awayke-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            string sumsText;
            using (var c = new CancellationTokenSource(Stall)) sumsText = await Http.GetStringAsync(o.Sums, c.Token);
            var want = ExpectedHash(sumsText, ZipName) ?? throw new InvalidOperationException("the release has no checksum for the download");

            var file = Path.Combine(work, ZipName);
            progress.Report(1);
            using (var head = new CancellationTokenSource(Stall))
            using (var resp = await Http.GetAsync(o.Zip, HttpCompletionOption.ResponseHeadersRead, head.Token))
            {
                resp.EnsureSuccessStatusCode();
                var total = resp.Content.Headers.ContentLength ?? 0;
                await using var src = await resp.Content.ReadAsStreamAsync();
                await using var dst = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, useAsync: true);
                var buf = new byte[1 << 18]; long got = 0; double last = 1;
                while (true)
                {
                    using var cts = new CancellationTokenSource(Stall);
                    var n = await src.ReadAsync(buf, cts.Token);
                    if (n <= 0) break;
                    await dst.WriteAsync(buf.AsMemory(0, n));
                    got += n;
                    var p = total > 0 ? Math.Min(99, Math.Max(1, Math.Round(got * 100.0 / total))) : Math.Min(95, 1 + Math.Round(got / 1_000_000.0));
                    if (p != last) { last = p; progress.Report(p); }
                }
                if (total > 0 && got != total) throw new IOException($"download cut short ({got} of {total} bytes)");
            }
            string have;
            await using (var fs = File.OpenRead(file)) have = Convert.ToHexString(await SHA256.HashDataAsync(fs)).ToLowerInvariant();
            if (have != want) throw new InvalidOperationException("the download did not match its checksum");
            progress.Report(100);

            var x = Path.Combine(work, "x");
            ZipFile.ExtractToDirectory(file, x);
            File.Delete(file);
            var exe = Directory.EnumerateFiles(x, "Awayke.exe", SearchOption.AllDirectories).FirstOrDefault()
                      ?? throw new InvalidOperationException("the download is not Awayke");
            return Path.GetDirectoryName(exe)!;
        }
        catch
        {
            try { Directory.Delete(work, true); } catch { /* temp folder, best effort */ }
            throw;
        }
    }

    /// <summary>Starts the helper that waits for <paramref name="pid"/> to exit, copies the new files over the install
    /// folder and starts Awayke.exe again. The caller quits right after.</summary>
    public static void StartSwap(string staged, string installDir, int pid)
    {
        var script = Path.Combine(Path.GetTempPath(), "awayke-swap-" + Guid.NewGuid().ToString("N") + ".ps1");
        File.WriteAllText(script,
            "param([int]$ProcId,[string]$Staged,[string]$Install)\n" +
            "$ErrorActionPreference='SilentlyContinue'\n" +
            "while (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 200 }\n" +
            "Start-Sleep -Milliseconds 300\n" +
            "for ($i=0; $i -lt 10; $i++) { Copy-Item -Path (Join-Path $Staged '*') -Destination $Install -Recurse -Force -ErrorAction Stop; if ($?) { break }; Start-Sleep -Milliseconds 500 }\n" +
            "Start-Process -FilePath (Join-Path $Install 'Awayke.exe')\n" +
            "Remove-Item -Recurse -Force (Split-Path $Staged -Parent) -ErrorAction SilentlyContinue\n" +
            "Remove-Item -Force $PSCommandPath -ErrorAction SilentlyContinue\n");
        var psi = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        foreach (var a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProcId", pid.ToString(), "-Staged", staged, "-Install", installDir })
            psi.ArgumentList.Add(a);
        Process.Start(psi);
    }

    /// <summary>Test aid (no window, installs nothing): `Awayke.exe --selftest-update=RESULT.json` checks the newest release,
    /// downloads it, verifies the checksum and unzips it. Writes {ok, tag, seconds, error}.</summary>
    public static async Task<int> SelfTestAsync(string resultFile)
    {
        var sw = Stopwatch.StartNew(); string? tag = null, err = null; var ok = false;
        try
        {
            var (t, offer) = await LatestAsync(); tag = t;
            if (offer == null) throw new InvalidOperationException("the newest release has no Windows download");
            var dir = await DownloadAsync(offer, new Progress<double>());
            ok = File.Exists(Path.Combine(dir, "Awayke.exe"));
            try { Directory.Delete(Path.GetDirectoryName(dir)!, true); } catch { }
        }
        catch (Exception ex) { err = ex.Message; }
        File.WriteAllText(resultFile, JsonSerializer.Serialize(new { ok, tag, seconds = Math.Round(sw.Elapsed.TotalSeconds, 1), error = err }));
        return ok ? 0 : 1;
    }
}
