#import "FlutterSFrame.h"

// C182 / DR-055 — see FlutterSFrame.h. No key byte is ever logged or sent back to Dart (only the vector seams return
// units); the NSData copies of base keys handed to the framework are wiped after use.

#if __has_include(<WebRTC/RTCSFrameKeyStore.h>)
#define TKM_HAS_SFRAME 1
#import <WebRTC/RTCSFrameCryptor.h>
#import <WebRTC/RTCSFrameKeyStore.h>
#else
#define TKM_HAS_SFRAME 0
#endif

#if TKM_HAS_SFRAME

#pragma mark - Store (one per key store: delegate + event channel)

@interface TkmSFrameStore : NSObject <RTCSFrameKeyStoreDelegate, FlutterStreamHandler>
@property(nonatomic, readonly) NSString* storeId;
@property(nonatomic, readonly) RTCSFrameKeyStore* keyStore;
@property(nonatomic, strong) FlutterEventChannel* channel;
@end

@implementation TkmSFrameStore {
  FlutterEventSink _sink;          // guarded by self
  NSMutableArray<NSDictionary*>* _queue;  // guarded by self; events before the Dart listener
}

- (instancetype)initWithId:(NSString*)storeId
                  keyStore:(RTCSFrameKeyStore*)keyStore
                 messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  self = [super init];
  if (self) {
    _storeId = storeId;
    _keyStore = keyStore;
    _queue = [NSMutableArray array];
    _channel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/sframeEvents/%@", storeId]
             binaryMessenger:messenger];
    [_channel setStreamHandler:self];
    keyStore.delegate = self;
  }
  return self;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  NSArray<NSDictionary*>* pending;
  @synchronized(self) {
    _sink = events;
    pending = [_queue copy];
    [_queue removeAllObjects];
  }
  for (NSDictionary* e in pending) postEvent(events, e);
  return nil;
}

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  @synchronized(self) {
    _sink = nil;
  }
  return nil;
}

// On a WebRTC media thread: only queue/post, never block.
// The tkm.5 framework's delegate selector (no `count`); kept so the binding builds and receives events against
// either framework. tkm.6+ calls the selector below.
- (void)sframeKeyStore:(RTCSFrameKeyStore*)keyStore
      didEventWithType:(NSString*)type
              streamId:(NSString*)streamId
                reason:(NSString*)reason
                   kid:(int64_t)kid
           consecutive:(int64_t)consecutive {
  [self sframeKeyStore:keyStore didEventWithType:type streamId:streamId reason:reason kid:kid
           consecutive:consecutive count:0];
}

- (void)sframeKeyStore:(RTCSFrameKeyStore*)keyStore
      didEventWithType:(NSString*)type
              streamId:(NSString*)streamId
                reason:(NSString*)reason
                   kid:(int64_t)kid
           consecutive:(int64_t)consecutive
                 count:(int64_t)count {
  NSDictionary* e = @{
    @"event" : type ?: @"",
    @"streamId" : streamId ?: @"",
    @"reason" : reason ?: @"",
    @"kid" : @(kid),
    @"consecutive" : @(consecutive),
    @"count" : @(count), // C-24 `released`
  };
  FlutterEventSink sink;
  @synchronized(self) {
    sink = _sink;
    if (sink == nil && _queue.count < 1000) [_queue addObject:e];
  }
  if (sink != nil) postEvent(sink, e);
}

@end

#pragma mark - Attached transformer

@interface TkmSFrameAttached : NSObject
@property(nonatomic, strong) NSString* cryptorId;
@property(nonatomic, strong) NSString* storeId;
@property(nonatomic, strong) RTCSFrameCryptor* cryptor;
@property(nonatomic, strong) NSString* endpoint;
@end
@implementation TkmSFrameAttached
@end

#pragma mark - Registry (process-wide; maps only, no lock held across a WebRTC call)

