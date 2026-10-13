package com.cloudwebrtc.webrtc.audio;

import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * C-25 (2026-10-13, operator: «Build 2009b with meter»): a level meter on the APM's capture OUTPUT. The fork's
 * capture post-processing hook runs after the gain controllers (AGC2) and before the encoder, so this is the level
 * the far side receives — unlike the raw {@code audio_device_buffer.cc [REC] level} line, which samples the device
 * buffer BEFORE the APM. One logcat line per period: {@code tkm C-25: [APM out] peak=… rms=… (… dBFS) …}. Samples
 * are WebRTC's float AudioBuffer in int16 scale (±32768). No allocation per frame; cost = one pass over 10 ms.
 */
public final class CaptureLevelMeter implements AudioProcessingAdapter.ExternalAudioFrameProcessing {
  private static final String TAG = "FlutterWebRTC";
  private static final int PERIOD_FRAMES = 1000; // 10 ms frames → one line per 10 s
  private static CaptureLevelMeter installed;

  private volatile boolean enabled;
  private int rate;
  private int frames;
  private long samples;
  private double sumSq;
  private float peak;

  /** Installs the one meter on the capture post-processing adapter (once) and turns it on or off. */
  public static synchronized void install(AudioProcessingAdapter capturePost, boolean on) {
    if (installed == null) {
      installed = new CaptureLevelMeter();
      capturePost.addProcessor(installed);
    }
    installed.enabled = on;
    installed.clear();
    Log.i(TAG, "tkm C-25: [APM out] level meter " + (on ? "ON" : "OFF"));
  }

  private void clear() {
    frames = 0;
    samples = 0;
    sumSq = 0;
    peak = 0;
  }

  @Override
  public void initialize(int sampleRateHz, int numChannels) {
    rate = sampleRateHz;
    clear();
  }

  @Override
  public void reset(int newRate) {
    rate = newRate;
    clear();
  }

  @Override
  public void process(int numBands, int numFrames, ByteBuffer buffer) {
    if (!enabled) {
      return;
    }
    FloatBuffer fb = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer();
    int n = Math.min(numFrames, fb.remaining()); // full-band channel 0
    for (int i = 0; i < n; i++) {
      float v = fb.get(i);
      float a = v < 0 ? -v : v;
      if (a > peak) {
        peak = a;
      }
      sumSq += (double) v * v;
    }
    samples += n;
    frames++;
    if (frames >= PERIOD_FRAMES) {
      double rms = samples == 0 ? 0 : Math.sqrt(sumSq / samples);
      double dbfs = rms <= 0 ? -120 : 20 * Math.log10(rms / 32768.0);
      Log.i(TAG, String.format(java.util.Locale.ROOT,
          "tkm C-25: [APM out] peak=%d rms=%d (%.1f dBFS) over %d ms, rate=%d bands=%d",
          (int) peak, (int) rms, dbfs, frames * 10, rate, numBands));
      clear();
    }
  }
}
