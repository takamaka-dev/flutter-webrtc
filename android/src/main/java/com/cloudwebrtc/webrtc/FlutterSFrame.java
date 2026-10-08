// Takamaka E2EE calls (C182 / DR-055): the RFC 9605 SFrame transformer of our webrtc-sdk fork
// (org.webrtc.SFrameKeyStore / SFrameCryptor) exposed to Dart. Replaces the stock FrameCryptor path for our calls;
// method names are new ("sframe*") so an app on a binary without them fails loudly instead of running another
// cipher. No key byte is ever logged or sent back to Dart (only the vector seams return units).
//
// Auto-attach: once a key store is chosen with "sframeAutoAttach", EVERY RtpSender created by any PeerConnection of
// this plugin (addTrack / addTransceiver) gets a sealing transformer inside the same native call that created it, and
// EVERY RtpReceiver an opening transformer in onAddTrack, before the event reaches Dart. So a library that creates
// its own transceivers (livekit_client) cannot send a frame before the transformer is attached.
package com.cloudwebrtc.webrtc;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.cloudwebrtc.webrtc.utils.AnyThreadSink;

import org.webrtc.MediaStreamTrack;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpSender;
import org.webrtc.RtpTransceiver;
import org.webrtc.SFrameCryptor;
import org.webrtc.SFrameKeyStore;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.Result;

public class FlutterSFrame {
  private static final String TAG = "FlutterSFrame";

  /** The plugin's instance, for the PeerConnectionObserver hooks. */
  @Nullable static volatile FlutterSFrame instance;

  private static final class Store implements SFrameKeyStore.Observer {
    final String id;
    final SFrameKeyStore keyStore;
    final EventChannel channel;
    volatile EventChannel.EventSink sink;
    final List<Map<String, Object>> queue = new ArrayList<>();

    Store(String id, SFrameKeyStore keyStore, BinaryMessenger messenger) {
      this.id = id;
      this.keyStore = keyStore;
      this.channel = new EventChannel(messenger, "FlutterWebRTC/sframeEvents/" + id);
      this.channel.setStreamHandler(new EventChannel.StreamHandler() {
        @Override
        public void onListen(Object o, EventChannel.EventSink s) {
          synchronized (queue) {
            sink = new AnyThreadSink(s);
            for (Map<String, Object> e : queue) sink.success(e);
            queue.clear();
          }
        }

        @Override
        public void onCancel(Object o) {
          sink = null;
        }
      });
    }

    @Override
    public void onSFrameEvent(String type, String streamId, String reason, long kid, long consecutive) {
      Map<String, Object> e = new HashMap<>();
      e.put("event", type);
      e.put("streamId", streamId);
      e.put("reason", reason);
      e.put("kid", kid);
      e.put("consecutive", consecutive);
      synchronized (queue) {
        if (sink != null) {
          sink.success(e);
        } else if (queue.size() < 1000) {
          queue.add(e);
        }
      }
    }
  }

  private static final class Attached {
    final String id;
    final String storeId;
    final SFrameCryptor cryptor;
    final String role;
    final String kind;

    Attached(String id, String storeId, SFrameCryptor cryptor, String role, String kind) {
      this.id = id;
      this.storeId = storeId;
      this.cryptor = cryptor;
      this.role = role;
      this.kind = kind;
    }
  }

  private final StateProvider stateProvider;
  // Concurrent maps and NO monitor held across native calls: attaching calls into WebRTC proxies that block on the
  // signaling thread, which itself calls onReceiverAdded — a lock held here across those calls could deadlock.
  private final Map<String, Store> stores = new ConcurrentHashMap<>();
  private final Map<String, Attached> cryptors = new ConcurrentHashMap<>();
  /** "pc/send/<senderId>" or "pc/recv/<receiverId>" → attached cryptor id. */
  private final Map<String, String> byEndpoint = new ConcurrentHashMap<>();
  @Nullable private volatile String autoAttachStoreId;

  public FlutterSFrame(StateProvider stateProvider) {
    this.stateProvider = stateProvider;
    instance = this;
  }

  // ---- hooks called by PeerConnectionObserver ------------------------------------------------------------------

  /** A sender was just created (addTrack / addTransceiver), before its result goes back to Dart. */
  void onSenderCreated(String peerConnectionId, @Nullable RtpSender sender, @Nullable String transceiverKind) {
    final String storeId = autoAttachStoreId;
    if (storeId == null || sender == null) return;
    String kind = transceiverKind;
    MediaStreamTrack t = sender.track();
    if (t != null) kind = t.kind();
    String key = peerConnectionId + "/send/" + sender.id();
    if (byEndpoint.containsKey(key)) return;
    attach(storeId, peerConnectionId, sender, null, kind, "send:" + kind + ":" + sender.id());
  }

