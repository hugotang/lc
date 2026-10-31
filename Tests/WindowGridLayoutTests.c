// Run with: cc -std=c11 -Wall -Wextra -Werror -pedantic Tests/WindowGridLayoutTests.c -lm -o /tmp/window-grid-tests && /tmp/window-grid-tests
#include "../MultitaskSupport/WindowGridLayout.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>

static const double epsilon = 0.000001;

static void assertClose(double actual, double expected) {
    assert(fabs(actual - expected) < epsilon);
}

static void testCommonLayouts(void) {
    LCWindowGridLayout single = LCWindowGridLayoutMake(1, 374, 734, 8, 88);
    LCWindowGridRect frame = LCWindowGridFrame(single, 0);
    assertClose(frame.x, 0);
    assertClose(frame.y, 0);
    assertClose(frame.width, 374);
    assertClose(frame.height, 734);

    LCWindowGridLayout portraitPair = LCWindowGridLayoutMake(2, 374, 734, 8, 88);
    assert(portraitPair.rows == 2 && portraitPair.columns == 1);
    LCWindowGridRect first = LCWindowGridFrame(portraitPair, 0);
    LCWindowGridRect second = LCWindowGridFrame(portraitPair, 1);
    assertClose(first.height, 363);
    assertClose(second.y - first.height, 8);
    assertClose(second.y + second.height, 734);

    LCWindowGridLayout landscapePair = LCWindowGridLayoutMake(2, 734, 374, 8, 88);
    assert(landscapePair.rows == 1 && landscapePair.columns == 2);
    first = LCWindowGridFrame(landscapePair, 0);
    second = LCWindowGridFrame(landscapePair, 1);
    assertClose(first.width, 363);
    assertClose(second.x - first.width, 8);

    for (size_t count = 3; count <= 4; ++count) {
        LCWindowGridLayout grid = LCWindowGridLayoutMake(count, 374, 734, 8, 88);
        assert(grid.rows == 2 && grid.columns == 2);
        LCWindowGridRect last = LCWindowGridFrame(grid, count - 1);
        assertClose(last.x + last.width, 374);
        assertClose(last.y + last.height, 734);
        if (count == 3) assertClose(last.width, 374);
        if (count == 4) assertClose(last.width, 183);
    }

    LCWindowGridLayout sixPortrait = LCWindowGridLayoutMake(6, 374, 734, 8, 88);
    LCWindowGridLayout sixLandscape = LCWindowGridLayoutMake(6, 734, 374, 8, 88);
    assert(sixPortrait.rows == 3 && sixPortrait.columns == 2);
    assert(sixLandscape.rows == 2 && sixLandscape.columns == 3);
}

static void assertUsableLayout(size_t count, double width, double height, double spacing, bool singleRowInLandscape) {
    LCWindowGridLayout layout = LCWindowGridLayoutMakeWithLandscapePreference(count, width, height, spacing, 88,
                                                                               singleRowInLandscape);
    assert(layout.count == count);
    if (singleRowInLandscape && width > height) assert(layout.rows == 1 && layout.columns == count);
    double totalArea = 0;
    for (size_t i = 0; i < count; ++i) {
        LCWindowGridRect a = LCWindowGridFrame(layout, i);
        assert(isfinite(a.x) && isfinite(a.y) && isfinite(a.width) && isfinite(a.height));
        assert(a.width > 0 && a.height > 0);
        assert(a.x >= 0 && a.y >= 0);
        assert(a.x + a.width <= width + epsilon);
        assert(a.y + a.height <= height + epsilon);
        if (height >= 88) assert(a.height >= 88 - epsilon);
        totalArea += a.width * a.height;
        for (size_t j = 0; j < i; ++j) {
            LCWindowGridRect b = LCWindowGridFrame(layout, j);
            assert(a.x + a.width <= b.x + epsilon || b.x + b.width <= a.x + epsilon ||
                   a.y + a.height <= b.y + epsilon || b.y + b.height <= a.y + epsilon);
        }
    }
    // Without gaps, even incomplete rows should use every part of the surface.
    if (spacing == 0) assertClose(totalArea, width * height);
}

