// Takamaka E2EE calls (C182 / DR-055): the RFC 9605 SFrame transformer of our webrtc-sdk fork
// (org.webrtc.SFrameKeyStore / SFrameCryptor) exposed to Dart. Replaces the stock FrameCryptor path for our calls;
// method names are new ("sframe*") so an app on a binary without them fails loudly instead of running another
// cipher. No key byte is ever logged or sent back to Dart (only the vector seams return units).
//
// Auto-attach: once a key store is chosen with "sframeAutoAttach", EVERY RtpSender created by any PeerConnection of
// this plugin (addTrack / addTransceiver) gets a sealing transformer inside the same native call that created it, and
// EVERY RtpReceiver an opening transformer in onAddTrack, before the event reaches Dart. So a library that creates
// its own transceivers (livekit_client) cannot send a frame before the transformer is attached.
//
// S-8 (rulings Q5/Q6): the first selection ARMS the plugin for the life of the process. From then on "no store
// selected" (after autoAttach(false), or after the selected store was disposed) attaches a key-less SENTINEL store
// instead of nothing: its senders drop every frame (no send KID), its receivers every frame (unbound / no key). So a
// sender or receiver created between two calls, or by a late renegotiation after the call ended, is never left
// without a transformer (= media in clear). While one store is selected, selecting another is refused.
//
// Iris §7.117 (2026-10-30, rschat-docs/analysis/C182_IRIS_7117_VERIFICATION_2026-10-30.md §3 1-B / 3):
// * item 1 (blocker): libwebrtc gives a receiver created from the remote description the msid TRACK ID the offerer
//   chose (M150, sdp_offer_answer.cc:4487) and allows receiver ids to collide across m-sections
//   (rtp_transmission_manager.cc:286). Receive endpoints are therefore keyed by the transceiver MID (unique per
//   description), every onAddTrack attaches a FRESH transformer (the superseded handle goes; WebRTC keeps the last
//   SetFrameTransformer), the stream label is a plugin UUID (never the relay-chosen track id), a receiver id seen on
//   two m-lines raises the `duplicate-receiver` event and is refused by "sframeAttachedFor", and the cryptor id of
//   the attached transformer rides on the onTrack event so Dart never has to look it up by receiver id.
// * item 3: the registry (stores, cryptors, endpoints, the auto-attach selection) is PROCESS-WIDE, as on iOS: a
//   second Flutter engine (add-to-app, a background isolate that touches the plugin, a hot restart) shares it, so
//   Q6 holds per process and no observer is routed through a "last engine". A store remembers the messenger of the
//   engine that created it (its EventChannel).
// * 8p2: the receiver hook never throws out of the JNI callback (a store disposed between the pick and the attach
//   → retry with the sentinel). 8c: leg_index is range-checked before the int cast.
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
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.Result;

public class FlutterSFrame {
  private static final String TAG = "FlutterSFrame";

  private static final class Store implements SFrameKeyStore.Observer {
    final String id;
    final SFrameKeyStore keyStore;
    final EventChannel channel;
    volatile EventChannel.EventSink sink;
    final List<Map<String, Object>> queue = new ArrayList<>();

