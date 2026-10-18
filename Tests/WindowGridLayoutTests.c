// Run with: cc -std=c11 -Wall -Wextra -Werror -pedantic Tests/WindowGridLayoutTests.c -lm -o /tmp/window-grid-tests && /tmp/window-grid-tests
#include "../MultitaskSupport/WindowGridLayout.h"
#include <assert.h>
#include <stdio.h>

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

static void assertUsableLayout(size_t count, double width, double height, double spacing) {
    LCWindowGridLayout layout = LCWindowGridLayoutMake(count, width, height, spacing, 88);
    assert(layout.count == count);
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

static void testSizesAndWindowCounts(void) {
    const double sizes[][2] = {
        {320, 524}, {375, 647}, {390, 750}, {430, 830}, // iPhone safe-area sizes
        {750, 354}, {932, 430}, {768, 980}, {1008, 700},
        {1, 1}, {50, 45}, {143.5, 197.25}
    };
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
        for (size_t count = 1; count <= 128; ++count) {
            assertUsableLayout(count, sizes[s][0], sizes[s][1], 8);
            assertUsableLayout(count, sizes[s][0], sizes[s][1], LCWindowGridSpacing);
            assertUsableLayout(count, sizes[s][0], sizes[s][1], 0);
        }
    }
    assertUsableLayout(16, 320, 200, 1000);
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

int main(void) {
    testCommonLayouts();
    testSizesAndWindowCounts();
    testCompactGridUsesSafeArea();
    testInvalidInput();
    puts("Window grid layout tests passed (4,225 size/count/spacing combinations and compact-grid edge checks).");
    return 0;
}
