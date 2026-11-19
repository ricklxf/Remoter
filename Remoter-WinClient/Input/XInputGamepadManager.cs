using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace RemoterWinClient.Input;

/// <summary>
/// UU-Remote compatible 16-bit gamepad button bitmask (matches GamepadStreaming.swift).
/// </summary>
[Flags]
public enum GamepadButtonFlags : ushort
{
    None      = 0,
    A         = 1 << 0,
    B         = 1 << 1,
    X         = 1 << 2,
    Y         = 1 << 3,
    L1        = 1 << 4,
    R1        = 1 << 5,
    DpadUp    = 1 << 6,
    DpadDown  = 1 << 7,
    DpadLeft  = 1 << 8,
    DpadRight = 1 << 9,
    L3        = 1 << 10,
    R3        = 1 << 11,
    Menu      = 1 << 12,
    Options   = 1 << 13,
}

/// <summary>
/// Compact 14-byte gamepad state packet modeled on UU-Remote's GamepadPacket (magic 0x5547 'UG').
/// </summary>
public readonly record struct GamepadStatePacket(
    GamepadButtonFlags Buttons,
    short LeftStickX,
    short LeftStickY,
    short RightStickX,
    short RightStickY,
    byte LeftTrigger,
    byte RightTrigger)
{
    public const ushort Magic = 0x5547; // 'UG'
    public const int SerializedSize = 14;

    public void Serialize(Span<byte> dest)
    {
        if (dest.Length < SerializedSize)
            throw new ArgumentException("Buffer too small", nameof(dest));
        BinaryPrimitives.WriteUInt16BigEndian(dest.Slice(0, 2), Magic);
        BinaryPrimitives.WriteUInt16BigEndian(dest.Slice(2, 2), (ushort)Buttons);
        BinaryPrimitives.WriteInt16BigEndian(dest.Slice(4, 2), LeftStickX);
        BinaryPrimitives.WriteInt16BigEndian(dest.Slice(6, 2), LeftStickY);
        BinaryPrimitives.WriteInt16BigEndian(dest.Slice(8, 2), RightStickX);
        BinaryPrimitives.WriteInt16BigEndian(dest.Slice(10, 2), RightStickY);
        dest[12] = LeftTrigger;
        dest[13] = RightTrigger;
    }
}

/// <summary>
/// Pure native Win32 XInput 120Hz gamepad poller (xinput1_4.dll with xinput9_1_0.dll fallback),
/// inspired by UU-Remote's 120Hz GamepadStreaming. Applies stick deadzone filtering and emits
/// state packets only when controller state changes.
/// </summary>
public sealed class XInputGamepadManager : IDisposable
{
    private const uint ERROR_SUCCESS = 0;
    private const short LeftThumbDeadzone = 7849;
    private const short RightThumbDeadzone = 8689;
    private const byte TriggerThreshold = 30;

    private const ushort XINPUT_DPAD_UP        = 0x0001;
    private const ushort XINPUT_DPAD_DOWN      = 0x0002;
    private const ushort XINPUT_DPAD_LEFT      = 0x0004;
    private const ushort XINPUT_DPAD_RIGHT     = 0x0008;
    private const ushort XINPUT_START          = 0x0010;
    private const ushort XINPUT_BACK           = 0x0020;
    private const ushort XINPUT_LEFT_THUMB     = 0x0040;
    private const ushort XINPUT_RIGHT_THUMB    = 0x0080;
    private const ushort XINPUT_LEFT_SHOULDER  = 0x0100;
    private const ushort XINPUT_RIGHT_SHOULDER = 0x0200;
    private const ushort XINPUT_A              = 0x1000;
    private const ushort XINPUT_B              = 0x2000;
    private const ushort XINPUT_X              = 0x4000;
    private const ushort XINPUT_Y              = 0x8000;

    private CancellationTokenSource? _cts;
    private Task? _pollTask;
    private bool _useLegacyXInput;
    private bool _xInputUnavailable;
    private bool _disposed;

    private GamepadStatePacket _lastPacket;
    private bool _hasLastPacket;

    /// <summary>Fired on the polling thread (up to 120Hz) whenever the active gamepad state changes.</summary>
    public event Action<GamepadStatePacket>? StateChanged;

    public bool IsRunning => _pollTask != null && !_pollTask.IsCompleted;

