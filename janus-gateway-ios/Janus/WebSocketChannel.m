#import "WebSocketChannel.h"
#import <Foundation/Foundation.h>

#import "WebRTC/RTCLogging.h"
#import "SRWebSocket.h"
#import "JanusTransaction.h"
#import "JanusHandle.h"
#import "TBMacros.h"

static NSString const *kJanus = @"janus";
static NSString const *kJanusData = @"data";


@interface WebSocketChannel () <SRWebSocketDelegate>
@property(nonatomic, readonly) ARDSignalingChannelState state;
@property(nonatomic) NSNumber *sessionId;
@property(nonatomic) NSTimer *keepAliveTimer;
@property(nonatomic) NSURL *url;
@property(nonatomic) SRWebSocket *socket;
@property(nonatomic) NSMutableDictionary *transDict;
@property(nonatomic) NSMutableDictionary *handleDict;
@property(nonatomic) NSMutableDictionary *feedDict;
@end

@implementation WebSocketChannel

@synthesize state = _state;


- (instancetype)initWithURL:(NSURL *)url {
    if (self = [super init]) {
        _url = url;
        NSArray<NSString *> *protocols = [NSArray arrayWithObject:@"janus-protocol"];
        _socket = [[SRWebSocket alloc] initWithURL:url protocols:(NSArray *)protocols];
        _socket.delegate = self;
        _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(keepAlive) userInfo:nil repeats:YES];
        _transDict = [NSMutableDictionary dictionary];
        _handleDict = [NSMutableDictionary dictionary];
        _feedDict = [NSMutableDictionary dictionary];

        RTCLog(@"Opening WebSocket.");
        [_socket open];
    }
    return self;
}

- (void)stopTimer {
    [_keepAliveTimer invalidate];
    _keepAliveTimer = nil;
}

- (void)dealloc {
  [self disconnect];
}

- (void)setState:(ARDSignalingChannelState)state {
  if (_state == state) {
    return;
  }
  _state = state;
}

- (void)disconnect {
  if (_state == kARDSignalingChannelStateClosed ||
      _state == kARDSignalingChannelStateError) {
    return;
  }
  [_socket close];
    RTCLog(@"C->WSS DELETE close");
}

#pragma mark - SRWebSocketDelegate

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
  RTCLog(@"WebSocket connection opened.");
  self.state = kARDSignalingChannelStateOpen;
  [self createSession];
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
  NSLog(@"====onMessage=%@", message);
  NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
  id jsonObject = [NSJSONSerialization JSONObjectWithData:messageData options:0 error:nil];
  if (![jsonObject isKindOfClass:[NSDictionary class]]) {
    NSLog(@"Unexpected message: %@", jsonObject);
    return;
  }
  NSDictionary *wssMessage = jsonObject;
  NSString *janus = wssMessage[kJanus];
    if ([janus isEqualToString:@"success"]) {
        NSString *transaction = wssMessage[@"transaction"];

        JanusTransaction *jt = _transDict[transaction];
        if (jt.success != nil) {
            jt.success(wssMessage);
        }
        [_transDict removeObjectForKey:transaction];
    } else if ([janus isEqualToString:@"error"]) {
        NSString *transaction = wssMessage[@"transaction"];
        JanusTransaction *jt = _transDict[transaction];
        if (jt.error != nil) {
            jt.error(wssMessage);
        }
        [_transDict removeObjectForKey:transaction];
    } else if ([janus isEqualToString:@"ack"]) {
        NSLog(@"Just an ack");
    } else {
        JanusHandle *handle = _handleDict[wssMessage[@"sender"]];
        if (handle == nil) {
            NSLog(@"missing handle?");
        } else if ([janus isEqualToString:@"event"]) {
            NSDictionary *plugin = wssMessage[@"plugindata"][@"data"];
            if ([plugin[@"videoroom"] isEqualToString:@"joined"]) {
                handle.onJoined(handle);
            }

            NSArray *arrays = plugin[@"publishers"];
            if (arrays != nil && [arrays count] > 0) {
                for (NSDictionary *publisher in arrays) {
                    NSNumber *feed = publisher[@"id"];
                    NSString *display = publisher[@"display"];
                    [self subscriberCreateHandle:feed display:display];
                }
            }

            if (plugin[@"leaving"] != nil) {
                JanusHandle *jHandle = _feedDict[plugin[@"leaving"]];
                if (jHandle) {
                    jHandle.onLeaving(jHandle);
                }
            }

            if (wssMessage[@"jsep"] != nil) {
                handle.onRemoteJsep(handle, wssMessage[@"jsep"]);
            }
        } else if ([janus isEqualToString:@"detached"]) {
            handle.onLeaving(handle);
        }
    }
}


- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
  RTCLogError(@"WebSocket error: %@", error);
  self.state = kARDSignalingChannelStateError;
}

