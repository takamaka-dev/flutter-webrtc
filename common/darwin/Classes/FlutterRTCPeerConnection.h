#import "FlutterWebRTCPlugin.h"

@interface RTCPeerConnection (Flutter) <FlutterStreamHandler>
@property(nonatomic, strong, nonnull) NSMutableDictionary<NSString*, RTCDataChannel*>* dataChannels;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStream*>* remoteStreams;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStreamTrack*>* remoteTracks;
@property(nonatomic, strong, nonnull) NSString* flutterId;
@property(nonatomic, strong, nullable) FlutterEventSink eventSink;
@property(nonatomic, strong, nullable) FlutterEventChannel* eventChannel;
// Set when the plugin has closed this connection. A closed connection stays
// registered until it is disposed so that its event channel handler can be
// released at that point.
@property(nonatomic, assign) BOOL closedByPlugin;
// C182 (Iris §7.117 1-B, twin of Android's F-M2-2 lastOnTrackTransceiver): libwebrtc calls
// didStartReceivingOnTransceiver: right before didAddReceiver:streams: on the signaling thread. Keeping it gives
// didAddReceiver the receiver's OWN transceiver (its mid keys the SFrame endpoint) even when two transceivers carry
// the same relay-chosen receiver id — a scan of `transceivers` by id would always find the first.
@property(nonatomic, strong, nullable) RTCRtpTransceiver* lastOnTrackTransceiver;
@end

@interface FlutterWebRTCPlugin (RTCPeerConnection)

- (void)peerConnectionCreateOffer:(nonnull NSDictionary*)constraints
                   peerConnection:(nonnull RTCPeerConnection*)peerConnection
                           result:(nonnull FlutterResult)result;

- (void)peerConnectionCreateAnswer:(nonnull NSDictionary*)constraints
                    peerConnection:(nonnull RTCPeerConnection*)peerConnection
                            result:(nonnull FlutterResult)result;

- (void)peerConnectionSetLocalDescription:(nonnull RTCSessionDescription*)sdp
                           peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                   result:(nonnull FlutterResult)result;

- (void)peerConnectionSetRemoteDescription:(nonnull RTCSessionDescription*)sdp
                            peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                    result:(nonnull FlutterResult)result;

- (void)peerConnectionAddICECandidate:(nonnull RTCIceCandidate*)candidate
                       peerConnection:(nonnull RTCPeerConnection*)peerConnection
                               result:(nonnull FlutterResult)result;

- (void)peerConnectionGetStats:(nonnull RTCPeerConnection*)peerConnection
                        result:(nonnull FlutterResult)result;

- (void)peerConnectionGetStatsForTrackId:(nonnull NSString*)trackID
                          peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                  result:(nonnull FlutterResult)result;

- (nonnull RTCMediaConstraints*)parseMediaConstraints:(nonnull NSDictionary*)constraints;

- (void)peerConnectionSetConfiguration:(nonnull RTCConfiguration*)configuration
                        peerConnection:(nonnull RTCPeerConnection*)peerConnection;

- (void)peerConnectionGetRtpReceiverCapabilities:(nonnull NSDictionary*)argsMap
                                          result:(nonnull FlutterResult)result;

- (void)peerConnectionGetRtpSenderCapabilities:(nonnull NSDictionary*)argsMap
                                        result:(nonnull FlutterResult)result;

- (void)transceiverSetCodecPreferences:(nonnull NSDictionary*)argsMap
                                result:(nonnull FlutterResult)result;

- (nullable NSString*)stringForSignalingState:(RTCSignalingState)state;

- (nullable NSString*)stringForICEGatheringState:(RTCIceGatheringState)state;

- (nullable NSString*)stringForICEConnectionState:(RTCIceConnectionState)state;

- (nullable NSString*)stringForPeerConnectionState:(RTCPeerConnectionState)state;

@end
