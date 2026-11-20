namespace RemoterWin;

interface IWsConn
{
    string RemoteAddr { get; }
    Task SendTextAsync(string text);
    Task SendBinaryAsync(byte[] data);
    void Disconnect();
}