    public void Start()
    {
        if (_disposed || IsRunning || _xInputUnavailable) return;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        _pollTask = Task.Run(() => PollLoopAsync(ct), ct);
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        _pollTask = null;
        _hasLastPacket = false;
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(8)); // ~120Hz
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
            {
                if (!TryReadFirstConnected(out XINPUT_STATE state)) continue;

                var gp = state.Gamepad;
                var buttons = MapButtons(gp.wButtons);
                short lx = ApplyDeadzone(gp.sThumbLX, LeftThumbDeadzone);
                short ly = ApplyDeadzone(gp.sThumbLY, LeftThumbDeadzone);
                short rx = ApplyDeadzone(gp.sThumbRX, RightThumbDeadzone);
                short ry = ApplyDeadzone(gp.sThumbRY, RightThumbDeadzone);
                byte lt = gp.bLeftTrigger > TriggerThreshold ? gp.bLeftTrigger : (byte)0;
                byte rt = gp.bRightTrigger > TriggerThreshold ? gp.bRightTrigger : (byte)0;

                var packet = new GamepadStatePacket(buttons, lx, ly, rx, ry, lt, rt);
                if (!_hasLastPacket || packet != _lastPacket)
                {
                    _lastPacket = packet;
                    _hasLastPacket = true;
                    StateChanged?.Invoke(packet);
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private bool TryReadFirstConnected(out XINPUT_STATE state)
    {
        state = default;
        for (uint i = 0; i < 4; i++)
        {
            uint res;
            try
            {
                res = _useLegacyXInput
                    ? XInputGetStateLegacy(i, out state)
                    : XInputGetStateModern(i, out state);
            }
            catch (DllNotFoundException)
            {
                if (!_useLegacyXInput)
                {
                    _useLegacyXInput = true;
                    continue;
                }
                _xInputUnavailable = true;
                return false;
            }

            if (res == ERROR_SUCCESS) return true;
        }
        return false;
    }

    private static short ApplyDeadzone(short value, short deadzone)
    {
        if (value > -deadzone && value < deadzone) return 0;
        return value;
    }

    private static GamepadButtonFlags MapButtons(ushort w)
    {
        GamepadButtonFlags f = GamepadButtonFlags.None;
        if ((w & XINPUT_A) != 0) f |= GamepadButtonFlags.A;
        if ((w & XINPUT_B) != 0) f |= GamepadButtonFlags.B;
        if ((w & XINPUT_X) != 0) f |= GamepadButtonFlags.X;
        if ((w & XINPUT_Y) != 0) f |= GamepadButtonFlags.Y;
        if ((w & XINPUT_LEFT_SHOULDER) != 0) f |= GamepadButtonFlags.L1;
        if ((w & XINPUT_RIGHT_SHOULDER) != 0) f |= GamepadButtonFlags.R1;
        if ((w & XINPUT_DPAD_UP) != 0) f |= GamepadButtonFlags.DpadUp;
        if ((w & XINPUT_DPAD_DOWN) != 0) f |= GamepadButtonFlags.DpadDown;
        if ((w & XINPUT_DPAD_LEFT) != 0) f |= GamepadButtonFlags.DpadLeft;
        if ((w & XINPUT_DPAD_RIGHT) != 0) f |= GamepadButtonFlags.DpadRight;
        if ((w & XINPUT_LEFT_THUMB) != 0) f |= GamepadButtonFlags.L3;
        if ((w & XINPUT_RIGHT_THUMB) != 0) f |= GamepadButtonFlags.R3;
        if ((w & XINPUT_START) != 0) f |= GamepadButtonFlags.Menu;
        if ((w & XINPUT_BACK) != 0) f |= GamepadButtonFlags.Options;
        return f;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
    }

    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]
    private static extern uint XInputGetStateModern(uint dwUserIndex, out XINPUT_STATE pState);

    [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")]
    private static extern uint XInputGetStateLegacy(uint dwUserIndex, out XINPUT_STATE pState);

    [StructLayout(LayoutKind.Sequential)]
    private struct XINPUT_GAMEPAD
    {
        public ushort wButtons;
        public byte   bLeftTrigger;
        public byte   bRightTrigger;
        public short  sThumbLX;
        public short  sThumbLY;
        public short  sThumbRX;
        public short  sThumbRY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XINPUT_STATE
    {
        public uint           dwPacketNumber;
        public XINPUT_GAMEPAD Gamepad;
    }
}