  /** A remote track arrived (onAddTrack), before the event goes to Dart. */
  void onReceiverAdded(String peerConnectionId, @Nullable RtpReceiver receiver) {
    final String storeId = autoAttachStoreId;
    if (storeId == null || receiver == null || receiver.track() == null) return;
    String kind = receiver.track().kind();
    String key = peerConnectionId + "/recv/" + receiver.id();
    if (byEndpoint.containsKey(key)) return;
    attach(storeId, peerConnectionId, null, receiver, kind, "recv:" + kind + ":" + receiver.track().id());
  }

  static String kindOf(@Nullable RtpTransceiver t) {
    if (t == null) return null;
    return t.getMediaType() == MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO ? "audio" : "video";
  }

  // ---- method channel -------------------------------------------------------------------------------------------

  public boolean handleMethodCall(MethodCall call, @NonNull Result result) {
    if (!call.method.startsWith("sframe")) return false;
    try {
      dispatch(call, result);
    } catch (Exception e) {
      Log.w(TAG, call.method + " failed: " + e.getClass().getSimpleName());
      result.error(call.method + "Failed", e.getClass().getSimpleName() + ": " + e.getMessage(), null);
    }
    return true;
  }

  private static long asLong(Object o) {
    if (o == null) throw new IllegalArgumentException("missing integer");
    return ((Number) o).longValue();
  }

  private Store store(MethodCall call) {
    Store s = stores.get((String) call.argument("keyStoreId"));
    if (s == null) throw new IllegalArgumentException("key store not found");
    return s;
  }