// Attaching calls into WebRTC proxies that block on the signaling thread, which itself runs the didAddReceiver hook:
// a lock held across those calls could deadlock, so every lock below guards map operations only (as on Android).
@interface TkmSFrameRegistry : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString*, TkmSFrameStore*>* stores;
@property(nonatomic, strong) NSMutableDictionary<NSString*, TkmSFrameAttached*>* cryptors;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* byEndpoint;  // "pc/send/<id>" → cryptor id
@property(nonatomic, copy) NSString* autoAttachStoreId;
@end
@implementation TkmSFrameRegistry
+ (instancetype)shared {
  static TkmSFrameRegistry* r;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    r = [TkmSFrameRegistry new];
    r.stores = [NSMutableDictionary dictionary];
    r.cryptors = [NSMutableDictionary dictionary];
    r.byEndpoint = [NSMutableDictionary dictionary];
  });
  return r;
}
@end

static NSString* TkmKindOfTransceiver(RTCRtpTransceiver* t) {
  return t.mediaType == RTCRtpMediaTypeAudio ? @"audio" : @"video";
}

static void TkmWipe(NSData* data) {
  if ([data isKindOfClass:[NSMutableData class]]) {
    memset([(NSMutableData*)data mutableBytes], 0, data.length);
  }
}

/// Returns the cryptor id, or nil when WebRTC refused (no native sender/receiver). Never under a lock.
static NSString* TkmAttach(NSString* storeId, NSString* pcId, RTCRtpSender* sender, RTCRtpReceiver* receiver,
                           NSString* kind, NSString* streamId) {
  TkmSFrameRegistry* reg = [TkmSFrameRegistry shared];
  TkmSFrameStore* s;
  @synchronized(reg) {
    s = reg.stores[storeId];
  }
  if (s == nil) return nil;
  RTCSFrameMediaKind k = [@"audio" isEqualToString:kind] ? RTCSFrameMediaKindAudio : RTCSFrameMediaKindVideo;
  RTCSFrameCryptor* c;
  NSString* endpoint;
  if (sender != nil) {
    c = [[RTCSFrameCryptor alloc] initWithRtpSender:sender keyStore:s.keyStore mediaKind:k streamId:streamId];
    endpoint = [NSString stringWithFormat:@"%@/send/%@", pcId, sender.senderId];
  } else {
    c = [[RTCSFrameCryptor alloc] initWithRtpReceiver:receiver keyStore:s.keyStore mediaKind:k streamId:streamId];
    endpoint = [NSString stringWithFormat:@"%@/recv/%@", pcId, receiver.receiverId];
  }
  if (c == nil) return nil;
  TkmSFrameAttached* a = [TkmSFrameAttached new];
  a.cryptorId = [[NSUUID UUID] UUIDString];
  a.storeId = storeId;
  a.cryptor = c;
  a.endpoint = endpoint;
  @synchronized(reg) {
    reg.cryptors[a.cryptorId] = a;
    reg.byEndpoint[endpoint] = a.cryptorId;
  }
  NSLog(@"FlutterSFrame: attached %@ %@ %@", sender != nil ? @"send" : @"recv", kind, streamId);
  return a.cryptorId;
}

#endif  // TKM_HAS_SFRAME

@implementation FlutterWebRTCPlugin (SFrame)

#if TKM_HAS_SFRAME

- (void)sframeOnSenderCreated:(RTCRtpSender*)sender peerConnectionId:(NSString*)peerConnectionId kind:(NSString*)kind {
  TkmSFrameRegistry* reg = [TkmSFrameRegistry shared];
  NSString* storeId;
  @synchronized(reg) {
    storeId = reg.autoAttachStoreId;
  }
  if (storeId == nil || sender == nil) return;
  NSString* k = sender.track != nil ? sender.track.kind : kind;
  NSString* endpoint = [NSString stringWithFormat:@"%@/send/%@", peerConnectionId, sender.senderId];
  @synchronized(reg) {
    if (reg.byEndpoint[endpoint] != nil) return;
  }
  TkmAttach(storeId, peerConnectionId, sender, nil, k,
            [NSString stringWithFormat:@"send:%@:%@", k, sender.senderId]);
}

