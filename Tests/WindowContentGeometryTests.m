#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>
#import "../MultitaskSupport/WindowContentGeometry.h"
#import "../MultitaskSupport/WindowChromeLayout.h"
#import "../MultitaskSupport/WorkspaceLaunchLayout.h"
#import "../MultitaskSupport/WindowGridLayout.h"
#import "TapSyncTestWindow.h"
#include <math.h>

// Only the remote provider is controlled. Submission, layout, coalescing and
// lifetime cancellation use the production update object and real UIKit views.
@interface LCWindowContentTestUpdater : NSObject<LCWindowHostingGeometryUpdating>
@property(nonatomic, weak) UIView *view;
@property(nonatomic) NSUInteger submissions;
@property(nonatomic) BOOL fenced;
@property(nonatomic) CGSize submittedSize;
@property(nonatomic, copy) dispatch_block_t didSubmit;
@end
@implementation LCWindowContentTestUpdater
- (void)_updateSceneSettingsFromSettingsProvidersWithFence:(BOOL)fence {
    self.submissions++;
    self.fenced = fence;
    self.submittedSize = self.view.bounds.size;
    if (self.didSubmit) self.didSubmit();
}
@end

@interface WindowContentGeometryTests : XCTestCase
@property(nonatomic, strong) UIView *host;
@end