static void testSizesAndWindowCounts(bool singleRowInLandscape) {
    const double sizes[][2] = {
        {320, 524}, {375, 647}, {390, 750}, {430, 830}, // iPhone safe-area sizes
        {750, 354}, {932, 430}, {768, 980}, {1008, 700},
        {1, 1}, {50, 45}, {143.5, 197.25}
    };
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
        for (size_t count = 1; count <= 128; ++count) {
            assertUsableLayout(count, sizes[s][0], sizes[s][1], 8, singleRowInLandscape);
            assertUsableLayout(count, sizes[s][0], sizes[s][1], LCWindowGridSpacing, singleRowInLandscape);
            assertUsableLayout(count, sizes[s][0], sizes[s][1], 0, singleRowInLandscape);
        }
    }
    assertUsableLayout(16, 320, 200, 1000, singleRowInLandscape);
}

static void testLandscapeSingleRow(void) {
    LCWindowGridRect content = LCWindowGridContentBounds((LCWindowGridRect){0, 0, 874, 402},
                                                         (LCWindowGridRect){62, 0, 750, 382});
    LCWindowGridLayout automatic = LCWindowGridLayoutMakeWithLandscapePreference(4, content.width, content.height, 2, 88, false);
    assert(automatic.rows == 2 && automatic.columns == 2);
    LCWindowGridLayout singleRow = LCWindowGridLayoutMakeWithLandscapePreference(4, content.width, content.height, 2, 88, true);
    assert(singleRow.rows == 1 && singleRow.columns == 4);
    for (size_t i = 0; i < 4; ++i) {
        LCWindowGridRect frame = LCWindowGridFrame(singleRow, i);
        assertClose(frame.x, i * 188);
        assertClose(frame.y, 0);
        assertClose(frame.width, 186);
        assertClose(frame.height, 402);
        assertClose(content.y + frame.y + frame.height, 402);
    }

    // Returning to portrait uses the same row-major order and geometry as automatic mode.
    LCWindowGridLayout portrait = LCWindowGridLayoutMakeWithLandscapePreference(4, 402, 812, 2, 88, true);
    LCWindowGridLayout original = LCWindowGridLayoutMake(4, 402, 812, 2, 88);
    assert(portrait.rows == 2 && portrait.columns == 2);
    for (size_t i = 0; i < 4; ++i) {
        LCWindowGridRect a = LCWindowGridFrame(portrait, i), b = LCWindowGridFrame(original, i);
        assertClose(a.x, b.x);
        assertClose(a.y, b.y);
        assertClose(a.width, b.width);
        assertClose(a.height, b.height);
    }
    LCWindowGridLayout square = LCWindowGridLayoutMakeWithLandscapePreference(4, 700, 700, 2, 88, true);
    assert(square.rows == 2 && square.columns == 2);
    assert(LCWindowGridLayoutMakeWithLandscapePreference(0, 874, 402, 2, 88, true).count == 0);
    assert(LCWindowGridLayoutMakeWithLandscapePreference(4, INFINITY, 402, 2, 88, true).count == 0);
    assert(LCWindowGridLayoutMakeWithLandscapePreference(4, 874, 402, NAN, 88, true).count == 0);

    // Landscape columns and portrait dividers are separate, reusable proportions.
    double columns[] = {0.2, 0.5, 0.8};
    double rows[] = {0.4}, portraitColumns[] = {0.6};
    LCWindowGridRect before = LCWindowGridFrameWithDividers(portrait, 0, rows, portraitColumns, NULL);
    assert(LCWindowGridMoveDivider(columns, 4, 1, 410, 750, 2, 96));
    LCWindowGridRect a = LCWindowGridFrameWithDividers(singleRow, 1, NULL, columns, NULL);
    LCWindowGridRect b = LCWindowGridFrameWithDividers(singleRow, 2, NULL, columns, NULL);
    assertClose(b.x - (a.x + a.width), 2);
    assertClose(a.height, 402);
    assertClose(b.height, 402);
    LCWindowGridRect after = LCWindowGridFrameWithDividers(portrait, 0, rows, portraitColumns, NULL);
    assertClose(before.width, after.width);
    assertClose(before.height, after.height);
}