- (void)sframeOnReceiverAdded:(RTCRtpReceiver*)receiver peerConnectionId:(NSString*)peerConnectionId {
  TkmSFrameRegistry* reg = [TkmSFrameRegistry shared];
  NSString* storeId;
  @synchronized(reg) {
    storeId = reg.autoAttachStoreId;
  }
  if (storeId == nil || receiver == nil || receiver.track == nil) return;
  NSString* k = receiver.track.kind;
  NSString* endpoint = [NSString stringWithFormat:@"%@/recv/%@", peerConnectionId, receiver.receiverId];
  @synchronized(reg) {
    if (reg.byEndpoint[endpoint] != nil) return;
  }
  TkmAttach(storeId, peerConnectionId, nil, receiver, k,
            [NSString stringWithFormat:@"recv:%@:%@", k, receiver.track.trackId]);
}

static int64_t TkmLong(id o) {
  if (![o isKindOfClass:[NSNumber class]]) {
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"missing integer" userInfo:nil];
  }
  return [(NSNumber*)o longLongValue];
}

static NSMutableData* TkmBytes(id o) {
  if ([o isKindOfClass:[FlutterStandardTypedData class]]) {
    return [((FlutterStandardTypedData*)o).data mutableCopy];
  }
  return nil;
}

- (BOOL)handleSFrameMethodCall:(nonnull FlutterMethodCall*)call result:(nonnull FlutterResult)result {
  NSString* method = call.method;
  if (![method hasPrefix:@"sframe"]) {
    return NO;
  }
  @try {
    [self tkmSFrameDispatch:call result:result];
  } @catch (NSException* e) {
    NSLog(@"FlutterSFrame: %@ failed: %@", method, e.name);
    result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed", method]
                               message:[NSString stringWithFormat:@"%@: %@", e.name, e.reason]
                               details:nil]);
  }
  return YES;
}

