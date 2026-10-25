#import "WindowContentGeometry.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static BOOL LCWindowContentValidSize(CGSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width >= 1 && size.height >= 1;
}

CGSize LCWindowContentLogicalSize(CGSize contentSize, CGFloat scale) {
    if (!LCWindowContentValidSize(contentSize)) return CGSizeZero;
    if (!isfinite(scale) || scale <= 0) scale = 1;
    return CGSizeMake(contentSize.width / scale, contentSize.height / scale);
}

CGRect LCWindowContentSceneFrame(CGRect contentFrame, CGFloat scale, BOOL usesHostingController,
                                 UIInterfaceOrientation orientation) {
    // The modern hosting view's transform performs the division. Legacy scene
    // settings need logical points explicitly; never divide both paths.
    if (!usesHostingController) contentFrame.size = LCWindowContentLogicalSize(contentFrame.size, scale);
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        contentFrame.size = CGSizeMake(contentFrame.size.height, contentFrame.size.width);
    }
    return contentFrame;
}

void LCWindowContentApplyHostingSize(UIView *contentView, CGSize hostSize, CGFloat scale) {
    if (!LCWindowContentValidSize(hostSize)) return;
    if (!isfinite(scale) || scale <= 0) scale = 1;
    contentView.transform = CGAffineTransformMakeScale(scale, scale);
    contentView.layer.anchorPoint = CGPointZero;
    contentView.bounds = (CGRect){CGPointZero, LCWindowContentLogicalSize(hostSize, scale)};
    contentView.layer.position = CGPointZero;
}