static void testCompactGridUsesSafeArea(void) {
    LCWindowGridLayout pair = LCWindowGridLayoutMake(2, 390, 750, LCWindowGridSpacing, LCWindowGridMinimumHeight);
    LCWindowGridRect top = LCWindowGridFrame(pair, 0);
    LCWindowGridRect bottom = LCWindowGridFrame(pair, 1);
    assertClose(top.x, 0);
    assertClose(top.y, 0);
    assertClose(top.width, 390);
    assertClose(bottom.y + bottom.height, 750);
    assertClose(bottom.y - (top.y + top.height), 2);
    // Previously, 8pt outside margins, an 8pt gap and two 44pt bars consumed this space.
    double previousContentHeight = (750 - 16 - 8) / 2.0 - 44;
    assertClose(top.height - previousContentHeight, 55);
    LCWindowGridLayout four = LCWindowGridLayoutMake(4, 390, 750, LCWindowGridSpacing, LCWindowGridMinimumHeight);
    LCWindowGridRect first = LCWindowGridFrame(four, 0);
    LCWindowGridRect last = LCWindowGridFrame(four, 3);
    assertClose(first.width, 194);
    assertClose(first.height, 374);
    assertClose(last.x + last.width, 390);
    assertClose(last.y + last.height, 750);
}

static void testInvalidInput(void) {
    assert(LCWindowGridLayoutMake(0, 390, 844, 8, 88).count == 0);
    assert(LCWindowGridLayoutMake(4, 0, 844, 8, 88).count == 0);
    assert(LCWindowGridLayoutMake(4, 390, -1, 8, 88).count == 0);
    assert(LCWindowGridLayoutMake(4, NAN, 844, 8, 88).count == 0);
    assert(LCWindowGridLayoutMake(4, 390, INFINITY, 8, 88).count == 0);
    assert(LCWindowGridLayoutMake(4, 390, 844, NAN, 88).count == 0);
    LCWindowGridLayout empty = {0};
    assertClose(LCWindowGridFrame(empty, 0).width, 0);
    LCWindowGridLayout grid = LCWindowGridLayoutMake(4, 390, 844, 8, 88);
    assertClose(LCWindowGridFrame(grid, 4).width, 0);
}

static void testGridContentBounds(void) {
    const LCWindowGridRect bounds[] = {
        {0, 0, 874, 402}, {0, 0, 874, 402}, {0, 0, 402, 874},
        {12, 24, 1024, 768}, {0, 0, 667, 375}
    };
    const LCWindowGridRect safe[] = {
        {62, 0, 750, 382},    // Landscape: the old grid left a 20pt black strip.
        {62, 0, 812, 382},    // Asymmetric side exclusions.
        {0, 62, 402, 778},    // Portrait: preserve the top exclusion.
        {12, 48, 1024, 724},  // A host with a nonzero origin.
        {0, 0, 667, 375}      // No bottom inset.
    };
    for (size_t s = 0; s < sizeof(bounds) / sizeof(bounds[0]); ++s) {
        LCWindowGridRect content = LCWindowGridContentBounds(bounds[s], safe[s]);
        assertClose(content.x, safe[s].x);
        assertClose(content.y, safe[s].y);
        assertClose(content.width, safe[s].width);
        assertClose(content.y + content.height, bounds[s].y + bounds[s].height);
        for (size_t count = 1; count <= 12; ++count) {
            LCWindowGridLayout layout = LCWindowGridLayoutMake(count, content.width, content.height,
                                                               LCWindowGridSpacing, LCWindowGridMinimumHeight);
            for (size_t index = 0; index < count; ++index) {
                LCWindowGridRect tile = LCWindowGridFrame(layout, index);
                assert(content.x + tile.x >= safe[s].x - epsilon);
                assert(content.x + tile.x + tile.width <= safe[s].x + safe[s].width + epsilon);
                if (index / layout.columns == layout.rows - 1) {
                    assertClose(content.y + tile.y + tile.height, bounds[s].y + bounds[s].height);
                }
            }
        }
    }
    LCWindowGridRect clipped = LCWindowGridContentBounds(bounds[0], (LCWindowGridRect){-20, -20, 1000, 450});
    assertClose(clipped.x, 0);
    assertClose(clipped.y, 0);
    assertClose(clipped.width, 874);
    assertClose(clipped.height, 402);
    assertClose(LCWindowGridContentBounds(bounds[0], (LCWindowGridRect){0}).width, 0);
    assertClose(LCWindowGridContentBounds((LCWindowGridRect){NAN, 0, 874, 402}, safe[0]).height, 0);
}