- (void)webSocket:(SRWebSocket *)webSocket
 didCloseWithCode:(NSInteger)code
           reason:(NSString *)reason
         wasClean:(BOOL)wasClean {
    RTCLog(@"WebSocket closed with code: %ld reason:%@ wasClean:%d",
           (long)code, reason, wasClean);
    NSParameterAssert(_state != kARDSignalingChannelStateError);
    self.state = kARDSignalingChannelStateClosed;
    [_keepAliveTimer invalidate];
}

#pragma mark - Private

NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

- (NSString *)randomStringWithLength: (int)len {
    NSMutableString *randomString = [NSMutableString stringWithCapacity: len];
    for (int i = 0; i< len; i++) {
        uint32_t data = arc4random_uniform((uint32_t)[letters length]);
        [randomString appendFormat: @"%C", [letters characterAtIndex: data]];
    }
    return randomString;
}

- (void)createSession {
    NSString *transaction = [self randomStringWithLength:12];

    JanusTransaction *jt = [[JanusTransaction alloc] init];
    jt.tid = transaction;
    weakify(self);
    jt.success = ^(NSDictionary *data) {
        strongify(self);
        self.sessionId = data[@"data"][@"id"];
        [self.keepAliveTimer fire];
        [self publisherCreateHandle];
    };
    jt.error = ^(NSDictionary *data) {
    };
    _transDict[transaction] = jt;

    NSDictionary *createMessage = @{
        @"janus": @"create",
        @"transaction" : transaction,
                                    };
  [_socket send:[self jsonMessage:createMessage]];
}

- (void)publisherCreateHandle {
    NSString *transaction = [self randomStringWithLength:12];
    JanusTransaction *jt = [[JanusTransaction alloc] init];
    jt.tid = transaction;
    weakify(self);
    jt.success = ^(NSDictionary *data){
        strongify(self);
        JanusHandle *handle = [[JanusHandle alloc] init];
        handle.handleId = data[@"data"][@"id"];
        handle.onJoined = ^(JanusHandle *handle) {
            strongify(self);
            [self.delegate onPublisherJoined: handle.handleId];
        };
        handle.onRemoteJsep = ^(JanusHandle *handle, NSDictionary *jsep) {
            strongify(self);
            [self.delegate onPublisherRemoteJsep:handle.handleId dict:jsep];
        };

        self.handleDict[handle.handleId] = handle;
        [self publisherJoinRoom: handle];
    };
    jt.error = ^(NSDictionary *data) {
    };
    _transDict[transaction] = jt;

    NSDictionary *attachMessage = @{
                                    @"janus": @"attach",
                                    @"plugin": @"janus.plugin.videoroom",
                                    @"transaction": transaction,
                                    @"session_id": _sessionId,
                                    };
    [_socket send:[self jsonMessage:attachMessage]];
}

- (void)createHandle: (NSString *) transValue dict:(NSDictionary *)publisher {
}

- (void)publisherJoinRoom : (JanusHandle *)handle {
    NSString *transaction = [self randomStringWithLength:12];

    NSDictionary *body = @{
                           @"request": @"join",
                           @"room": @1234,
                           @"ptype": @"publisher",
                           @"display": @"ios webrtc",
                           };
    NSDictionary *joinMessage = @{
                                  @"janus": @"message",
                                  @"transaction": transaction,
                                  @"session_id":_sessionId,
                                  @"handle_id":handle.handleId,
                                  @"body": body
                                  };
    
    [_socket send:[self jsonMessage:joinMessage]];
}

- (void)publisherCreateOffer:(NSNumber *)handleId sdp: (RTCSessionDescription *)sdp {
    NSString *transaction = [self randomStringWithLength:12];

    NSDictionary *publish = @{
                             @"request": @"configure",
                             @"audio": @YES,
                             @"video": @YES,
                             };

    NSString *type = [RTCSessionDescription stringForType:sdp.type];

    NSDictionary *jsep = @{
                           @"type": type,
                          @"sdp": [sdp sdp],
                           };
    NSDictionary *offerMessage = @{
                                   @"janus": @"message",
                                   @"body": publish,
                                   @"jsep": jsep,
                                   @"transaction": transaction,
                                   @"session_id": _sessionId,
                                   @"handle_id": handleId,
                                   };


    [_socket send:[self jsonMessage:offerMessage]];
}

- (void)trickleCandidate:(NSNumber *) handleId candidate: (RTCIceCandidate *)candidate {
    NSDictionary *candidateDict = @{
                                @"candidate": candidate.sdp,
                                @"sdpMid": candidate.sdpMid,
                                @"sdpMLineIndex": [NSNumber numberWithInt: candidate.sdpMLineIndex],
                                };

    NSDictionary *trickleMessage = @{
                                     @"janus": @"trickle",
                                     @"candidate": candidateDict,
                                     @"transaction": [self randomStringWithLength:12],
                                     @"session_id":_sessionId,
                                     @"handle_id":handleId,
                                     };

    NSLog(@"===trickle==%@", trickleMessage);
    [_socket send:[self jsonMessage:trickleMessage]];
}

