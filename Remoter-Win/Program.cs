using System.Windows.Forms;
using Vortice.MediaFoundation;

namespace RemoterWin;

public class Program
{
    [STAThread]
    public static void Main()
    {
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
            Application.Run(new MainForm());
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Global] Application.Run Exception: {ex.Message}");
            AppLog.Write($"[Global] StackTrace: {ex.StackTrace}");
            MessageBox.Show($"程序发生错误：{ex.Message}\n\n请查看日志文件获取详细信息。", 
                "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