static void testPortraitReservedAreas(void) {
    const LCWindowGridRect bounds = {0, 0, 402, 874};
    const LCWindowGridRect safe = {0, 62, 402, 778};
    const LCWindowGridRect expected[] = {
        {0, 0, 402, 874}, {0, 0, 402, 840},
        {0, 62, 402, 812}, {0, 62, 402, 778}
    };
    for (int top = 0; top <= 1; ++top) {
        for (int bottom = 0; bottom <= 1; ++bottom) {
            LCWindowGridRect content = LCWindowGridContentBoundsWithPortraitPreferences(bounds, safe, top, bottom);
            LCWindowGridRect target = expected[top * 2 + bottom];
            assertClose(content.x, target.x);
            assertClose(content.y, target.y);
            assertClose(content.width, target.width);
            assertClose(content.height, target.height);
            for (size_t count = 1; count <= 6; ++count) {
                LCWindowGridLayout layout = LCWindowGridLayoutMakeForOrientation(count, content.width, content.height, 2, 88, true, true);
                LCWindowGridRect first = LCWindowGridFrame(layout, 0);
                LCWindowGridRect last = LCWindowGridFrame(layout, count - 1);
                assertClose(first.y, 0);
                assertClose(content.y + last.y + last.height, target.y + target.height);
                assertClose(last.x + last.width, content.width);
                if (count == 4) assert(layout.rows == 2 && layout.columns == 2);
                if (count == 6) assert(layout.rows == 3 && layout.columns == 2);
            }

            // Reserving space can make a portrait host's content wider than tall.
            // It must retain portrait rows and its portrait divider storage key.
            LCWindowGridRect square = {12, 24, 600, 640};
            LCWindowGridRect squareSafe = {22, 86, 580, 544};
            content = LCWindowGridContentBoundsWithPortraitPreferences(square, squareSafe, top, bottom);
            assertClose(content.x, 22);
            assertClose(content.width, 580);
            assertClose(content.y, top ? 86 : 24);
            assertClose(content.y + content.height, bottom ? 630 : 664);
            LCWindowGridLayout portrait = LCWindowGridLayoutMakeForOrientation(6, content.width, content.height, 2, 88,
                                                                                square.height >= square.width, true);
            assert(portrait.rows == 3 && portrait.columns == 2);

            // Portrait choices never change the landscape top/side exclusions or bottom coverage.
            content = LCWindowGridContentBoundsWithPortraitPreferences((LCWindowGridRect){12, 24, 874, 402},
                (LCWindowGridRect){74, 44, 812, 362}, top, bottom);
            assertClose(content.x, 74);
            assertClose(content.y, 44);
            assertClose(content.width, 812);
            assertClose(content.height, 382);

            // No system insets means all four choices produce the same full drawing area.
            content = LCWindowGridContentBoundsWithPortraitPreferences(bounds, bounds, top, bottom);
            assertClose(content.y, 0);
            assertClose(content.height, 874);
        }
    }
}