- (void)trickleCandidateComplete:(NSNumber *) handleId {
    NSDictionary *candidateDict = @{
       @"completed": @YES,
       };
    NSDictionary *trickleMessage = @{
                                     @"janus": @"trickle",
                                     @"candidate": candidateDict,
                                     @"transaction": [self randomStringWithLength:12],
                                     @"session_id":_sessionId,
                                     @"handle_id":handleId,
                                     };

    [_socket send:[self jsonMessage:trickleMessage]];
}


- (void)subscriberCreateHandle: (NSNumber *)feed display:(NSString *)display {
    NSString *transaction = [self randomStringWithLength:12];
    JanusTransaction *jt = [[JanusTransaction alloc] init];
    jt.tid = transaction;
    weakify(self);
    jt.success = ^(NSDictionary *data){
        strongify(self);
        JanusHandle *handle = [[JanusHandle alloc] init];
        handle.handleId = data[@"data"][@"id"];
        handle.feedId = feed;
        handle.display = display;

        handle.onRemoteJsep = ^(JanusHandle *handle, NSDictionary *jsep) {
            strongify(self);
            [self.delegate subscriberHandleRemoteJsep:handle.handleId dict:jsep];
        };

        handle.onLeaving = ^(JanusHandle *handle) {
            strongify(self);
            [self subscriberOnLeaving:handle];
        };
        self.handleDict[handle.handleId] = handle;
        self.feedDict[handle.feedId] = handle;
        [self subscriberJoinRoom: handle];
    };
    jt.error = ^(NSDictionary *data) {
    };
    self.transDict[transaction] = jt;

    NSDictionary *attachMessage = @{
                                    @"janus": @"attach",
                                    @"plugin": @"janus.plugin.videoroom",
                                    @"transaction": transaction,
                                    @"session_id": _sessionId,
                                    };
    [_socket send:[self jsonMessage:attachMessage]];
}


- (void)subscriberJoinRoom:(JanusHandle*)handle {

    NSString *transaction = [self randomStringWithLength:12];
    _transDict[transaction] = @"subscriber";

    NSDictionary *body = @{
                           @"request": @"join",
                           @"room": @1234,
                           @"ptype": @"listener",
                           @"feed": handle.feedId,
                           };

    NSDictionary *message = @{
                                  @"janus": @"message",
                                  @"transaction": transaction,
                                  @"session_id": _sessionId,
                                  @"handle_id": handle.handleId,
                                  @"body": body,
                                  };

    [_socket send:[self jsonMessage:message]];
}

- (void)subscriberCreateAnswer:(NSNumber *)handleId sdp: (RTCSessionDescription *)sdp  {
    NSString *transaction = [self randomStringWithLength:12];

    NSDictionary *body = @{
                              @"request": @"start",
                              @"room": @1234,
                              };

    NSString *type = [RTCSessionDescription stringForType:sdp.type];

    NSDictionary *jsep = @{
                           @"type": type,
                           @"sdp": [sdp sdp],
                           };
    NSDictionary *offerMessage = @{
                                   @"janus": @"message",
                                   @"body": body,
                                   @"jsep": jsep,
                                   @"transaction": transaction,
                                   @"session_id": _sessionId,
                                   @"handle_id": handleId,
                                   };

    [_socket send:[self jsonMessage:offerMessage]];
}

- (void)subscriberOnLeaving:(JanusHandle *) handle {
    NSString *transaction = [self randomStringWithLength:12];

    JanusTransaction *jt = [[JanusTransaction alloc] init];
    jt.tid = transaction;
    weakify(self);
    jt.success = ^(NSDictionary *data) {
        strongify(self);
        [self.delegate onLeaving:handle.handleId];
        [self.handleDict removeObjectForKey:handle.handleId];
        [self.feedDict removeObjectForKey:handle.feedId];
    };
    jt.error = ^(NSDictionary *data) {
    };
    _transDict[transaction] = jt;

    NSDictionary *message = @{
                                   @"janus": @"detach",
                                   @"transaction": transaction,
                                   @"session_id": _sessionId,
                                   @"handle_id": handle.handleId,
                                   };

    [_socket send:[self jsonMessage:message]];
}

- (void)keepAlive {
    if (!_sessionId) {
        NSLog(@"Socket not connected. Check network connection");
        return;
    }
    NSDictionary *dict = @{
                           @"janus": @"keepalive",
                           @"session_id": _sessionId,
                           @"transaction": [self randomStringWithLength:12],
                           };
    [_socket send:[self jsonMessage:dict]];
}

- (NSString *)jsonMessage:(NSDictionary *)dict {
    NSData *message = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted
                                                        error:nil];
    NSString *messageString = [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    return messageString;
}


@end


