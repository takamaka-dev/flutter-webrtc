package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import org.junit.Test;

/**
 * C182 S-9 (ruling Q7): every stock frameCryptor* / keyProvider* method is refused with "frameCryptor-disabled" —
 * a stock FrameCryptor attached after our SFrame transformer would replace it (last SetFrameTransformer wins).
 */
public class FlutterRTCFrameCryptorRefusalTest {
  private static final String[] STOCK = {
    "frameCryptorFactoryCreateFrameCryptor", "frameCryptorSetKeyIndex", "frameCryptorGetKeyIndex",
    "frameCryptorSetEnabled", "frameCryptorGetEnabled", "frameCryptorDispose", "frameCryptorFactoryCreateKeyProvider",
    "keyProviderSetSharedKey", "keyProviderRatchetSharedKey", "keyProviderExportSharedKey", "keyProviderSetKey",
    "keyProviderRatchetKey", "keyProviderExportKey", "keyProviderSetSifTrailer", "keyProviderDispose",
  };

  private static final class Recorded implements MethodChannel.Result {
    String errorCode;
    boolean success;
    boolean notImplemented;

    @Override
    public void success(Object result) {
      success = true;
    }

    @Override
    public void error(String code, String message, Object details) {
      errorCode = code;
    }

    @Override
    public void notImplemented() {
      notImplemented = true;
    }
  }

  @Test
  public void everyStockCryptorMethodIsRefused() {
    FlutterRTCFrameCryptor cryptor = new FlutterRTCFrameCryptor(null);
    for (String m : STOCK) {
      Map<String, Object> args = new HashMap<>();
      args.put("peerConnectionId", "pc");
      args.put("keyProviderId", "kp");
      Recorded r = new Recorded();
      assertTrue(m + " must be handled (refused), not passed on", cryptor.handleMethodCall(new MethodCall(m, args), r));
      assertEquals(m, FlutterRTCFrameCryptor.DISABLED_CODE, r.errorCode);
      assertFalse(m, r.success);
    }
  }

  @Test
  public void otherMethodsAreNotItsBusiness() {
    FlutterRTCFrameCryptor cryptor = new FlutterRTCFrameCryptor(null);
    Recorded r = new Recorded();
    assertFalse(cryptor.handleMethodCall(new MethodCall("sframeKeyStoreCreate", new HashMap<>()), r));
    assertFalse(cryptor.handleMethodCall(new MethodCall("dataPacketCryptorEncrypt", new HashMap<>()), r));
    assertNull(r.errorCode);
    assertFalse(FlutterRTCFrameCryptor.isStockCryptorMethod("sframeAutoAttach"));
    assertTrue(FlutterRTCFrameCryptor.isStockCryptorMethod("keyProviderSetKey"));
  }
}
