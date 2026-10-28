using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace RemoterWin;

// Media Foundation AAC Audio Encoder.
// Encodes raw PCM samples into 7-byte ADTS-framed AAC-LC packets (FrameType 0x03)
// matching the format expected by the WebCodecs AudioDecoder ('mp4a.40.2').
sealed class AudioEncoder : IDisposable
{
    public Action<byte[]>? OnEncodedFrame;

    private IMFTransform? _transform;
    private bool _initialized;
    private readonly object _lock = new();

    private static readonly Guid CLSID_AACMFTEncoder = new("93023151-D54A-4F66-9703-B801494BDE0D");
    private static readonly Guid MF_MT_MAJOR_TYPE    = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid MF_MT_SUBTYPE       = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid MF_MT_AUDIO_SAMPLES_PER_SECOND = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    private static readonly Guid MF_MT_AUDIO_NUM_CHANNELS       = new("37eab8d7-9f43-41bb-9e29-79718b1accfb");
    private static readonly Guid MF_MT_AUDIO_BITS_PER_SAMPLE    = new("f2deb57f-4009-4497-b647-7359de047294");
    private static readonly Guid MF_MT_AUDIO_AVG_BYTES_PER_SECOND = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");

    private static readonly Guid MFAudioFormat_PCM = new("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid MFAudioFormat_AAC = new("00001610-0000-0010-8000-00aa00389b71");
    private static readonly Guid MfMediaTypeAudio  = new("73647561-0000-0010-8000-00aa00389b71");

    public void Initialize(int sampleRate = 48000, int channels = 2, int bitrateBps = 128000)
    {
        lock (_lock)
        {
            if (_initialized) return;

            try
            {
                // Create AAC Encoder MFT
                var mftType = Type.GetTypeFromCLSID(CLSID_AACMFTEncoder);
                if (mftType == null)
                {
                    AppLog.Write("[AudioEncoder] CLSID_AACMFTEncoder not found");
                    return;
                }

                _transform = (IMFTransform)Activator.CreateInstance(mftType)!;

                // 1. Set Output Type (AAC)
                using var outType = MediaFactory.MFCreateMediaType();
                outType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeAudio);
                outType.Set(MF_MT_SUBTYPE, MFAudioFormat_AAC);
                outType.Set(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
                outType.Set(MF_MT_AUDIO_SAMPLES_PER_SECOND, sampleRate);
                outType.Set(MF_MT_AUDIO_NUM_CHANNELS, channels);
                outType.Set(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bitrateBps / 8);

                _transform.SetOutputType(0, outType, 0);

                // 2. Set Input Type (PCM)
                using var inType = MediaFactory.MFCreateMediaType();
                inType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeAudio);
                inType.Set(MF_MT_SUBTYPE, MFAudioFormat_PCM);
                inType.Set(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
                inType.Set(MF_MT_AUDIO_SAMPLES_PER_SECOND, sampleRate);
                inType.Set(MF_MT_AUDIO_NUM_CHANNELS, channels);

                _transform.SetInputType(0, inType, 0);

                _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
                _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
                _initialized = true;

                AppLog.Write($"[AudioEncoder] AAC encoder ready: {sampleRate}Hz {channels}ch {bitrateBps / 1000}kbps");
            }
            catch (Exception ex)
            {
                AppLog.Write($"[AudioEncoder] Init failed: {ex.Message}");
            }
        }
    }

    public void EncodePcm(byte[] pcmData, int length)
    {
        if (!_initialized || _transform == null || length <= 0) return;

        lock (_lock)
        {
            try
            {
                using var buffer = MediaFactory.MFCreateMemoryBuffer(length);
                buffer.Lock(out nint dst, out _, out _);
                Marshal.Copy(pcmData, 0, dst, length);
                buffer.Unlock();
                buffer.CurrentLength = length;

                using var sample = MediaFactory.MFCreateSample();
                sample.AddBuffer(buffer);

                _transform.ProcessInput(0, sample, 0);

                DrainOutput();
            }
            catch (Exception ex)
            {
                AppLog.Write($"[AudioEncoder] Encode error: {ex.Message}");
            }
        }
    }

    private void DrainOutput()
    {
        if (_transform == null) return;

        while (true)
        {
            var outputData = new MFTOutputDataBuffer[1];
            using var outBuffer = MediaFactory.MFCreateMemoryBuffer(4096);
            using var outSample = MediaFactory.MFCreateSample();
            outSample.AddBuffer(outBuffer);
            outputData[0].Sample = outSample;

            var hr = _transform.ProcessOutput(0, outputData, out _);
            if (hr.Failure) break;

            using var resSample = outputData[0].Sample;
            if (resSample == null) break;

            using var resBuffer = resSample.ConvertToContiguousBuffer();
            resBuffer.Lock(out nint pSrc, out _, out int aacLen);
            if (aacLen > 0)
            {
                var adtsHeader = CreateAdtsHeader(aacLen, 48000, 2);
                var fullPacket = new byte[adtsHeader.Length + aacLen];
                Buffer.BlockCopy(adtsHeader, 0, fullPacket, 0, adtsHeader.Length);
                Marshal.Copy(pSrc, fullPacket, adtsHeader.Length, aacLen);

                resBuffer.Unlock();
                OnEncodedFrame?.Invoke(fullPacket);
            }
            else
            {
                resBuffer.Unlock();
            }
        }
    }

    // 7-byte ADTS header for AAC-LC
    private static byte[] CreateAdtsHeader(int aacLength, int sampleRate, int channels)
    {
        int srIdx = sampleRate switch
        {
            96000 => 0, 88200 => 1, 64000 => 2, 48000 => 3,
            44100 => 4, 32000 => 5, 24000 => 6, 22050 => 7,
            16000 => 8, _ => 3
        };
        int profile = 2; // AAC-LC
        int len = aacLength + 7;
        return
        [
            0xFF,
            0xF1,
            (byte)(((profile - 1) << 6) | (srIdx << 2) | ((channels >> 2) & 1)),
            (byte)(((channels & 3) << 6) | ((len >> 11) & 3)),
            (byte)((len >> 3) & 0xFF),
            (byte)(((len & 7) << 5) | 0x1F),
            0xFC
        ];
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_initialized && _transform != null)
            {
                try
                {
                    _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                    _transform.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero);
                }
                catch { }
                _transform.Dispose();
                _transform = null;
                _initialized = false;
            }
        }
    }
}
