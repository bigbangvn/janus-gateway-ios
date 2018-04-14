
#import "ViewController.h"
#import "WebSocketChannel.h"
#import "WebRTC/WebRTC.h"
#import "RTCSessionDescription+JSON.h"
#import "JanusConnection.h"
#import "TBMacros.h"

#define kJanusServer    @"ws://graphtable.com:18188"
#define kTURNServerUDP  @"turn:graphtable.com:13478?transport=udp"
#define kTURNServerTCP  @"turn:graphtable.com:13478?transport=tcp"
#define kTURNUsername   @"test"
#define kTURNPassword   @"test"
#define kSTUNServer     @"stun:stun.l.google.com:19302"

//What does it mean !?? Maybe just unique name
static NSString * const kARDMediaStreamId = @"ARDAMS";
static NSString * const kARDAudioTrackId = @"ARDAMSa0";
static NSString * const kARDVideoTrackId = @"ARDAMSv0";

@interface ViewController ()
{
    
}
@property(nonatomic, strong) NSMutableDictionary *peerConnectionDict; //Careful, race condition can happen
@property(nonatomic, strong) RTCPeerConnection *publisherPeerConnection;
@property(nonatomic, strong) RTCVideoTrack *localTrack;
@property(nonatomic, strong) RTCAudioTrack *localAudioTrack;
@property(nonatomic, strong) WebSocketChannel *websocket;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) RTCCameraPreviewView *localView;
@property(nonatomic, weak) UIView *remoteView; //Store weak reference just to layout
@end

@implementation ViewController

- (void)dealloc {
    [self stopAll];
    [self.websocket stopTimer];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _localView = [[RTCCameraPreviewView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_localView];

    NSURL *url = [[NSURL alloc] initWithString:kJanusServer];
    self.websocket = [[WebSocketChannel alloc] initWithURL: url];
    self.websocket.delegate = self;

    _peerConnectionDict = [NSMutableDictionary dictionary];
    _factory = [[RTCPeerConnectionFactory alloc] init];
    _localTrack = [self createLocalVideoTrack];
    _localAudioTrack = [self createLocalAudioTrack];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    CGRect frame = UIScreen.mainScreen.bounds;
    frame.size.height /= 2;
    self.localView.frame = frame;
    
    frame.origin.y += frame.size.height;
    self.remoteView.frame = frame;
}

- (RTCEAGLVideoView *)createRemoteView {
    RTCEAGLVideoView *remoteView = [[RTCEAGLVideoView alloc] initWithFrame:CGRectZero];
    remoteView.delegate = self;
    [self.view addSubview:remoteView];
    [self.view setNeedsLayout];
    return remoteView;
}

- (void)createPublisherPeerConnection {
    _publisherPeerConnection = [self createPeerConnection];
    [self createAudioSender:_publisherPeerConnection];
    [self createVideoSender:_publisherPeerConnection];
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
    NSDictionary *optionalConstraints = @{ @"DtlsSrtpKeyAgreement" : @"true" };
    RTCMediaConstraints* constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil  optionalConstraints:optionalConstraints];
    return constraints;
}

- (RTCIceServer *)myTurnServer {
    NSArray *array = @[kTURNServerUDP,
                       kTURNServerTCP];
    return [[RTCIceServer alloc] initWithURLStrings:array
                                           username:kTURNUsername
                                         credential:kTURNPassword];
}

- (RTCIceServer *)defaultSTUNServer {
    return [[RTCIceServer alloc] initWithURLStrings:@[kSTUNServer]];
}

- (RTCPeerConnection *)createPeerConnection {
    RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    NSArray *iceServers = @[[self defaultSTUNServer], [self myTurnServer]];
    config.iceServers = iceServers;
    config.iceTransportPolicy = RTCIceTransportPolicyRelay;
    RTCPeerConnection *peerConnection = [_factory peerConnectionWithConfiguration:config
                                         constraints:constraints
                                            delegate:self];
    return peerConnection;
}