static void testIndependentReservedAreas(void) {
    const LCWindowGridRect bounds[] = {
        {12, 24, 1366, 1024}, {12, 24, 874, 402}, {12, 24, 874, 402},
        {12, 24, 640, 600}, {12, 24, 600, 640}, {0, 0, 667, 375}
    };
    const LCWindowGridRect safe[] = {
        {24, 48, 1342, 980}, {74, 44, 796, 362}, {28, 44, 796, 362},
        {82, 44, 500, 560}, {22, 86, 580, 544}, {0, 0, 667, 375}
    };
    for (size_t s = 0; s < sizeof(bounds) / sizeof(bounds[0]); ++s) {
        bool portrait = bounds[s].height >= bounds[s].width;
        for (int portraitTop = 0; portraitTop <= 1; ++portraitTop) {
            for (int portraitBottom = 0; portraitBottom <= 1; ++portraitBottom) {
                for (int landscapeTop = 0; landscapeTop <= 1; ++landscapeTop) {
                    for (int landscapeBottom = 0; landscapeBottom <= 1; ++landscapeBottom) {
                        LCWindowGridRect content = LCWindowGridContentBoundsWithReservedAreas(bounds[s], safe[s],
                            portraitTop, portraitBottom, landscapeTop, landscapeBottom);
                        bool top = portrait ? portraitTop : landscapeTop;
                        bool bottom = portrait ? portraitBottom : landscapeBottom;
                        assertClose(content.x, safe[s].x);
                        assertClose(content.width, safe[s].width);
                        assertClose(content.y, top ? safe[s].y : bounds[s].y);
                        assertClose(content.y + content.height, bottom ? safe[s].y + safe[s].height : bounds[s].y + bounds[s].height);

                        // Side exclusions can make landscape content taller than wide.
                        // The full host orientation still selects the layout and preferences.
                        for (int singleRow = 0; singleRow <= 1; ++singleRow) {
                            LCWindowGridLayout grid = LCWindowGridLayoutMakeForOrientation(4, content.width,
                                content.height, 2, 88, portrait, singleRow);
                            assert(grid.rows == (!portrait && singleRow ? 1 : 2));
                            assert(grid.columns == (!portrait && singleRow ? 4 : 2));
                            LCWindowGridRect first = LCWindowGridFrame(grid, 0);
                            LCWindowGridRect last = LCWindowGridFrame(grid, 3);
                            assertClose(first.y, 0);
                            assertClose(last.x + last.width, content.width);
                            assertClose(last.y + last.height, content.height);
                        }
                    }
                }
            }
        }
        LCWindowGridRect legacy = LCWindowGridContentBounds(bounds[s], safe[s]);
        LCWindowGridRect defaults = LCWindowGridContentBoundsWithReservedAreas(bounds[s], safe[s], true, false, true, false);
        assertClose(legacy.x, defaults.x);
        assertClose(legacy.y, defaults.y);
        assertClose(legacy.width, defaults.width);
        assertClose(legacy.height, defaults.height);
    }
    LCWindowGridRect clipped = LCWindowGridContentBoundsWithReservedAreas(bounds[1],
        (LCWindowGridRect){-20, -20, 1000, 1000}, false, false, true, true);
    assertClose(clipped.x, 12);
    assertClose(clipped.y, 24);
    assertClose(clipped.width, 874);
    assertClose(clipped.height, 402);
    assertClose(LCWindowGridContentBoundsWithReservedAreas(bounds[0], (LCWindowGridRect){0}, true, true, true, true).width, 0);
}

