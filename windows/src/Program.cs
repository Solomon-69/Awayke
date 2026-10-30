using System.Diagnostics;
using Kit;
using Microsoft.Web.WebView2.Core;

namespace Awayke;

internal static class Program
{
    private const string WebView2Download = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

    [STAThread]
    private static void Main(string[] argv)
    {
        Files.Init("Awayke");
        var updateTest = argv.FirstOrDefault(a => a.StartsWith("--selftest-update=", StringComparison.Ordinal));
        if (updateTest != null) { Environment.ExitCode = Updater.SelfTestAsync(updateTest["--selftest-update=".Length..]).GetAwaiter().GetResult(); return; }
        var args = LaunchArgs.Parse(argv);

        using var instance = SingleInstance.Claim("Awayke", args.Quit);
        if (instance == null || args.Quit) return;   // the running copy was asked to open or quit

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Files.Log($"Unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Files.Log($"Fatal: {e.ExceptionObject}");

        if (!WebView2Ready()) return;

        var app = new AwaykeApp(args);
        instance.Listen(app.OpenFromOutside, app.QuitFromOutside);
        Application.Run(app);
    }

    private static bool WebView2Ready()
    {
        try
        {
            if (!string.IsNullOrEmpty(CoreWebView2Environment.GetAvailableBrowserVersionString())) return true;
        }
        catch (WebView2RuntimeNotFoundException)
        {
        }
        catch (Exception ex)
        {
            Files.Log($"WebView2 check failed: {ex.Message}");
            return true;
        }
        var answer = MessageBox.Show(
            "Awayke needs the Microsoft Edge WebView2 Runtime, which is missing on this PC.\n\n" +
            "It is built into Windows 11 and a free, small download from Microsoft for Windows 10.\n\nOpen the download page now?",
            "Awayke", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (answer == DialogResult.Yes) Process.Start(new ProcessStartInfo(WebView2Download) { UseShellExecute = true });
        return false;
    }
}
