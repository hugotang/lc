#include "../MultitaskSupport/WindowKeyboardGeometry.h"
#include <assert.h>
#include <stdio.h>

static bool sameRect(LCWindowGridRect a, LCWindowGridRect b) {
    return fabs(a.x - b.x) < 1e-8 && fabs(a.y - b.y) < 1e-8 &&
           fabs(a.width - b.width) < 1e-8 && fabs(a.height - b.height) < 1e-8;
}

static void testLandscapePreferenceWithKeyboard(void) {
    LCWindowGridRect surfaces[] = {{62, 0, 750, 402}, {0, 62, 402, 812}};
    LCWindowGridRect keyboards[] = {{0, 216, 874, 186}, {0, 420, 402, 454}};
    double columns[] = {0.2, 0.5, 0.8};
    for (size_t s = 0; s < 2; ++s) {
        LCWindowGridRect normal = surfaces[s];
        LCWindowGridRect available = LCKeyboardAvailableRect(normal, keyboards[s]);
        LCWindowGridLayout layout = LCWindowGridLayoutMakeWithLandscapePreference(4, normal.width, normal.height, 2, 88, true);
        assert(layout.rows == (s == 0 ? 1 : 2));
        assert(layout.columns == (s == 0 ? 4 : 2));
        LCWindowGridLayout resized = layout;
        resized.height = available.height;
        const double *dividers = s == 0 ? columns : NULL;
        // The portrait keyboard makes the remaining surface wider than tall; it must stay 2x2.
        assert(available.width > available.height);
        for (size_t i = 0; i < 4; ++i) {
            LCWindowGridRect before = LCWindowGridFrameWithDividers(layout, i, NULL, dividers, NULL);
            LCWindowGridRect during = LCWindowGridFrameWithDividers(resized, i, NULL, dividers, NULL);
            assert(before.x == during.x && before.width == during.width);
            assert(during.height > 0 && during.height < before.height);
            if (i / layout.columns == layout.rows - 1) {
                assert(fabs(available.y + during.y + during.height - keyboards[s].y) < 1e-8);
            }
            resized.height = LCKeyboardAvailableRect(normal, (LCWindowGridRect){0}).height;
            assert(sameRect(before, LCWindowGridFrameWithDividers(resized, i, NULL, dividers, NULL)));
            resized.height = available.height;
        }
    }
}

int main(void) {
    testLandscapePreferenceWithKeyboard();
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