static void testAdjustablePair(void) {
    LCWindowGridLayout layout = LCWindowGridLayoutMake(2, 390, 750, 2, 88);
    double rows[1];
    LCWindowGridResetDividers(rows, 2);
    double original = LCWindowGridDividerPosition(rows, 2, 0, 750, 2);
    assertClose(original, 375);
    assert(LCWindowGridMoveDivider(rows, 2, 0, original + 73, 750, 2, 88));
    LCWindowGridRect top = LCWindowGridFrameWithDividers(layout, 0, rows, NULL, NULL);
    LCWindowGridRect bottom = LCWindowGridFrameWithDividers(layout, 1, rows, NULL, NULL);
    assertClose(top.height, 374 + 73);
    assertClose(bottom.height, 374 - 73);
    assertClose(bottom.y - top.height, 2);
    assertClose(bottom.y + bottom.height, 750);
    assertClose(top.width, 390);
    // A touch anywhere in the wide hit target uses translation, so a zero delta never jumps.
    double position = LCWindowGridDividerPosition(rows, 2, 0, 750, 2);
    assert(!LCWindowGridMoveDivider(rows, 2, 0, position, 750, 2, 88));
    assert(LCWindowGridMoveDivider(rows, 2, 0, -1000, 750, 2, 88));
    assertClose(LCWindowGridFrameWithDividers(layout, 0, rows, NULL, NULL).height, 88);
    assert(LCWindowGridMoveDivider(rows, 2, 0, 1000, 750, 2, 88));
    assertClose(LCWindowGridFrameWithDividers(layout, 1, rows, NULL, NULL).height, 88);
    LCWindowGridResetDividers(rows, 2);
    assertClose(rows[0], 0.5);

    LCWindowGridLayout landscape = LCWindowGridLayoutMake(2, 750, 390, 2, 88);
    double columns[] = {0.5};
    LCWindowGridMoveDivider(columns, 2, 0, 450, 750, 2, LCWindowGridMinimumWidth);
    assertClose(LCWindowGridFrameWithDividers(landscape, 0, NULL, columns, NULL).width, 449);
    LCWindowGridMoveDivider(columns, 2, 0, -1000, 750, 2, LCWindowGridMinimumWidth);
    assertClose(LCWindowGridFrameWithDividers(landscape, 0, NULL, columns, NULL).width, 96);
}

static void testAlignedFourAndThree(void) {
    LCWindowGridLayout four = LCWindowGridLayoutMake(4, 390, 750, 2, 88);
    double rows[] = {0.4};
    double columns[] = {0.35};
    LCWindowGridRect a = LCWindowGridFrameWithDividers(four, 0, rows, columns, NULL);
    LCWindowGridRect b = LCWindowGridFrameWithDividers(four, 1, rows, columns, NULL);
    LCWindowGridRect c = LCWindowGridFrameWithDividers(four, 2, rows, columns, NULL);
    LCWindowGridRect d = LCWindowGridFrameWithDividers(four, 3, rows, columns, NULL);
    assertClose(a.width, 388 * 0.35);
    assertClose(a.height, 748 * 0.4);
    assertClose(a.width, c.width);
    assertClose(b.x, d.x);
    assertClose(a.height, b.height);
    assertClose(c.y, d.y);
    assertClose(d.x + d.width, 390);
    assertClose(d.y + d.height, 750);
    // The central intersection performs the same independent moves on both shared axes.
    LCWindowGridMoveDivider(rows, 2, 0, a.height + 1 + 37, 750, 2, 88);
    LCWindowGridMoveDivider(columns, 2, 0, a.width + 1 - 29, 390, 2, 96);
    LCWindowGridRect moved = LCWindowGridFrameWithDividers(four, 0, rows, columns, NULL);
    assertClose(moved.height, a.height + 37);
    assertClose(moved.width, a.width - 29);
    assertClose(LCWindowGridFrameWithDividers(four, 2, rows, columns, NULL).width, moved.width);
    assertClose(LCWindowGridFrameWithDividers(four, 1, rows, columns, NULL).height, moved.height);

    LCWindowGridLayout three = LCWindowGridLayoutMake(3, 390, 750, 2, 88);
    LCWindowGridRect last = LCWindowGridFrameWithDividers(three, 2, rows, columns, NULL);
    assertClose(last.x, 0);
    assertClose(last.width, 390);
    assertClose(last.y, moved.height + 2);
    assertClose(last.y + last.height, 750);
}

