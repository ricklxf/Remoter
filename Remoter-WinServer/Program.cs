using System.Runtime.InteropServices;
using System.Windows.Forms;
using Vortice.MediaFoundation;

namespace RemoterWin;

public class Program
{
    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int dwProcessId);

    [STAThread]
    public static int Main(string[] args)
    {
        if (args != null && Array.IndexOf(args, "--self-test") >= 0)
        {
            try { AttachConsole(-1); } catch { }
            return RegressionTestRunner.RunAll();
        }
        try
        {
            MediaFactory.MFStartup();
        }
        catch (Exception ex)
        {
            // H264Encoder.Initialize will fail loudly per-session if MF truly
            // isn't usable; don't block the whole app from starting over this.
            AppLog.Write($"[Global] MFStartup failed: {ex.Message}");
        }

        // Register global exception handlers
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (sender, args) =>
        {
            AppLog.Write($"[Global] UI Thread Exception: {args.Exception.Message}");
            AppLog.Write($"[Global] StackTrace: {args.Exception.StackTrace}");
        };
        
        AppDomain.CurrentDomain.UnhandledException += (sender, args) =>
        {
            var ex = args.ExceptionObject as Exception;
            AppLog.Write($"[Global] Unhandled Exception: {ex?.Message ?? "Unknown"}");
            AppLog.Write($"[Global] StackTrace: {ex?.StackTrace ?? "N/A"}");
        };
        
        TaskScheduler.UnobservedTaskException += (sender, args) =>
        {
            AppLog.Write($"[Global] Unobserved Task Exception: {args.Exception.Message}");
            AppLog.Write($"[Global] StackTrace: {args.Exception.StackTrace}");
            args.SetObserved(); // Mark as observed to prevent crash
        };

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        
        try
        {
            UdpVideoServer.Shared.Start(7789);
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Global] UdpVideoServer start failed (falling back to WS): {ex.Message}");
        }

        try
        {
            Application.Run(new MainForm());
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Global] Application.Run Exception: {ex.Message}");
            AppLog.Write($"[Global] StackTrace: {ex.StackTrace}");
            MessageBox.Show($"程序发生错误：{ex.Message}\n\n请查看日志文件获取详细信息。", 
                "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            UdpVideoServer.Shared.Stop();
        }
        return 0;
    }
}