- (void)tkmSFrameDispatch:(FlutterMethodCall*)call result:(FlutterResult)result {
  TkmSFrameRegistry* reg = [TkmSFrameRegistry shared];
  NSDictionary* args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NSString* method = call.method;
  TkmSFrameStore* (^store)(void) = ^TkmSFrameStore*(void) {
    TkmSFrameStore* s;
    @synchronized(reg) {
      s = reg.stores[args[@"keyStoreId"]];
    }
    if (s == nil) {
      @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"key store not found" userInfo:nil];
    }
    return s;
  };
  id nul = [NSNull null];

  if ([method isEqualToString:@"sframeAvailable"]) {
    result(@YES);  // this framework carries RTCSFrameKeyStore / RTCSFrameCryptor
  } else if ([method isEqualToString:@"sframeKeyStoreCreate"]) {
    RTCSFrameKeyStore* ks = [[RTCSFrameKeyStore alloc] init];
    id n = args[@"stormThreshold"];
    if (n != nil && n != nul) [ks setStormThreshold:(int)TkmLong(n)];
    id h264 = args[@"h264"];
    [ks setH264Enabled:(h264 != nil && h264 != nul && [h264 boolValue])];
    NSString* sid = [[NSUUID UUID] UUIDString];
    TkmSFrameStore* s = [[TkmSFrameStore alloc] initWithId:sid keyStore:ks messenger:self.messenger];
    @synchronized(reg) {
      reg.stores[sid] = s;
    }
    result(@{@"keyStoreId" : sid});
  } else if ([method isEqualToString:@"sframeKeyStoreSetKey"]) {
    NSMutableData* key = TkmBytes(args[@"key"]);
    RTCSFrameSetKeyResult r = [store().keyStore setKey:TkmLong(args[@"kid"]) baseKey:key ?: [NSData data]];
    TkmWipe(key);
    result(r == RTCSFrameSetKeyResultChanged ? @"changed"
           : r == RTCSFrameSetKeyResultUnchanged ? @"unchanged"
                                                 : @"invalid");
  } else if ([method isEqualToString:@"sframeKeyStoreRemoveKey"]) {
    result(@([store().keyStore removeKey:TkmLong(args[@"kid"])]));
  } else if ([method isEqualToString:@"sframeKeyStoreRetireKey"]) {
    result(@([store().keyStore retireKey:TkmLong(args[@"kid"]) retentionMs:TkmLong(args[@"retentionMs"])]));
  } else if ([method isEqualToString:@"sframeKeyStoreSetSendKid"]) {
    result(@([store().keyStore setSendKid:TkmLong(args[@"kid"])]));
  } else if ([method isEqualToString:@"sframeKeyStoreClearSendKid"]) {
    [store().keyStore clearSendKid];
    result(nil);
  } else if ([method isEqualToString:@"sframeKeyStoreGetSendKid"]) {
    result(@([store().keyStore sendKid]));
  } else if ([method isEqualToString:@"sframeKeyStoreSetStormThreshold"]) {
    [store().keyStore setStormThreshold:(int)TkmLong(args[@"n"])];
    result(nil);
  } else if ([method isEqualToString:@"sframeKeyStoreSetHoldTime"]) {
    // C-24: -setHoldTimeMs: exists from WebRTC-SDK tkm.6; invoked by selector so this file still builds against
    // tkm.5 (then the call fails loudly instead of silently doing nothing).
    RTCSFrameKeyStore* ks = store().keyStore;
    SEL sel = NSSelectorFromString(@"setHoldTimeMs:");
    if (![ks respondsToSelector:sel]) {
      result([FlutterError errorWithCode:kSFrameUnavailable
                                 message:@"setHoldTime needs the WebRTC-SDK tkm.6 framework"
                                 details:nil]);
      return nil;
    }
    int64_t ms = TkmLong(args[@"holdMs"]);
    NSInvocation* inv = [NSInvocation invocationWithMethodSignature:[ks methodSignatureForSelector:sel]];
    [inv setSelector:sel];
    [inv setTarget:ks];
    [inv setArgument:&ms atIndex:2];
    [inv invoke];
    result(nil);
  } else if ([method isEqualToString:@"sframeKeyStoreGetStats"]) {
    result([store().keyStore statsJson]);
  } else if ([method isEqualToString:@"sframeKeyStoreDispose"]) {
    TkmSFrameStore* s = store();
    @synchronized(reg) {
      if ([s.storeId isEqualToString:reg.autoAttachStoreId]) reg.autoAttachStoreId = nil;
      [reg.stores removeObjectForKey:s.storeId];
      // Cryptors stay attached to their senders/receivers (WebRTC holds the transformer and, through it, the native
      // store): they keep failing closed. Only our handles go.
      NSMutableArray<NSString*>* gone = [NSMutableArray array];
      for (TkmSFrameAttached* a in reg.cryptors.allValues) {
        if ([a.storeId isEqualToString:s.storeId]) [gone addObject:a.cryptorId];
      }
      for (NSString* cid in gone) {
        TkmSFrameAttached* a = reg.cryptors[cid];
        [reg.byEndpoint removeObjectForKey:a.endpoint];
        [reg.cryptors removeObjectForKey:cid];
      }
    }
    s.keyStore.delegate = nil;
    [s.channel setStreamHandler:nil];
    result(nil);
  } else if ([method isEqualToString:@"sframeAutoAttach"]) {
    id sid = args[@"keyStoreId"];
    @synchronized(reg) {
      if (sid != nil && sid != nul && reg.stores[sid] == nil) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"key store not found" userInfo:nil];
      }
      reg.autoAttachStoreId = (sid == nul) ? nil : sid;
    }
    result(nil);
  } else if ([method isEqualToString:@"sframeAttachToSender"] ||
             [method isEqualToString:@"sframeAttachToReceiver"]) {
    TkmSFrameStore* s = store();
    NSString* pcId = args[@"peerConnectionId"];
    RTCPeerConnection* pc = self.peerConnections[pcId];
    if (pc == nil) {
      @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"peerConnection not found" userInfo:nil];
    }
    NSString* kind = args[@"kind"];
    id streamIdArg = args[@"streamId"];
    NSString* streamId = (streamIdArg == nil || streamIdArg == nul) ? nil : streamIdArg;
    NSString* cid;
    if ([method isEqualToString:@"sframeAttachToSender"]) {
      RTCRtpSender* sender = [self getRtpSenderById:pc Id:args[@"rtpSenderId"]];
      if (sender == nil) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"sender not found" userInfo:nil];
      }
      @synchronized(reg) {
        cid = reg.byEndpoint[[NSString stringWithFormat:@"%@/send/%@", pcId, sender.senderId]];
      }
      if (cid == nil) {
        cid = TkmAttach(s.storeId, pcId, sender, nil, kind,
                        streamId ?: [NSString stringWithFormat:@"send:%@:%@", kind, sender.senderId]);
      }
    } else {
      RTCRtpReceiver* receiver = [self getRtpReceiverById:pc Id:args[@"rtpReceiverId"]];
      if (receiver == nil) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"receiver not found" userInfo:nil];
      }
      @synchronized(reg) {
        cid = reg.byEndpoint[[NSString stringWithFormat:@"%@/recv/%@", pcId, receiver.receiverId]];
      }
      if (cid == nil) {
        cid = TkmAttach(s.storeId, pcId, nil, receiver, kind,
                        streamId ?: [NSString stringWithFormat:@"recv:%@:%@", kind, receiver.receiverId]);
      }
    }
    if (cid == nil) {
      @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"attach refused" userInfo:nil];
    }
    result(@{@"cryptorId" : cid});
  } else if ([method isEqualToString:@"sframeAttachedFor"]) {
    NSString* pcId = args[@"peerConnectionId"];
    id senderId = args[@"rtpSenderId"];
    NSString* endpoint = (senderId != nil && senderId != nul)
                             ? [NSString stringWithFormat:@"%@/send/%@", pcId, senderId]
                             : [NSString stringWithFormat:@"%@/recv/%@", pcId, args[@"rtpReceiverId"]];
    NSString* cid;
    @synchronized(reg) {
      cid = reg.byEndpoint[endpoint];
    }
    result(cid);
  } else if ([method isEqualToString:@"sframeCryptorGetStats"]) {
    TkmSFrameAttached* a;
    @synchronized(reg) {
      a = reg.cryptors[args[@"cryptorId"]];
    }
    if (a == nil) {
      @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"cryptor not found" userInfo:nil];
    }
    result([a.cryptor statsJson]);
  } else if ([method isEqualToString:@"sframeVectorSeal"]) {
    NSMutableData* key = TkmBytes(args[@"key"]);
    NSData* frame = TkmBytes(args[@"frame"]);
    NSData* unit = (key == nil || frame == nil)
                       ? nil
                       : [RTCSFrameKeyStore vectorSealWithBaseKey:key
                                                              kid:TkmLong(args[@"kid"])
                                                              ctr:TkmLong(args[@"ctr"])
                                                            frame:frame
                                                     prefixLength:(NSInteger)TkmLong(args[@"prefixLen"])];
    TkmWipe(key);
    result(unit == nil ? nil : [FlutterStandardTypedData typedDataWithBytes:unit]);
  } else if ([method isEqualToString:@"sframeVectorOpen"]) {
    NSMutableData* key = TkmBytes(args[@"key"]);
    NSData* unit = TkmBytes(args[@"unit"]);
    NSData* frame = (key == nil || unit == nil)
                        ? nil
                        : [RTCSFrameKeyStore vectorOpenWithBaseKey:key
                                                               kid:TkmLong(args[@"kid"])
                                                              unit:unit
                                                      prefixLength:(NSInteger)TkmLong(args[@"prefixLen"])];
    TkmWipe(key);
    result(frame == nil ? nil : [FlutterStandardTypedData typedDataWithBytes:frame]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#else  // !TKM_HAS_SFRAME — FAIL CLOSED

static NSString* const kSFrameUnavailable = @"sframe-unavailable";

- (void)sframeOnSenderCreated:(RTCRtpSender*)sender peerConnectionId:(NSString*)peerConnectionId kind:(NSString*)kind {
}

- (void)sframeOnReceiverAdded:(RTCRtpReceiver*)receiver peerConnectionId:(NSString*)peerConnectionId {
}

- (BOOL)handleSFrameMethodCall:(nonnull FlutterMethodCall*)call result:(nonnull FlutterResult)result {
  NSString* method = call.method;
  if (![method hasPrefix:@"sframe"]) {
    return NO;
  }
  if ([method isEqualToString:@"sframeAvailable"]) {
    result(@NO);
    return YES;
  }
  result([FlutterError
      errorWithCode:kSFrameUnavailable
            message:[NSString stringWithFormat:@"%@: the SFrame transformer is not in this WebRTC.framework "
                                               @"(needs the takamaka-dev/webrtc-build tkm-ios xcframework) — media "
                                               @"must not start",
                                               method]
            details:nil]);
  return YES;
}

#endif  // TKM_HAS_SFRAME

@end