static void testAdjacentTracksAndPartialRow(void) {
    LCWindowGridLayout layout = LCWindowGridLayoutMake(8, 390, 750, 2, 88);
    assert(layout.rows == 3 && layout.columns == 3);
    double rows[] = {0.25, 0.7};
    double columns[] = {0.3, 0.7};
    double tail[] = {0.4};
    LCWindowGridRect last = LCWindowGridFrameWithDividers(layout, 7, rows, columns, tail);
    LCWindowGridRect first = LCWindowGridFrameWithDividers(layout, 0, rows, columns, tail);
    assertClose(last.x, 388 * 0.4 + 2);
    assertClose(last.x + last.width, 390);
    // Moving a divider does not move the third row or cross the next boundary.
    LCWindowGridMoveDivider(rows, 3, 0, 2000, 750, 2, 88);
    LCWindowGridRect middle = LCWindowGridFrameWithDividers(layout, 3, rows, columns, tail);
    assertClose(middle.height, 88);
    LCWindowGridRect after = LCWindowGridFrameWithDividers(layout, 7, rows, columns, tail);
    assertClose(after.y, last.y);
    assertClose(after.height, last.height);
    LCWindowGridMoveDivider(columns, 3, 0, 145, 390, 2, 96);
    after = LCWindowGridFrameWithDividers(layout, 7, rows, columns, tail);
    assertClose(after.x, last.x);
    assertClose(after.width, last.width);
    double fullRowWidth = LCWindowGridFrameWithDividers(layout, 0, rows, columns, tail).width;
    assert(fullRowWidth != first.width);
    LCWindowGridMoveDivider(tail, 2, 0, 210, 390, 2, 96);
    assertClose(LCWindowGridFrameWithDividers(layout, 0, rows, columns, tail).width, fullRowWidth);
    assertClose(LCWindowGridFrameWithDividers(layout, 6, rows, columns, tail).width, 209);
}

static void testReclampingAndInvalidDividers(void) {
    double columns[] = {0.1, 0.9};
    LCWindowGridConstrainDividers(columns, 3, 390, 2, 96);
    assertClose(columns[0] * 386, 96);
    assertClose((1 - columns[1]) * 386, 96);
    double saved = columns[0];
    LCWindowGridConstrainDividers(columns, 3, 900, 2, 96);
    assertClose(columns[0], saved);
    assert(!LCWindowGridMoveDivider(columns, 3, 0, NAN, 390, 2, 96));
    assert(!LCWindowGridMoveDivider(columns, 3, 0, INFINITY, 390, 2, 96));
    assert(!LCWindowGridMoveDivider(columns, 3, 3, 50, 390, 2, 96));
    assert(!LCWindowGridMoveDivider(columns, 3, 0, 50, 0, 2, 96));
    assert(!LCWindowGridMoveDivider(NULL, 3, 0, 50, 390, 2, 96));
    assertClose(columns[0], saved);
    columns[0] = NAN;
    columns[1] = -10;
    LCWindowGridConstrainDividers(columns, 3, 390, 2, 96);
    assert(isfinite(columns[0]) && isfinite(columns[1]));
    assert((columns[1] - columns[0]) * 386 >= 96 - epsilon);
    // On a surface too small for the preferred minimum, every track keeps an equal positive share.
    LCWindowGridConstrainDividers(columns, 3, 20, 2, 96);
    assertClose(columns[0], 1.0 / 3);
    assertClose(columns[1], 2.0 / 3);
    LCWindowGridResetDividers(NULL, 0);
    LCWindowGridConstrainDividers(NULL, 0, 0, 0, 0);
}

static uint32_t randomState = 42;
static double randomPosition(double length) {
    randomState = randomState * 1664525u + 1013904223u;
    return ((double)randomState / UINT32_MAX * 1.4 - 0.2) * length;
}

