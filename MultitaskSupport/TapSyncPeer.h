#import "TapSyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// A private, anonymous channel handed only to this LiveProcess launch.
@interface LCTapSyncPeer : NSObject
@property(nonatomic, strong, readonly) NSXPCListenerEndpoint *endpoint;
@property(nonatomic) pid_t expectedProcessIdentifier;
@property(nonatomic, readonly, getter=isReady) BOOL ready;
@property(nonatomic, readonly) BOOL canReplay;
@property(nonatomic, copy, nullable) void (^stateDidChange)(void);
@property(nonatomic, copy, nullable) void (^didReceiveTap)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy, nullable) void (^didReceiveTouch)(NSDictionary *, NSString *, uint64_t);
@property(nonatomic, copy, nullable) void (^didInterrupt)(NSString *, LCTapSyncResult);
- (void)prepareSession:(NSString *)session source:(BOOL)source mode:(LCTapSyncMode)mode reply:(void (^)(LCTapSyncResult))reply;
- (void)stopSession:(NSString *)session;
- (void)replayTap:(NSDictionary *)tap session:(NSString *)session sequence:(uint64_t)sequence
            reply:(void (^)(LCTapSyncResult))reply;
- (void)replayTouch:(NSDictionary *)touch session:(NSString *)session sequence:(uint64_t)sequence
             reply:(void (^)(LCTapSyncResult))reply;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