@implementation WindowContentGeometryTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1366, 1024)];
    [LCTapSyncTestHostWindow().rootViewController.view addSubview:self.host];
}
- (void)tearDown {
    [self.host removeFromSuperview];
    self.host = nil;
    [super tearDown];
}
- (LCWindowWorkspace *)workspaceWithSingleRow:(BOOL)singleRow reservations:(NSUInteger)choices {
    NSMutableArray *entries = [NSMutableArray array];
    CGFloat scales[] = {0.5, 1, 1.5, 2};
    for (NSUInteger account = 0; account < 4; account++) {
        [entries addObject:[[LCWorkspaceWindow alloc] initWithBundleName:@"game.app"
            dataUUID:[NSString stringWithFormat:@"account-%lu", (unsigned long)account] scale:scales[account]]];
    }
    NSDictionary *proportions = @{
        @"4:2:2:1": @{@"rows": @[@0.47], @"columns": @[@0.53], @"lastRowColumns": @[@0.53]},
        @"4:2:2:0": @{@"rows": @[@0.54], @"columns": @[@0.49], @"lastRowColumns": @[@0.49]},
        @"4:1:4:0": @{@"rows": @[], @"columns": @[@0.22, @0.48, @0.75], @"lastRowColumns": @[@0.22, @0.48, @0.75]},
    };
    return [[LCWindowWorkspace alloc] initWithWindows:entries proportions:proportions
        singleRowInLandscape:singleRow reservePortraitTop:(choices & 1) != 0 reservePortraitBottom:(choices & 2) != 0
        reserveLandscapeTop:(choices & 4) != 0 reserveLandscapeBottom:(choices & 8) != 0];
}
- (CGRect)tileForWorkspace:(LCWindowWorkspace *)workspace slot:(NSUInteger)slot portrait:(BOOL)portrait {
    CGSize size = portrait ? CGSizeMake(1024, 1366) : CGSizeMake(1366, 1024);
    LCWindowGridRect content = LCWindowGridContentBoundsWithReservedAreas((LCWindowGridRect){0, 0, size.width, size.height},
        (LCWindowGridRect){0, 24, size.width, size.height - 44}, workspace.reservePortraitTop, workspace.reservePortraitBottom,
        workspace.reserveLandscapeTop, workspace.reserveLandscapeBottom);
    LCWindowGridLayout grid = LCWindowGridLayoutMakeForOrientation(4, content.width, content.height,
        LCWindowGridSpacing, LCWindowGridMinimumHeight, portrait, workspace.singleRowInLandscape);
    NSString *key = [NSString stringWithFormat:@"4:%zu:%zu:%d", grid.rows, grid.columns, portrait];
    NSDictionary *saved = workspace.proportions[key];
    double rows[3] = {0}, columns[3] = {0}, lastColumns[3] = {0};
    for (NSUInteger index = 0; index < [saved[@"rows"] count]; index++) rows[index] = [saved[@"rows"][index] doubleValue];
    for (NSUInteger index = 0; index < [saved[@"columns"] count]; index++) columns[index] = [saved[@"columns"][index] doubleValue];
    for (NSUInteger index = 0; index < [saved[@"lastRowColumns"] count]; index++) lastColumns[index] = [saved[@"lastRowColumns"][index] doubleValue];
    LCWindowGridConstrainDividers(rows, grid.rows, grid.height, grid.spacing, LCWindowGridMinimumHeight);
    LCWindowGridConstrainDividers(columns, grid.columns, grid.width, grid.spacing, LCWindowGridMinimumWidth);
    LCWindowGridConstrainDividers(lastColumns, grid.count - (grid.rows - 1) * grid.columns,
                                 grid.width, grid.spacing, LCWindowGridMinimumWidth);
    LCWindowGridRect tile = LCWindowGridFrameWithDividers(grid, slot, rows, columns, lastColumns);
    return CGRectMake(content.x + tile.x, content.y + tile.y, tile.width, tile.height);
}
- (UIStackView *)containerForTile:(CGRect)tile bottom:(BOOL)bottom hidden:(BOOL)hidden overlay:(BOOL)overlay
                           guest:(UIView * __autoreleasing *)guest hosting:(UIView * __autoreleasing *)hosting {
    UIStackView *container = [[UIStackView alloc] initWithFrame:tile];
    container.axis = UILayoutConstraintAxisVertical;
    UIView *placeholder = [UIView new];
    placeholder.userInteractionEnabled = NO;
    [container addArrangedSubview:placeholder];
    UIView *content = [UIView new];
    [container insertSubview:content atIndex:0];
    [self.host addSubview:container];
    UINavigationBar *bar = [UINavigationBar new];
    bar.items = @[[[UINavigationItem alloc] initWithTitle:@"Account"]];
    LCWindowChromeLayout *chrome = [LCWindowChromeLayout new];
    [chrome applyToContainer:container guest:content bar:bar bottom:bottom hidden:hidden overlay:overlay];
    [container layoutIfNeeded];
    // The private hosting view can begin with a physical scene frame, nonzero
    // bounds and a center anchor. These must not determine the game size.
    UIView *hosted = [[UIView alloc] initWithFrame:CGRectMake(31, 47, 1366, 1024)];
    hosted.bounds = CGRectMake(7, 9, 1366, 1024);
    [content addSubview:hosted];
    *guest = content;
    *hosting = hosted;
    return container;
}
- (void)applySceneForGuest:(UIView *)guest hosting:(UIView *)hosting scale:(CGFloat)scale
               orientation:(UIInterfaceOrientation)orientation {
    CGRect scene = LCWindowContentSceneFrame((CGRect){CGPointZero, guest.bounds.size}, scale, YES, orientation);
    CGSize hostSize = UIInterfaceOrientationIsLandscape(orientation) ? CGSizeMake(scene.size.height, scene.size.width) : scene.size;
    LCWindowContentApplyHostingSize(hosting, hostSize, scale);
}
- (void)assertHosting:(UIView *)hosting matchesGuest:(UIView *)guest scale:(CGFloat)scale {
    XCTAssertEqualWithAccuracy(hosting.bounds.size.width, guest.bounds.size.width / scale, 0.001);
    XCTAssertEqualWithAccuracy(hosting.bounds.size.height, guest.bounds.size.height / scale, 0.001);
    XCTAssertTrue(CGPointEqualToPoint(hosting.bounds.origin, CGPointZero));
    XCTAssertTrue(CGPointEqualToPoint(hosting.layer.anchorPoint, CGPointZero));
    XCTAssertTrue(CGPointEqualToPoint(hosting.layer.position, CGPointZero));
    XCTAssertEqualWithAccuracy(hosting.frame.size.width, guest.bounds.size.width, 0.001);
    XCTAssertEqualWithAccuracy(hosting.frame.size.height, guest.bounds.size.height, 0.001);
    XCTAssertEqualWithAccuracy(hosting.frame.origin.x, 0, 0.001);
    XCTAssertEqualWithAccuracy(hosting.frame.origin.y, 0, 0.001);
}
- (void)testInitialHostingGeometryMatchesLaunchMetadataBeforeAndAfterActivation {
    for (NSUInteger options = 0; options < 8; options++) {
        BOOL hidden = (options & 1) != 0, bottom = (options & 2) != 0, overlay = (options & 4) != 0;
        for (NSNumber *number in @[@0.5, @1, @2]) {
            CGFloat scale = number.doubleValue;
            UIView *guest, *hosting;
            UIStackView *container = [self containerForTile:CGRectMake(100, 80, 320, 700) bottom:bottom hidden:hidden
                                                  overlay:overlay guest:&guest hosting:&hosting];
            LCWindowContentApplyHostingSize(hosting, guest.bounds.size, scale);
            CGSize launch = LCWindowContentLogicalSize(guest.bounds.size, scale);
            XCTAssertEqualWithAccuracy(launch.height, (700 - (hidden || overlay ? 0 : 44)) / scale, 0.001);
            XCTAssertTrue(CGSizeEqualToSize(hosting.bounds.size, launch));
            [self assertHosting:hosting matchesGuest:guest scale:scale];
            for (NSNumber *orientation in @[@(UIInterfaceOrientationPortrait), @(UIInterfaceOrientationLandscapeLeft),
                                            @(UIInterfaceOrientationLandscapeRight), @(UIInterfaceOrientationPortraitUpsideDown)]) {
                CGRect initial = LCWindowContentSceneFrame((CGRect){CGPointZero, guest.bounds.size}, scale, NO,
                                                          orientation.integerValue);
                CGSize initialLogical = UIInterfaceOrientationIsLandscape(orientation.integerValue) ?
                    CGSizeMake(initial.size.height, initial.size.width) : initial.size;
                XCTAssertTrue(CGSizeEqualToSize(initialLogical, launch));
                [self applySceneForGuest:guest hosting:hosting scale:scale orientation:orientation.integerValue];
                XCTAssertTrue(CGSizeEqualToSize(hosting.bounds.size, launch));
                [self assertHosting:hosting matchesGuest:guest scale:scale];
            }
            [container removeFromSuperview];
        }
    }
}
- (void)testPortraitRestoreAndDirectLandscapeRestoreHaveIdenticalFinalContent {
    for (NSUInteger choices = 0; choices < 16; choices++) for (NSNumber *single in @[@NO, @YES]) {
        LCWindowWorkspace *workspace = [self workspaceWithSingleRow:single.boolValue reservations:choices];
        NSDictionary *original = workspace.propertyList;
        for (NSUInteger account = 0; account < 4; account++) for (NSNumber *hide in @[@NO, @YES]) {
            CGFloat scale = workspace.windows[account].scale;
            CGRect portrait = [self tileForWorkspace:workspace slot:account portrait:YES];
            CGRect landscape = [self tileForWorkspace:workspace slot:account portrait:NO];
            UIView *portraitGuest, *portraitHosting, *landscapeGuest, *landscapeHosting;
            UIStackView *first = [self containerForTile:portrait bottom:account >= 2 hidden:hide.boolValue overlay:NO
                                                  guest:&portraitGuest hosting:&portraitHosting];
            UIStackView *direct = [self containerForTile:landscape bottom:account >= 2 hidden:hide.boolValue overlay:NO
                                                   guest:&landscapeGuest hosting:&landscapeHosting];
            LCWindowContentApplyHostingSize(portraitHosting, portraitGuest.bounds.size, scale);
            LCWindowContentApplyHostingSize(landscapeHosting, landscapeGuest.bounds.size, scale);
            first.frame = landscape;
            [first layoutIfNeeded];
            [self applySceneForGuest:portraitGuest hosting:portraitHosting scale:scale orientation:UIInterfaceOrientationLandscapeLeft];
            [self applySceneForGuest:landscapeGuest hosting:landscapeHosting scale:scale orientation:UIInterfaceOrientationLandscapeLeft];
            XCTAssertTrue(CGSizeEqualToSize(portraitHosting.bounds.size, landscapeHosting.bounds.size));
            [self assertHosting:portraitHosting matchesGuest:portraitGuest scale:scale];
            [self assertHosting:landscapeHosting matchesGuest:landscapeGuest scale:scale];
            first.frame = portrait;
            direct.frame = portrait;
            [first layoutIfNeeded];
            [direct layoutIfNeeded];
            [self applySceneForGuest:portraitGuest hosting:portraitHosting scale:scale orientation:UIInterfaceOrientationPortrait];
            [self applySceneForGuest:landscapeGuest hosting:landscapeHosting scale:scale orientation:UIInterfaceOrientationPortrait];
            XCTAssertTrue(CGSizeEqualToSize(portraitHosting.bounds.size, landscapeHosting.bounds.size));
            [self assertHosting:landscapeHosting matchesGuest:landscapeGuest scale:scale];
            [first removeFromSuperview];
            [direct removeFromSuperview];
        }
        XCTAssertEqualObjects(workspace.propertyList, original);
    }
}
- (void)testFourAccountsAtDefaultScaleUseTheCurrentOrientationAfterRepeatedRotation {
    LCWindowWorkspace *workspace = [self workspaceWithSingleRow:YES reservations:5];
    for (NSUInteger account = 0; account < 4; account++) {
        UIView *guest, *hosting;
        UIStackView *container = [self containerForTile:[self tileForWorkspace:workspace slot:account portrait:NO]
            bottom:account >= 2 hidden:YES overlay:NO guest:&guest hosting:&hosting];
        LCWindowContentApplyHostingSize(hosting, guest.bounds.size, 1);
        for (NSNumber *portrait in @[@YES, @NO, @YES, @NO]) {
            container.frame = [self tileForWorkspace:workspace slot:account portrait:portrait.boolValue];
            [container layoutIfNeeded];
            [self applySceneForGuest:guest hosting:hosting scale:1 orientation:portrait.boolValue ?
                UIInterfaceOrientationPortrait : UIInterfaceOrientationLandscapeRight];
            [self assertHosting:hosting matchesGuest:guest scale:1];
            XCTAssertTrue(CGSizeEqualToSize(hosting.bounds.size, guest.bounds.size));
        }
        [container removeFromSuperview];
    }
}
- (void)testEachOrientationUsesItsOwnReservationsAndSavedDividers {
    // Portrait reserves both edges, landscape extends behind both. Different
    // proportions remain intentional instead of being replaced by a fixed ratio.
    LCWindowWorkspace *workspace = [self workspaceWithSingleRow:YES reservations:3];
    CGRect portrait = [self tileForWorkspace:workspace slot:0 portrait:YES];
    CGRect landscape = [self tileForWorkspace:workspace slot:0 portrait:NO];
    XCTAssertEqualWithAccuracy(portrait.size.width, (1024 - 2) * 0.53, 0.001);
    XCTAssertEqualWithAccuracy(portrait.size.height, (1366 - 24 - 20 - 2) * 0.47, 0.001);
    XCTAssertEqualWithAccuracy(portrait.origin.y, 24, 0.001);
    XCTAssertEqualWithAccuracy(landscape.size.width, (1366 - 6) * 0.22, 0.001);
    XCTAssertEqualWithAccuracy(landscape.size.height, 1024, 0.001);
    XCTAssertEqualWithAccuracy(landscape.origin.y, 0, 0.001);
    CGSize p = LCWindowContentLogicalSize(portrait.size, 0.5);
    CGSize l = LCWindowContentLogicalSize(landscape.size, 0.5);
    XCTAssertFalse(CGSizeEqualToSize(p, l));
    XCTAssertGreaterThan(p.width / p.height, l.width / l.height);
}
- (void)testLegacySceneAndModernHostingApplyContentScaleExactlyOnce {
    for (NSNumber *number in @[@0.5, @1, @1.5, @2]) {
        CGFloat scale = number.doubleValue;
        for (NSNumber *orientation in @[@(UIInterfaceOrientationPortrait), @(UIInterfaceOrientationLandscapeLeft),
                                        @(UIInterfaceOrientationLandscapeRight), @(UIInterfaceOrientationPortraitUpsideDown)]) {
            UIView *guest, *hosting;
            UIStackView *container = [self containerForTile:CGRectMake(37, 59, 333, 777) bottom:NO hidden:NO overlay:NO
                                                  guest:&guest hosting:&hosting];
            CGRect content = (CGRect){CGPointMake(37, 44), guest.bounds.size};
            CGRect legacy = LCWindowContentSceneFrame(content, scale, NO, orientation.integerValue);
            CGSize logical = LCWindowContentLogicalSize(guest.bounds.size, scale);
            CGSize legacySize = UIInterfaceOrientationIsLandscape(orientation.integerValue) ?
                CGSizeMake(legacy.size.height, legacy.size.width) : legacy.size;
            XCTAssertTrue(CGSizeEqualToSize(legacySize, logical));
            XCTAssertTrue(CGPointEqualToPoint(legacy.origin, content.origin));
            [self applySceneForGuest:guest hosting:hosting scale:scale orientation:orientation.integerValue];
            XCTAssertTrue(CGSizeEqualToSize(hosting.bounds.size, legacySize));
            [self assertHosting:hosting matchesGuest:guest scale:scale];
            [container removeFromSuperview];
        }
    }
}
- (void)testScaledCloseButtonAndCoordinateConversionFollowRotatedContent {
    for (NSNumber *number in @[@0.5, @1, @2]) {
        CGFloat scale = number.doubleValue;
        UIView *guest, *hosting;
        UIStackView *container = [self containerForTile:CGRectMake(30, 40, 500, 600) bottom:NO hidden:YES overlay:NO
                                              guest:&guest hosting:&hosting];
        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        [hosting addSubview:close];
        for (NSValue *tile in @[[NSValue valueWithCGRect:CGRectMake(30, 40, 500, 600)],
                               [NSValue valueWithCGRect:CGRectMake(70, 60, 270, 950)],
                               [NSValue valueWithCGRect:CGRectMake(30, 40, 500, 600)]]) {
            container.frame = tile.CGRectValue;
            [container layoutIfNeeded];
            LCWindowContentApplyHostingSize(hosting, guest.bounds.size, scale);
            close.frame = CGRectMake(hosting.bounds.size.width - 44, 0, 44, 44);
            CGPoint hit = [close convertPoint:CGPointMake(22, 22) toView:guest];
            XCTAssertTrue(CGRectContainsPoint(guest.bounds, hit));
            XCTAssertEqual([guest hitTest:hit withEvent:nil], close);
            CGPoint roundTrip = [guest convertPoint:hit toView:close];
            XCTAssertEqualWithAccuracy(roundTrip.x, 22, 0.001);
            XCTAssertEqualWithAccuracy(roundTrip.y, 22, 0.001);
            [self assertHosting:hosting matchesGuest:guest scale:scale];
        }
        [container removeFromSuperview];
    }
}
- (void)testChangingSavedScaleDoesNotRetainPreviousLogicalBounds {
    UIView *guest, *hosting;
    UIStackView *container = [self containerForTile:CGRectMake(30, 40, 333, 777) bottom:YES hidden:NO overlay:NO
                                          guest:&guest hosting:&hosting];
    for (NSNumber *number in @[@0.5, @2, @1, @1.5, @0.5]) {
        CGFloat scale = number.doubleValue;
        LCWindowContentApplyHostingSize(hosting, guest.bounds.size, scale);
        [self assertHosting:hosting matchesGuest:guest scale:scale];
    }
    [container removeFromSuperview];
}
- (void)testInvalidPendingLayoutRetainsTheLastValidHostingSize {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 333, 777)];
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(333, 777), 0.5);
    CGRect original = hosting.bounds;
    CGSize invalid[] = {{0, 0}, {NAN, 500}, {300, INFINITY}, {-1, 500}};
    for (NSUInteger index = 0; index < sizeof(invalid) / sizeof(invalid[0]); index++) {
        LCWindowContentApplyHostingSize(hosting, invalid[index], 2);
        XCTAssertTrue(CGRectEqualToRect(hosting.bounds, original));
        XCTAssertEqualWithAccuracy(hosting.transform.a, 0.5, 0.001);
    }
    for (NSNumber *scale in @[@0, @(-1), @(NAN), @(INFINITY)]) {
        LCWindowContentApplyHostingSize(hosting, CGSizeMake(333, 777), scale.doubleValue);
        XCTAssertTrue(CGSizeEqualToSize(hosting.bounds.size, CGSizeMake(333, 777)));
        XCTAssertTrue(CGAffineTransformIsIdentity(hosting.transform));
    }
}
- (void)drainHostingUpdates {
    XCTestExpectation *settled = [self expectationWithDescription:@"queued hosting geometry completed"];
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [settled fulfill]; });
    });
    [self waitForExpectations:@[settled] timeout:5];
}
- (void)testHostingSubmissionUsesTheLatestCompletedLayout {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    [update requestUpdate];
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(250, 700), 0.5);
    [update requestUpdate];
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(333, 777), 1);
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 1U);
    XCTAssertTrue(controller.fenced);
    XCTAssertTrue(CGSizeEqualToSize(controller.submittedSize, CGSizeMake(333, 777)));
    XCTAssertEqual(update.committedUpdateCount, 1U);
}
- (void)testRepeatedProviderLayoutNotificationsDoNotCreateAnUpdateLoop {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    __weak LCWindowHostingGeometryUpdate *weakUpdate = update;
    controller.didSubmit = ^{ [weakUpdate requestUpdate]; };
    [update requestUpdate];
    [self drainHostingUpdates];
    for (NSUInteger count = 0; count < 10; count++) [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 1U);
    hosting.bounds = CGRectMake(0, 0, 500, 350);
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 2U);
    XCTAssertTrue(CGSizeEqualToSize(controller.submittedSize, CGSizeMake(500, 350)));
}
- (void)testBothRestorePathsSubmitTheSameCurrentSizeAfterRotation {
    LCWindowContentTestUpdater *controllers[2];
    LCWindowHostingGeometryUpdate *updates[2];
    UIView *views[2];
    for (NSUInteger path = 0; path < 2; path++) {
        views[path] = [[UIView alloc] initWithFrame:(CGRect){CGPointZero,
            path == 0 ? CGSizeMake(510, 650) : CGSizeMake(338, 980)}];
        [self.host addSubview:views[path]];
        controllers[path] = [LCWindowContentTestUpdater new];
        controllers[path].view = views[path];
        updates[path] = [[LCWindowHostingGeometryUpdate alloc] initWithView:views[path]
            controller:controllers[path] canUpdate:nil];
        [updates[path] requestUpdate];
    }
    [self drainHostingUpdates];
    XCTAssertFalse(CGSizeEqualToSize(controllers[0].submittedSize, controllers[1].submittedSize));
    for (NSNumber *portrait in @[@NO, @YES, @NO, @YES]) {
        CGSize size = portrait.boolValue ? CGSizeMake(510, 650) : CGSizeMake(338, 980);
        for (NSUInteger path = 0; path < 2; path++) {
            LCWindowContentApplyHostingSize(views[path], size, 1);
            [updates[path] requestUpdate];
        }
        [self drainHostingUpdates];
        XCTAssertTrue(CGSizeEqualToSize(controllers[0].submittedSize, size));
        XCTAssertTrue(CGSizeEqualToSize(controllers[1].submittedSize, size));
    }
    XCTAssertEqual(controllers[0].submissions, 5U);
    XCTAssertEqual(controllers[1].submissions, 4U);
}
- (void)testLayoutChangedDuringSubmissionIsNotDropped {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    __weak LCWindowHostingGeometryUpdate *weakUpdate = update;
    __weak LCWindowContentTestUpdater *weakController = controller;
    controller.didSubmit = ^{
        if (weakController.submissions == 1) {
            LCWindowContentApplyHostingSize(hosting, CGSizeMake(500, 350), 1);
            [weakUpdate requestUpdate];
        }
    };
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 2U);
    XCTAssertTrue(CGSizeEqualToSize(controller.submittedSize, CGSizeMake(500, 350)));
    controller.didSubmit = nil;
}
- (void)testPiPSuspensionCancelsPendingGeometryAndReturnSubmitsAgain {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    __block BOOL inPiP = NO;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:^BOOL { return !inPiP; }];
    [update requestUpdate];
    inPiP = YES;
    [update cancelPendingUpdate];
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 0U);
    inPiP = NO;
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 1U);
    [update requestUpdate];
    [update cancelPendingUpdate];
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(500, 350), 1);
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 2U);
    XCTAssertTrue(CGSizeEqualToSize(controller.submittedSize, CGSizeMake(500, 350)));
}
- (void)testClosedSceneCannotSubmitAnOldOrNewQueuedUpdate {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    [update requestUpdate];
    [update invalidate];
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 0U);
    update = [[LCWindowHostingGeometryUpdate alloc] initWithView:hosting controller:controller canUpdate:nil];
    [update requestUpdate];
    update = nil;
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 0U);
}
- (void)testDetachedInvalidOrUnsupportedHostingDoesNotSubmit {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 0U);
    [self.host addSubview:hosting];
    hosting.bounds = CGRectZero;
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 0U);
    hosting.bounds = CGRectMake(0, 0, 300, 500);
    NSObject *unsupported = [NSObject new];
    LCWindowHostingGeometryUpdate *unsupportedUpdate = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:(id<LCWindowHostingGeometryUpdating>)unsupported canUpdate:nil];
    [unsupportedUpdate requestUpdate];
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 1U);
    XCTAssertEqual(unsupportedUpdate.committedUpdateCount, 0U);
}
- (void)testAncestorMovementAndSavedScaleSubmitWithoutChangingTheGridSize {
    UIView *hosting = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 500)];
    [self.host addSubview:hosting];
    LCWindowContentTestUpdater *controller = [LCWindowContentTestUpdater new];
    controller.view = hosting;
    LCWindowHostingGeometryUpdate *update = [[LCWindowHostingGeometryUpdate alloc]
        initWithView:hosting controller:controller canUpdate:nil];
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(300, 500), 1);
    [update requestUpdate];
    [self drainHostingUpdates];
    self.host.frame = CGRectOffset(self.host.frame, 25, 15);
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 2U);
    LCWindowContentApplyHostingSize(hosting, CGSizeMake(300, 500), 0.5);
    [update requestUpdate];
    [self drainHostingUpdates];
    XCTAssertEqual(controller.submissions, 3U);
    XCTAssertTrue(CGSizeEqualToSize(controller.submittedSize, CGSizeMake(600, 1000)));
    XCTAssertTrue(CGSizeEqualToSize(hosting.frame.size, CGSizeMake(300, 500)));
}
@end
