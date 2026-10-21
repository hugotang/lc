#include "../MultitaskSupport/WindowKeyboardGeometry.h"
#include <assert.h>
#include <stdio.h>

static bool sameRect(LCWindowGridRect a, LCWindowGridRect b) {
    return fabs(a.x - b.x) < 1e-8 && fabs(a.y - b.y) < 1e-8 &&
           fabs(a.width - b.width) < 1e-8 && fabs(a.height - b.height) < 1e-8;
}

int main(void) {
    LCWindowGridRect desktop = {0, 24, 1024, 720};
    LCWindowGridRect keyboard = {0, 500, 1024, 268};
    LCWindowGridRect available = LCKeyboardAvailableRect(desktop, keyboard);
    assert(sameRect(available, (LCWindowGridRect){0, 24, 1024, 476}));
    LCWindowGridRect ignored[] = {
        {400, 400, 320, 264}, // Floating keyboard.
        {0, 744, 1024, 264}, // Offscreen keyboard.
        {0, 700, 1024, 44},  // Hardware keyboard toolbar.
        {0, 400, 1024, 200}, // Undocked keyboard.
        {1024, 500, 1024, 268}, // Another screen/window.
        {0, 0, 0, 0}, {NAN, 500, 1024, 268}, {0, 500, INFINITY, 268}
    };
    for (size_t i = 0; i < sizeof(ignored) / sizeof(ignored[0]); ++i) {
        assert(sameRect(desktop, LCKeyboardAvailableRect(desktop, ignored[i])));
    }
    // Keyboard overlaps the safe-area bottom, not necessarily the physical display bottom.
    assert(sameRect(LCKeyboardAvailableRect((LCWindowGridRect){30, 30, 800, 600}, keyboard),
                    (LCWindowGridRect){30, 30, 800, 470}));
    LCWindowGridRect untouched = {200, 50, 320, 200};
    assert(sameRect(untouched, LCKeyboardFitWindow(untouched, available)));
    LCWindowGridRect tall = {100, 200, 500, 540};
    assert(sameRect(LCKeyboardFitWindow(tall, available), (LCWindowGridRect){100, 24, 500, 476}));
    assert(sameRect(tall, LCKeyboardRestoreWindow(tall, desktop, desktop)));

    LCWindowGridRect screen = {0, 0, 874, 402};
    LCWindowGridRect safe = {62, 0, 750, 382};
    LCWindowGridRect grid = LCWindowGridContentBounds(screen, safe);
    LCWindowGridRect landscapeKeyboard = {0, 216, 874, 186};
    assert(sameRect(grid, (LCWindowGridRect){62, 0, 750, 402}));
    // Both layouts stop at the keyboard, but dismissing it restores their own bottom boundaries.
    assert(sameRect(LCKeyboardAvailableRect(grid, landscapeKeyboard), (LCWindowGridRect){62, 0, 750, 216}));
    assert(sameRect(LCKeyboardAvailableRect(safe, landscapeKeyboard), (LCWindowGridRect){62, 0, 750, 216}));
    assert(sameRect(LCKeyboardAvailableRect(grid, (LCWindowGridRect){0}), grid));
    assert(sameRect(LCKeyboardAvailableRect(safe, (LCWindowGridRect){0}), safe));
    LCWindowGridLayout pair = LCWindowGridLayoutMake(2, grid.width, grid.height, 2, 88);
    pair.height = LCKeyboardAvailableRect(grid, landscapeKeyboard).height;
    LCWindowGridRect tile = LCWindowGridFrame(pair, 1);
    assert(fabs(tile.y + tile.height - landscapeKeyboard.y) < 1e-8);

    size_t cases = 0;
    for (int width = 320; width <= 1600; width += 160) {
        for (int height = 400; height <= 1600; height += 120) {
            LCWindowGridRect bounds = {12, 24, width, height};
            for (int keyboardHeight = 100; keyboardHeight < height; keyboardHeight += 75) {
                LCWindowGridRect key = {0, 24 + height - keyboardHeight, width + 24, keyboardHeight + 34};
                LCWindowGridRect area = LCKeyboardAvailableRect(bounds, key);
                assert(area.height > 0 && area.height < bounds.height);
                for (int y = 24; y < 24 + height; y += 93) {
                    LCWindowGridRect original = {20, y, 250, fmin(height / 2.0, 24 + height - y)};
                    LCWindowGridRect fitted = LCKeyboardFitWindow(original, area);
                    assert(fitted.y >= area.y && fitted.y + fitted.height <= area.y + area.height + 1e-8);
                    assert(fitted.height > 0 && fitted.height <= original.height);
                    assert(fitted.x == original.x && fitted.width == original.width);
                    // Fit is stable and does not alter the saved frame used on dismissal.
                    assert(sameRect(fitted, LCKeyboardFitWindow(fitted, area)));
                    assert(sameRect(original, LCKeyboardRestoreWindow(original, bounds, bounds)));
                    LCWindowGridRect rotated = {12, 24, height, width};
                    LCWindowGridRect restored = LCKeyboardRestoreWindow(original, bounds, rotated);
                    assert(restored.x >= rotated.x && restored.y >= rotated.y);
                    assert(restored.x + restored.width <= rotated.x + rotated.width + 1e-8);
                    assert(restored.y + restored.height <= rotated.y + rotated.height + 1e-8);
                    ++cases;
                }
            }
        }
    }
    printf("Keyboard geometry tests passed (%zu fit/restore cases, floating/offscreen/hardware keyboards and rotation).\n", cases);
    return 0;
}
