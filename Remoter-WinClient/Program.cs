using System.Runtime.InteropServices;
using System.Windows.Forms;
using RemoterWinClient.UI;

namespace RemoterWinClient;

public static class Program
{
    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint uPeriod);

    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint uPeriod);

    [STAThread]
    public static void Main()
    {
        // Request 1ms Windows multimedia timer resolution for low-latency frame pacing & input coalescing
        bool timerRaised = timeBeginPeriod(1) == 0;

        try
        {
            // Ensure Media Foundation is initialized once for hardware H.264/H.265 & AAC decoding
            try
            {
                MfVideoDecoder.EnsureMediaFoundationStarted();
            }
            catch
            {
                // Individual decoders will surface errors if MF is truly unavailable
            }

            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (_, args) =>
            {
                MessageBox.Show(
                    $"UI 线程异常: {args.Exception.Message}",
                    "Remoter Client",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            };
            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                args.SetObserved();
            };

            Application.Run(new ConnectForm());
        }
        finally
        {
            if (timerRaised)
            {
                timeEndPeriod(1);
            }
        }
    }
}