  private void dispatch(MethodCall call, Result result) {
    switch (call.method) {
      case "sframeAvailable": {
        result.success(true); // this AAR carries org.webrtc.SFrame* (the Dart side gates media on it)
        break;
      }
      case "sframeKeyStoreCreate": {
        SFrameKeyStore ks = SFrameKeyStore.create();
        Object n = call.argument("stormThreshold");
        if (n != null) ks.setStormThreshold((int) asLong(n));
        Boolean h264 = call.argument("h264");
        ks.setH264Enabled(h264 != null && h264);
        String id = UUID.randomUUID().toString();
        Store s = new Store(id, ks, stateProvider.getMessenger());
        ks.setObserver(s);
        stores.put(id, s);
        Map<String, Object> r = new HashMap<>();
        r.put("keyStoreId", id);
        result.success(r);
        return;
      }
      case "sframeKeyStoreSetKey": {
        byte[] key = call.argument("key");
        SFrameKeyStore.SetKeyResult r = store(call).keyStore.setKey(asLong(call.argument("kid")), key);
        if (key != null) java.util.Arrays.fill(key, (byte) 0);
        result.success(r.name().toLowerCase());
        return;
      }
      case "sframeKeyStoreRemoveKey":
        result.success(store(call).keyStore.removeKey(asLong(call.argument("kid"))));
        return;
      case "sframeKeyStoreRetireKey":
        result.success(store(call).keyStore.retireKey(asLong(call.argument("kid")), asLong(call.argument("retentionMs"))));
        return;
      case "sframeKeyStoreSetSendKid":
        result.success(store(call).keyStore.setSendKid(asLong(call.argument("kid"))));
        return;
      case "sframeKeyStoreClearSendKid":
        store(call).keyStore.clearSendKid();
        result.success(null);
        return;
      case "sframeKeyStoreGetSendKid":
        result.success(store(call).keyStore.getSendKid());
        return;
      case "sframeKeyStoreSetStormThreshold":
        store(call).keyStore.setStormThreshold((int) asLong(call.argument("n")));
        result.success(null);
        return;
      case "sframeKeyStoreGetStats":
        result.success(store(call).keyStore.getStatsJson());
        return;
      case "sframeKeyStoreDispose": {
        Store s = store(call);
        if (s.id.equals(autoAttachStoreId)) autoAttachStoreId = null;
        stores.remove(s.id);
        // Cryptors of this store stay attached to their senders/receivers (WebRTC holds them); they keep the
        // store's native object alive and keep failing closed. Only the Java handles go.
        List<String> gone = new ArrayList<>();
        for (Attached a : cryptors.values()) if (a.storeId.equals(s.id)) gone.add(a.id);
        for (String id : gone) {
          Attached a = cryptors.remove(id);
          if (a != null) a.cryptor.dispose();
        }
        byEndpoint.values().removeAll(gone);
        s.keyStore.dispose();
        s.channel.setStreamHandler(null);
        result.success(null);
        return;
      }
      case "sframeAutoAttach": {
        String id = call.argument("keyStoreId");
        if (id != null && !stores.containsKey(id)) throw new IllegalArgumentException("key store not found");
        autoAttachStoreId = id;
        result.success(null);
        return;
      }
      case "sframeAttachToSender":
      case "sframeAttachToReceiver": {
        Store s = store(call);
        String pcId = call.argument("peerConnectionId");
        PeerConnectionObserver pco = stateProvider.getPeerConnectionObserver(pcId);
        if (pco == null) throw new IllegalArgumentException("peerConnection not found");
        String kind = call.argument("kind");
        String streamId = call.argument("streamId");
        String id;
        {
          if (call.method.equals("sframeAttachToSender")) {
            RtpSender sender = pco.getRtpSenderById(call.argument("rtpSenderId"));
            if (sender == null) throw new IllegalArgumentException("sender not found");
            String existing = byEndpoint.get(pcId + "/send/" + sender.id());
            id = existing != null ? existing
                : attach(s.id, pcId, sender, null, kind, streamId != null ? streamId : "send:" + kind + ":" + sender.id());
          } else {
            RtpReceiver receiver = pco.getRtpReceiverById(call.argument("rtpReceiverId"));
            if (receiver == null) throw new IllegalArgumentException("receiver not found");
            String existing = byEndpoint.get(pcId + "/recv/" + receiver.id());
            id = existing != null ? existing
                : attach(s.id, pcId, null, receiver, kind, streamId != null ? streamId : "recv:" + kind + ":" + receiver.id());
          }
        }
        Map<String, Object> r = new HashMap<>();
        r.put("cryptorId", id);
        result.success(r);
        return;
      }
      case "sframeAttachedFor": {
        String pcId = call.argument("peerConnectionId");
        String senderId = call.argument("rtpSenderId");
        String receiverId = call.argument("rtpReceiverId");
        String id = senderId != null ? byEndpoint.get(pcId + "/send/" + senderId)
            : byEndpoint.get(pcId + "/recv/" + receiverId);
        result.success(id);
        return;
      }
      case "sframeCryptorGetStats": {
        Attached a = cryptors.get((String) call.argument("cryptorId"));
        if (a == null) throw new IllegalArgumentException("cryptor not found");
        result.success(a.cryptor.getStatsJson());
        return;
      }
      case "sframeVectorSeal": {
        byte[] key = call.argument("key");
        byte[] unit = SFrameKeyStore.vectorSeal(key, asLong(call.argument("kid")), asLong(call.argument("ctr")),
            call.argument("frame"), (int) asLong(call.argument("prefixLen")));
        if (key != null) java.util.Arrays.fill(key, (byte) 0);
        result.success(unit);
        return;
      }
      case "sframeVectorOpen": {
        byte[] key = call.argument("key");
        byte[] frame = SFrameKeyStore.vectorOpen(key, asLong(call.argument("kid")), call.argument("unit"),
            (int) asLong(call.argument("prefixLen")));
        if (key != null) java.util.Arrays.fill(key, (byte) 0);
        result.success(frame);
        return;
      }
      default:
        result.notImplemented();
    }
  }

  /** Returns the cryptor id. Never called with a monitor held (see the maps). */
  private String attach(String storeId, String pcId, @Nullable RtpSender sender, @Nullable RtpReceiver receiver,
      String kind, String streamId) {
    Store s = stores.get(storeId);
    if (s == null) throw new IllegalStateException("key store gone");
    SFrameCryptor.MediaKind k = "audio".equals(kind) ? SFrameCryptor.MediaKind.AUDIO : SFrameCryptor.MediaKind.VIDEO;
    SFrameCryptor c;
    String key;
    String role;
    if (sender != null) {
      c = SFrameCryptor.createForRtpSender(sender, s.keyStore, k, streamId);
      key = pcId + "/send/" + sender.id();
      role = "send";
    } else {
      c = SFrameCryptor.createForRtpReceiver(receiver, s.keyStore, k, streamId);
      key = pcId + "/recv/" + receiver.id();
      role = "recv";
    }
    String id = UUID.randomUUID().toString();
    cryptors.put(id, new Attached(id, storeId, c, role, kind));
    byEndpoint.put(key, id);
    Log.d(TAG, "attached " + role + " " + kind + " " + streamId);
    return id;
  }
}