static void testAdjustedSizesAndCounts(bool singleRowInLandscape) {
    const double sizes[][2] = {
        {320, 524}, {375, 647}, {390, 750}, {430, 830},
        {750, 354}, {932, 430}, {768, 980}, {1008, 700},
        {1, 1}, {50, 45}, {143.5, 197.25}
    };
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
        for (size_t count = 1; count <= 128; ++count) {
            for (size_t gap = 0; gap <= 2; gap += 2) {
                LCWindowGridLayout layout = LCWindowGridLayoutMakeWithLandscapePreference(count, sizes[s][0], sizes[s][1],
                                                                                          gap, 88, singleRowInLandscape);
                size_t tailCount = count - (layout.rows - 1) * layout.columns;
                double rows[128], columns[128], tail[128];
                LCWindowGridResetDividers(rows, layout.rows);
                LCWindowGridResetDividers(columns, layout.columns);
                LCWindowGridResetDividers(tail, tailCount);
                for (size_t step = 0; step < 20; ++step) {
                    if (layout.rows > 1) LCWindowGridMoveDivider(rows, layout.rows, step % (layout.rows - 1),
                        randomPosition(layout.height), layout.height, layout.spacing, 88);
                    if (layout.columns > 1) LCWindowGridMoveDivider(columns, layout.columns, step % (layout.columns - 1),
                        randomPosition(layout.width), layout.width, layout.spacing, 96);
                    if (tailCount > 1) LCWindowGridMoveDivider(tail, tailCount, step % (tailCount - 1),
                        randomPosition(layout.width), layout.width, layout.spacing, 96);
                }
                double totalArea = 0;
                for (size_t i = 0; i < count; ++i) {
                    LCWindowGridRect a = LCWindowGridFrameWithDividers(layout, i, rows, columns, tail);
                    assert(isfinite(a.x) && isfinite(a.y) && isfinite(a.width) && isfinite(a.height));
                    assert(a.x >= 0 && a.y >= 0 && a.width > 0 && a.height > 0);
                    assert(a.x + a.width <= layout.width + epsilon);
                    assert(a.y + a.height <= layout.height + epsilon);
                    size_t tracks = i / layout.columns == layout.rows - 1 ? tailCount : layout.columns;
                    double minWidth = fmin(96, (layout.width - layout.spacing * (tracks - 1)) / tracks);
                    double minHeight = fmin(88, (layout.height - layout.spacing * (layout.rows - 1)) / layout.rows);
                    assert(a.width >= minWidth - epsilon && a.height >= minHeight - epsilon);
                    totalArea += a.width * a.height;
                    for (size_t j = 0; j < i; ++j) {
                        LCWindowGridRect b = LCWindowGridFrameWithDividers(layout, j, rows, columns, tail);
                        assert(a.x + a.width <= b.x + epsilon || b.x + b.width <= a.x + epsilon ||
                               a.y + a.height <= b.y + epsilon || b.y + b.height <= a.y + epsilon);
                    }
                }
                if (gap == 0) assertClose(totalArea, layout.width * layout.height);
            }
        }
    }
}

int main(void) {
    testCommonLayouts();
    testSizesAndWindowCounts(false);
    testSizesAndWindowCounts(true);
    testLandscapeSingleRow();
    testCompactGridUsesSafeArea();
    testGridContentBounds();
    testPortraitReservedAreas();
    testIndependentReservedAreas();
    testInvalidInput();
    testAdjustablePair();
    testAlignedFourAndThree();
    testAdjacentTracksAndPartialRow();
    testReclampingAndInvalidDividers();
    testAdjustedSizesAndCounts(false);
    testAdjustedSizesAndCounts(true);
    puts("Window grid layout tests passed (14,082 size/count/spacing combinations, landscape single row, independent portrait/landscape reserved areas, safe-area coverage, divider drags, alignment and clamping checks).");
    return 0;
}