- (void)offerPeerConnection: (NSNumber*) handleId {
    [self createPublisherPeerConnection];
    JanusConnection *jc = [[JanusConnection alloc] init];
    jc.connection = _publisherPeerConnection;
    jc.handleId = handleId;
    _peerConnectionDict[handleId] = jc;

    weakify(self);
    [_publisherPeerConnection offerForConstraints:[self defaultOfferConstraints]
                       completionHandler:^(RTCSessionDescription *sdp,
                                           NSError *error) {
                           strongify(self);
                           [self.publisherPeerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                               strongify(self);
                               [self.websocket publisherCreateOffer: handleId sdp:sdp];
                           }];
                       }];
}

- (RTCMediaConstraints *)defaultMediaAudioConstraints {
    NSDictionary *mandatoryConstraints = @{ kRTCMediaConstraintsLevelControl : kRTCMediaConstraintsValueFalse };
    RTCMediaConstraints *constraints =
    [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints
                                          optionalConstraints:nil];
    return constraints;
}


- (RTCMediaConstraints *)defaultOfferConstraints {
    NSDictionary *mandatoryConstraints = @{
                                           @"OfferToReceiveAudio" : @"false",
                                           @"OfferToReceiveVideo" : @"false"
                                           };
    RTCMediaConstraints* constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints optionalConstraints:nil];
    return constraints;
}

- (RTCAudioTrack *)createLocalAudioTrack {

    RTCMediaConstraints *constraints = [self defaultMediaAudioConstraints];
    RTCAudioSource *source = [_factory audioSourceWithConstraints:constraints];
    RTCAudioTrack *track = [_factory audioTrackWithSource:source trackId:kARDAudioTrackId];

    return track;
}

- (RTCRtpSender *)createAudioSender:(RTCPeerConnection *)peerConnection {
    RTCRtpSender *sender = [peerConnection senderWithKind:kRTCMediaStreamTrackKindAudio streamId:kARDMediaStreamId];
    if (self.localAudioTrack) {
        sender.track = self.localAudioTrack;
    }
    return sender;
}

- (RTCVideoTrack *)createLocalVideoTrack {
    RTCMediaConstraints *cameraConstraints = [[RTCMediaConstraints alloc]
                                              initWithMandatoryConstraints:[self currentMediaConstraint]
                                              optionalConstraints: nil];

    RTCAVFoundationVideoSource *source = [_factory avFoundationVideoSourceWithConstraints:cameraConstraints];
    RTCVideoTrack *localVideoTrack = [_factory videoTrackWithSource:source trackId:kARDVideoTrackId];
    _localView.captureSession = source.captureSession;

    return localVideoTrack;
}

- (RTCRtpSender *)createVideoSender:(RTCPeerConnection *)peerConnection {
    RTCRtpSender *sender = [peerConnection senderWithKind:kRTCMediaStreamTrackKindVideo
                                                 streamId:kARDMediaStreamId];
    if (self.localTrack) {
        sender.track = self.localTrack;
    }

    return sender;
}

- (NSDictionary *)currentMediaConstraint {
    NSString *widthConstraint = @"480";
    NSString *heightConstraint = @"360";
    NSString *frameRateConstrait = @"10";
    return @{
           kRTCMediaConstraintsMinWidth : @"100",
           kRTCMediaConstraintsMaxWidth : widthConstraint,
           kRTCMediaConstraintsMinHeight : @"100",
           kRTCMediaConstraintsMaxHeight : heightConstraint,
           kRTCMediaConstraintsMaxFrameRate: frameRateConstrait,
           };
}

- (void)videoView:(RTCEAGLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    CGRect rect = videoView.frame;
    rect.size = size;
    NSLog(@"========didChangeVideiSize %fx%f", size.width, size.height);
    videoView.frame = rect;
}


- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    NSLog(@"=========didAddStream");
    JanusConnection *janusConnection;

    for (JanusConnection *jc in self.peerConnectionDict.allValues) {
        if (peerConnection == jc.connection) {
            janusConnection = jc;
            break;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream.videoTracks.count) {
            RTCVideoTrack *remoteVideoTrack = stream.videoTracks[0];

            RTCEAGLVideoView *remoteView = [self createRemoteView];
            [remoteVideoTrack addRenderer:remoteView];
            janusConnection.videoTrack = remoteVideoTrack;
            janusConnection.videoView = remoteView;
            self.remoteView = remoteView;
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    NSLog(@"=========didRemoveStream");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {

}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {

}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    NSLog(@"=========didGenerateIceCandidate==%@", candidate.sdp);

    NSNumber *handleId;
    for (JanusConnection *jc in self.peerConnectionDict.allValues) {
        if (peerConnection == jc.connection) {
            handleId = jc.handleId;
            break;
        }
    }
    if (candidate != nil) {
        [self.websocket trickleCandidate:handleId candidate:candidate];
    } else {
        [self.websocket trickleCandidateComplete: handleId];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {

}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    NSLog(@"=========didRemoveIceCandidates");
}


// mark: delegate

- (void)onPublisherJoined: (NSNumber*) handleId {
    [self offerPeerConnection:handleId];
}

- (void)onPublisherRemoteJsep:(NSNumber *)handleId dict:(NSDictionary *)jsep {
    JanusConnection *jc = self.peerConnectionDict[handleId];
    RTCSessionDescription *answerDescription = [RTCSessionDescription descriptionFromJSONDictionary:jsep];
    [jc.connection setRemoteDescription:answerDescription completionHandler:^(NSError * _Nullable error) {
        //Do nothing here. After RTCpeerConnection get enough information: Ice candidate and offer/answer it will start establish the peer connection (send test packet..)
    }];
}

- (void)subscriberHandleRemoteJsep: (NSNumber *)handleId dict:(NSDictionary *)jsep {
    RTCPeerConnection *peerConnection = [self createPeerConnection];

    JanusConnection *jc = [[JanusConnection alloc] init];
    jc.connection = peerConnection;
    jc.handleId = handleId;
    self.peerConnectionDict[handleId] = jc;

    RTCSessionDescription *answerDescription = [RTCSessionDescription descriptionFromJSONDictionary:jsep];
    [peerConnection setRemoteDescription:answerDescription completionHandler:^(NSError * _Nullable error) {
    }];
    NSDictionary *mandatoryConstraints = @{
                                           @"OfferToReceiveAudio" : @"true",
                                           @"OfferToReceiveVideo" : @"true",
                                           };
    RTCMediaConstraints* constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints optionalConstraints:nil];

    weakify(self);
    [peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        strongify(self);
        [peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
        }];
        [self.websocket subscriberCreateAnswer:handleId sdp:sdp];
    }];

}

- (void)onLeaving:(NSNumber *)handleId {
    JanusConnection *jc = self.peerConnectionDict[handleId];
    [jc.connection close];
    jc.connection = nil;
    RTCVideoTrack *videoTrack = jc.videoTrack;
    [videoTrack removeRenderer: jc.videoView];
    videoTrack = nil;
    [jc.videoView renderFrame:nil];
    [jc.videoView removeFromSuperview];

    [self.peerConnectionDict removeObjectForKey:handleId];
}

- (void)destroyRemoteConnections {
    for (NSNumber *handleId in self.peerConnectionDict.allKeys) {
        JanusConnection *jc = self.peerConnectionDict[handleId];
        if (jc.connection != self.publisherPeerConnection) {
            [jc.connection close];
            [jc.videoTrack removeRenderer: jc.videoView];
            [jc.videoView renderFrame:nil];
            [jc.videoView removeFromSuperview];
            [self.peerConnectionDict removeObjectForKey:handleId];
        }
    }
}

- (void)stopAll {
    [self destroyRemoteConnections];
    
    //Note: Don't know why there's weird crash without set nil WebRTC objects reference
    //It maybe some magic c++ stuff that I don't understand.
    //It also crash in this: https://github.com/bigbangvn/AppRTCMobile-iOS, If eg. comment out line 308 (_localVideoTrack = nil;) in
    //ARDAppClient.m
    //Someone also get this similar crash: https://github.com/bigbangvn/Licode-ErizoClientIOS
    
    [_localView.captureSession stopRunning];
    _localView.captureSession = nil;
    _localView = nil;
    
    [self.publisherPeerConnection close];
    self.publisherPeerConnection = nil; //Crash without this!??
    [self.peerConnectionDict removeAllObjects]; //Also to clear reference to peerConnection
    
    self.localTrack = nil;      //Crash without this!??
    self.localAudioTrack = nil; //Crash without this!??
}

@end