    Store(String id, SFrameKeyStore keyStore, @Nullable BinaryMessenger messenger) {
      this.id = id;
      this.keyStore = keyStore;
      if (messenger == null) { // the S-8 sentinel: no Dart listener, no events
        this.channel = null;
        return;
      }
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
    public void onSFrameEvent(String type, String streamId, String reason, long kid, long consecutive, long count) {
      Map<String, Object> e = new HashMap<>();
      e.put("event", type);
      e.put("streamId", streamId);
      e.put("reason", reason);
      e.put("kid", kid);
      e.put("consecutive", consecutive);
      e.put("count", count); // C-24 `released`: frames delivered when the key came
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

  /** What the receiver hook attached, for the onTrack event (Iris §7.117 1-B.4); both null when nothing was. */
  static final class Attachment {
    static final Attachment NONE = new Attachment(null, null);
    @Nullable final String cryptorId;
    @Nullable final String streamId;

    Attachment(@Nullable String cryptorId, @Nullable String streamId) {
      this.cryptorId = cryptorId;
      this.streamId = streamId;
    }
  }

  private final StateProvider stateProvider;
  // PROCESS-WIDE registry (Iris §7.117 item 3). Concurrent maps and NO monitor held across native calls: attaching
  // calls into WebRTC proxies that block on the signaling thread, which itself calls onReceiverAdded — a lock held
  // here across those calls could deadlock.
  private static final Map<String, Store> stores = new ConcurrentHashMap<>();
  private static final Map<String, Attached> cryptors = new ConcurrentHashMap<>();
  /** "pc/send/<senderId>" or "pc/recv/<mid>" (Iris §7.117 1-B.2; never the receiver id) → attached cryptor id. */
  private static final Map<String, String> byEndpoint = new ConcurrentHashMap<>();
  static final AutoAttach autoAttach = new AutoAttach();
  static final ReceiverRegistry receivers = new ReceiverRegistry();

  /** S-8: the key-less store auto-attached while armed and nothing is selected. Never in {@link #stores}. */
  @Nullable private static Store sentinel;
  static final String SENTINEL_ID = "tkm-sframe-sentinel";

  /**
   * S-8 (rulings Q5/Q6): the process-wide auto-attach selection + the "armed" latch. Pure state, no JNI (unit-tested
   * in FlutterSFrameAutoAttachTest).
   */
  static final class AutoAttach {
    /** Q5: set at the first selection of a store, never cleared for the life of the process. */
    private static volatile boolean armed;
    @Nullable private volatile String selected;

    /** Selects {@code id} (null = none). Q6: refuses a second store while another live one is selected. */
    synchronized void select(@Nullable String id, Map<String, ?> live) {
      if (id != null) {
        final String current = selected;
        if (current != null && !current.equals(id) && live.containsKey(current)) {
          throw new IllegalStateException("another key store is selected for auto-attach (S-8: one call plane)");
        }
        armed = true;
      }
      selected = id;
    }

    /** The store {@code id} was disposed: if it was selected, nothing is (the sentinel takes over when armed). */
    synchronized void forget(String id) {
      if (id.equals(selected)) selected = null;
    }

    @Nullable
    String selected() {
      return selected;
    }

    /** The store id a new sender/receiver gets: the selected live store, else the sentinel when armed, else none. */
    @Nullable
    String target(Map<String, ?> live) {
      final String id = selected;
      if (id != null && live.containsKey(id)) return id;
      return armed ? SENTINEL_ID : null;
    }

    static boolean armed() {
      return armed;
    }

    /** Tests only: a fresh process. */
    static void disarmForTest() {
      armed = false;
    }
  }

  /**
   * Iris §7.117 item 1: the receive endpoints of every peer connection, keyed by the transceiver MID — unique per
   * description (sdp_offer_answer.cc:551) — never by the receiver id, which libwebrtc takes from the remote msid
   * track id and lets collide across m-sections. A receiver id seen on two endpoints of one peer connection is
   * AMBIGUOUS: the lookup by id answers null (refuse) from then on. Pure state, no JNI (unit-tested in
   * FlutterSFrameReceiverRegistryTest).
   */
  static final class ReceiverRegistry {
    static final class Admission {
      /** "pc/recv/<mid>", or "pc/recv/<uuid>" when the transceiver has no mid yet. */
      final String endpoint;
      /** The endpoint this receiver id was first seen on, when {@link #duplicate}. */
      @Nullable final String firstEndpoint;
      /** This receiver id is now on more than one endpoint of this peer connection. */
      final boolean duplicate;

      Admission(String endpoint, @Nullable String firstEndpoint, boolean duplicate) {
        this.endpoint = endpoint;
        this.firstEndpoint = firstEndpoint;
        this.duplicate = duplicate;
      }
    }

    /** pc → receiver id → the endpoint it was first seen on. */
    private final Map<String, Map<String, String>> firstEndpoint = new HashMap<>();
    /** pc → receiver ids seen on more than one endpoint. */
    private final Map<String, Set<String>> ambiguous = new HashMap<>();

    /** A sighting of {@code receiverId} on the transceiver {@code mid} (null: no mid → a fresh UUID endpoint). */
    synchronized Admission admit(String pcId, String receiverId, @Nullable String mid) {
      final String endpoint = pcId + "/recv/" + (mid != null ? mid : UUID.randomUUID().toString());
      Map<String, String> byId = firstEndpoint.get(pcId);
      if (byId == null) firstEndpoint.put(pcId, byId = new HashMap<>());
      final String first = byId.get(receiverId);
      if (first == null) {
        byId.put(receiverId, endpoint);
        return new Admission(endpoint, null, false);
      }
      // the same m-line again (8p1 reuse) is fine — unless the id is already ambiguous: then EVERY sighting of it
      // is reported (fail closed), whichever m-line it comes on
      if (first.equals(endpoint) && !isAmbiguousLocked(pcId, receiverId)) return new Admission(endpoint, null, false);
      Set<String> amb = ambiguous.get(pcId);
      if (amb == null) ambiguous.put(pcId, amb = new HashSet<>());
      amb.add(receiverId);
      return new Admission(endpoint, first, true);
    }

    /** The endpoint of {@code receiverId} on {@code pcId}; null when never seen or ambiguous (refuse: 1-B.4). */
    @Nullable
    synchronized String endpointOf(String pcId, String receiverId) {
      if (isAmbiguous(pcId, receiverId)) return null;
      final Map<String, String> byId = firstEndpoint.get(pcId);
      return byId == null ? null : byId.get(receiverId);
    }

    synchronized boolean isAmbiguous(String pcId, String receiverId) {
      return isAmbiguousLocked(pcId, receiverId);
    }

    private boolean isAmbiguousLocked(String pcId, String receiverId) {
      final Set<String> amb = ambiguous.get(pcId);
      return amb != null && amb.contains(receiverId);
    }

    /** Tests only. */
    synchronized void clearForTest() {
      firstEndpoint.clear();
      ambiguous.clear();
    }
  }

  private static synchronized Store sentinel() {
    if (sentinel == null) {
      SFrameKeyStore ks = SFrameKeyStore.create(); // never a key, never a send KID: everything drops
      ks.setRequireLegBinding(true); // and its receivers are never bound: 'unbound' (S-7)
      sentinel = new Store(SENTINEL_ID, ks, null);
    }
    return sentinel;
  }

  /** The store id a new sender/receiver gets (pure: the process-wide selection over the live stores). */
  @Nullable
  static String hookTargetId() {
    return autoAttach.target(stores);
  }

  /** The store a new sender/receiver gets: the selected one, else (armed) the sentinel, else none (never armed). */
  @Nullable
  private static Store autoAttachStore() {
    final String id = hookTargetId();
    if (id == null) return null;
    if (SENTINEL_ID.equals(id)) return sentinel();
    final Store s = stores.get(id);
    return s != null ? s : sentinel(); // disposed in between: armed by construction (it was selected)
  }

  public FlutterSFrame(StateProvider stateProvider) {
    this.stateProvider = stateProvider;
  }

  // ---- hooks called by PeerConnectionObserver (static: Iris §7.117 item 3) --------------------------------------

  /** A sender was just created (addTrack / addTransceiver), before its result goes back to Dart. */
  static void onSenderCreated(String peerConnectionId, @Nullable RtpSender sender, @Nullable String transceiverKind) {
    if (sender == null) return;
    final Store store = autoAttachStore(); // S-8: the sentinel when armed and nothing is selected
    if (store == null) return; // never armed: no call has used the plugin yet (stock flutter-webrtc behaviour)
    String kind = transceiverKind;
    MediaStreamTrack t = sender.track();
    if (t != null) kind = t.kind();
    String key = peerConnectionId + "/send/" + sender.id(); // sender ids are local and unique
    if (byEndpoint.containsKey(key)) return;
    attachOrSentinel(store, key, sender, null, kind, "send:" + kind + ":" + sender.id());
  }

  /**
   * A remote track arrived (onAddTrack), before the event goes to Dart. {@code mid} is the receiver's transceiver mid
   * (null: unknown). Iris §7.117 1-B: ALWAYS attaches a fresh transformer (unbound until Dart binds it), keyed by
   * the mid; a receiver id already seen on another mid raises `duplicate-receiver` on the store's channel (the
   * receiver still gets its transformer and stays unbound). Never throws (8p2).
   */
  static Attachment onReceiverAdded(String peerConnectionId, @Nullable RtpReceiver receiver, @Nullable String mid) {
    if (receiver == null || receiver.track() == null) return Attachment.NONE;
    final Store store = autoAttachStore(); // S-8, as above
    if (store == null) return Attachment.NONE;
    String kind = receiver.track().kind();
    ReceiverRegistry.Admission adm = receivers.admit(peerConnectionId, receiver.id(), mid);
    // The label is ours: the native BindLeg binds EVERY receive stream carrying it (sframe_transformer.cc:388), so it
    // must never be the relay-chosen track id.
    String streamId = "recv:" + kind + ":" + UUID.randomUUID();
    String id = attachOrSentinel(store, adm.endpoint, null, receiver, kind, streamId);
    if (adm.duplicate) {
      Log.w(TAG, "duplicate receiver id on " + adm.firstEndpoint + " and " + adm.endpoint + " (S-7: refused by id)");
      store.onSFrameEvent("duplicate-receiver", streamId,
          "receiver " + receiver.id() + " on " + adm.firstEndpoint + " and " + adm.endpoint, -1, 0, 0);
    }
    return id == null ? Attachment.NONE : new Attachment(id, streamId);
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

  /** 8c: a leg_index for bindLeg is -1 (unbind) or 1..65535 — checked BEFORE the int cast (a raw channel call could
   * otherwise truncate 0x10007 onto leg 7). */
  static int legIndexArg(Object o) {
    long v = asLong(o);
    if (v != -1 && (v < 1 || v > 0xFFFF)) throw new IllegalArgumentException("legIndex must be -1 or 1..65535");
    return (int) v;
  }

  private static Store store(MethodCall call) {
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
        Boolean requireLeg = call.argument("requireLegBinding"); // S-7 / Q1 (AAR >= 150.7871.03-tkm.9)
        ks.setRequireLegBinding(requireLeg != null && requireLeg);
        String id = UUID.randomUUID().toString();
        Store s = new Store(id, ks, stateProvider.getMessenger()); // this engine's messenger (item 3)
        ks.setObserver(s);
        stores.put(id, s);
        Map<String, Object> r = new HashMap<>();
        r.put("keyStoreId", id);
        r.put("requireLegBinding", requireLeg != null && requireLeg); // what this binary enforces
        result.success(r);
        return;
      }
      case "sframeKeyStoreBindLeg": { // S-7 (AAR >= 150.7871.03-tkm.9)
        String streamId = call.argument("streamId");
        if (streamId == null) throw new IllegalArgumentException("missing streamId");
        result.success(store(call).keyStore.bindLeg(streamId, legIndexArg(call.argument("legIndex"))));
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
      case "sframeKeyStoreSetHoldTime": // C-24 (AAR >= 150.7871.03-tkm.6)
        store(call).keyStore.setHoldTime(asLong(call.argument("holdMs")));
        result.success(null);
        return;
      case "sframeAudioTuning": { // C-25 (AAR >= 150.7871.03-tkm.7)
        Boolean agc2 = call.argument("adaptiveDigitalAgc");
        Boolean mic = call.argument("micTowardsUser");
        org.webrtc.audio.JavaAudioDeviceModule.setPreferMicrophoneTowardsUser(mic != null && mic);
        org.webrtc.ExternalAudioProcessingFactory f = stateProvider.getAudioProcessingFactory();
        if (f == null) {
          result.error("sframe-unavailable", "no audio processing factory (initialize first)", null);
          return;
        }
        f.setAdaptiveDigitalAgc(agc2 != null && agc2);
        Boolean meter = call.argument("levelMeter"); // 2009b: the post-APM capture level, one line per 10 s
        com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter capturePost = stateProvider.getCapturePostProcessing();
        if (capturePost != null) {
          com.cloudwebrtc.webrtc.audio.CaptureLevelMeter.install(capturePost, meter != null && meter);
        }
        String cfg = f.getAudioProcessingConfig();
        Log.i(TAG, "C-25 audio tuning: agc2=" + agc2 + " micTowardsUser=" + mic + " levelMeter=" + meter + " apm=" + cfg);
        result.success(cfg);
        return;
      }
      case "sframeKeyStoreGetStats":
        result.success(store(call).keyStore.getStatsJson());
        return;
      case "sframeKeyStoreDispose": {
        Store s = store(call); // never the sentinel: it is not in `stores` (S-8)
        autoAttach.forget(s.id); // armed: the sentinel takes over
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
        // S-8: Q6 refuses a second store while one is selected (one call plane per process: a second session must
        // not take over the first one's senders); Q5 arms the sentinel for the life of the process.
        autoAttach.select(id, stores);
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
        if (call.method.equals("sframeAttachToSender")) {
          RtpSender sender = pco.getRtpSenderById(call.argument("rtpSenderId"));
          if (sender == null) throw new IllegalArgumentException("sender not found");
          String key = pcId + "/send/" + sender.id();
          String existing = byEndpoint.get(key);
          id = existing != null ? existing
              : attach(s, key, sender, null, kind, streamId != null ? streamId : "send:" + kind + ":" + sender.id());
        } else {
          String receiverId = call.argument("rtpReceiverId");
          RtpReceiver receiver = pco.getRtpReceiverById(receiverId);
          if (receiver == null) throw new IllegalArgumentException("receiver not found");
          if (receivers.isAmbiguous(pcId, receiverId)) {
            throw new IllegalStateException("receiver id is ambiguous on this peer connection (S-7 duplicate)");
          }
          String key = receivers.endpointOf(pcId, receiverId);
          String existing = key == null ? null : byEndpoint.get(key);
          if (existing != null) {
            id = existing;
          } else {
            if (key == null) key = receivers.admit(pcId, receiverId, null).endpoint; // never auto-attached (not armed)
            id = attach(s, key, null, receiver, kind, streamId != null ? streamId : "recv:" + kind + ":" + UUID.randomUUID());
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
        String id;
        if (senderId != null) {
          id = byEndpoint.get(pcId + "/send/" + senderId);
        } else {
          String key = receivers.endpointOf(pcId, receiverId); // null = never seen or ambiguous: refuse
          id = key == null ? null : byEndpoint.get(key);
        }
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

  /**
   * 8p2: {@link #attach} from a JNI callback must never throw. A store disposed between the pick and the attach
   * throws IllegalStateException (SFrameKeyStore.getNativeKeyStore → checkExists): retry with the sentinel, which
   * is armed by construction (the store had been selected). Anything else is logged; the endpoint then has no
   * transformer handle and Dart (sframeAttachedFor / the event) sees none — fail closed on its side.
   */
  @Nullable
  private static String attachOrSentinel(Store s, String endpoint, @Nullable RtpSender sender,
      @Nullable RtpReceiver receiver, String kind, String streamId) {
    try {
      return attach(s, endpoint, sender, receiver, kind, streamId);
    } catch (IllegalStateException e) {
      Log.w(TAG, "attach to a disposed store (" + e.getMessage() + "): retrying with the S-8 sentinel");
      try {
        return attach(sentinel(), endpoint, sender, receiver, kind, streamId);
      } catch (RuntimeException e2) {
        Log.e(TAG, "sentinel attach failed: " + e2.getClass().getSimpleName());
        return null;
      }
    } catch (RuntimeException e) {
      Log.e(TAG, "attach failed: " + e.getClass().getSimpleName() + ": " + e.getMessage());
      return null;
    }
  }

  /**
   * Attaches a fresh transformer at {@code endpoint} and returns its cryptor id. A handle already at that endpoint
   * is superseded (its Java handle goes; WebRTC keeps the LAST SetFrameTransformer, as S-9 relies on). Never called
   * with a monitor held (see the maps).
   */
  private static String attach(Store s, String endpoint, @Nullable RtpSender sender, @Nullable RtpReceiver receiver,
      String kind, String streamId) {
    SFrameCryptor.MediaKind k = "audio".equals(kind) ? SFrameCryptor.MediaKind.AUDIO : SFrameCryptor.MediaKind.VIDEO;
    SFrameCryptor c;
    String role;
    if (sender != null) {
      c = SFrameCryptor.createForRtpSender(sender, s.keyStore, k, streamId);
      role = "send";
    } else {
      c = SFrameCryptor.createForRtpReceiver(receiver, s.keyStore, k, streamId);
      role = "recv";
    }
    String id = UUID.randomUUID().toString();
    cryptors.put(id, new Attached(id, s.id, c, role, kind));
    String previous = byEndpoint.put(endpoint, id);
    if (previous != null) {
      Attached old = cryptors.remove(previous);
      if (old != null) old.cryptor.dispose();
      Log.d(TAG, "superseded " + role + " transformer at " + endpoint);
    }
    Log.d(TAG, "attached " + role + " " + kind + " " + streamId + (s == sentinel ? " (S-8 sentinel: drops all)" : ""));
    return id;
  }
}
