// Geometry shared by the virtual window host and the standalone layout tests.
#ifndef LCWindowGridLayout_h
#define LCWindowGridLayout_h

#include <math.h>
#include <stddef.h>
#include <stdbool.h>

static const double LCWindowGridSpacing = 2;
static const double LCWindowGridMinimumHeight = 88;
static const double LCWindowGridMinimumWidth = 96;

typedef struct {
    double x, y, width, height;
} LCWindowGridRect;

typedef struct {
    size_t count, rows, columns;
    double width, height, spacing;
} LCWindowGridLayout;

// Draw the grid beneath the home indicator; each guest still receives its own
// bottom safe area for controls. Keep the top and side exclusions for system UI.
static inline LCWindowGridRect LCWindowGridContentBounds(LCWindowGridRect bounds,
                                                        LCWindowGridRect safeBounds) {
    if (!isfinite(bounds.x) || !isfinite(bounds.y) || !isfinite(bounds.width) || !isfinite(bounds.height) ||
        !isfinite(safeBounds.x) || !isfinite(safeBounds.y) || !isfinite(safeBounds.width) ||
        !isfinite(safeBounds.height) || bounds.width <= 0 || bounds.height <= 0 ||
        safeBounds.width <= 0 || safeBounds.height <= 0) return (LCWindowGridRect){0};
    double left = fmax(bounds.x, safeBounds.x);
    double right = fmin(bounds.x + bounds.width, safeBounds.x + safeBounds.width);
    double top = fmax(bounds.y, safeBounds.y);
    return (LCWindowGridRect){left, top, fmax(0, right - left), fmax(0, bounds.y + bounds.height - top)};
}

static inline LCWindowGridLayout LCWindowGridLayoutMake(size_t count, double width, double height,
                                                       double spacing, double minimumHeight) {
    LCWindowGridLayout layout = {0};
    if (count == 0 || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 ||
        !isfinite(spacing) || !isfinite(minimumHeight)) {
        return layout;
    }

    // Put the longer side of the grid along the longer side of the screen.
    size_t side = (size_t)ceil(sqrt((double)count));
    size_t rows = height >= width ? side : 1 + (count - 1) / side;
    spacing = fmax(0, spacing);
    if (minimumHeight > 0) {
        double maximumRows = fmax(1, floor((height + spacing) / (minimumHeight + spacing)));
        if (maximumRows < (double)rows) {
            rows = (size_t)maximumRows;
        }
    }
    size_t columns = 1 + (count - 1) / rows;
    rows = 1 + (count - 1) / columns;

    // Reduce the gaps on very small surfaces instead of producing negative sizes.
    spacing = fmin(spacing, fmin(width / (2.0 * columns), height / (2.0 * rows)));
    layout.count = count;
    layout.rows = rows;
    layout.columns = columns;
    layout.width = width;
    layout.height = height;
    layout.spacing = spacing;
    return layout;
}

// Divider fractions measure content only, excluding the gaps. A NULL array means equal sizes.
// Each axis with N tracks owns N - 1 ordered fractions between zero and one.
static inline double LCWindowGridBoundary(const double *dividers, size_t tracks, size_t boundary) {
    if (boundary == 0 || tracks == 0) return 0;
    if (boundary >= tracks) return 1;
    return dividers ? dividers[boundary - 1] : (double)boundary / tracks;
}

static inline void LCWindowGridResetDividers(double *dividers, size_t tracks) {
    if (!dividers) return;
    for (size_t i = 1; i < tracks; ++i) dividers[i - 1] = (double)i / tracks;
}

static inline double LCWindowGridMinimumFraction(size_t tracks, double length, double spacing,
                                                 double minimumSize) {
    double content = length - spacing * (tracks - 1);
    return fmin(1.0 / tracks, fmax(0, minimumSize) / content);
}

// Re-clamp saved proportions when the available space changes. Very small surfaces stay equal.
static inline void LCWindowGridConstrainDividers(double *dividers, size_t tracks, double length,
                                                  double spacing, double minimumSize) {
    if (!dividers || tracks < 2 || !isfinite(length) || !isfinite(spacing) ||
        !isfinite(minimumSize) || spacing < 0 || length <= spacing * (tracks - 1)) return;
    double minimum = LCWindowGridMinimumFraction(tracks, length, spacing, minimumSize);
    double previous = 0;
    for (size_t i = 1; i < tracks; ++i) {
        double value = isfinite(dividers[i - 1]) ? dividers[i - 1] : (double)i / tracks;
        dividers[i - 1] = fmin(1 - minimum * (tracks - i), fmax(previous + minimum, value));
        previous = dividers[i - 1];
    }
}

static inline double LCWindowGridDividerPosition(const double *dividers, size_t tracks, size_t index,
                                                  double length, double spacing) {
    if (tracks < 2 || index >= tracks - 1) return 0;
    double content = length - spacing * (tracks - 1);
    return LCWindowGridBoundary(dividers, tracks, index + 1) * content + spacing * (index + 0.5);
}

// Move only the two tracks adjacent to a divider, without crossing either neighbour.
static inline bool LCWindowGridMoveDivider(double *dividers, size_t tracks, size_t index,
                                            double position, double length, double spacing, double minimumSize) {
    if (!dividers || tracks < 2 || index >= tracks - 1 || !isfinite(position) ||
        !isfinite(length) || !isfinite(spacing) || !isfinite(minimumSize) ||
        spacing < 0 || length <= spacing * (tracks - 1)) return false;
    LCWindowGridConstrainDividers(dividers, tracks, length, spacing, minimumSize);
    double content = length - spacing * (tracks - 1);
    double minimum = LCWindowGridMinimumFraction(tracks, length, spacing, minimumSize);
    double lower = LCWindowGridBoundary(dividers, tracks, index) + minimum;
    double upper = LCWindowGridBoundary(dividers, tracks, index + 2) - minimum;
    double fraction = (position - spacing * (index + 0.5)) / content;
    double value = fmin(upper, fmax(lower, fraction));
    if (fabs(dividers[index] - value) < 1e-12) return false;
    dividers[index] = value;
    return true;
}

static inline LCWindowGridRect LCWindowGridFrameWithDividers(LCWindowGridLayout layout, size_t index,
                                                             const double *rowDividers, const double *columnDividers,
                                                             const double *lastRowDividers) {
    LCWindowGridRect frame = {0};
    if (index >= layout.count || layout.rows == 0 || layout.columns == 0) {
        return frame;
    }

    size_t row = index / layout.columns;
    size_t column = index % layout.columns;
    size_t remaining = layout.count - row * layout.columns;
    size_t columnsInRow = remaining < layout.columns ? remaining : layout.columns;
    // Full rows share vertical dividers. An incomplete last row still spans the whole width.
    const double *horizontal = columnsInRow == layout.columns ? columnDividers : lastRowDividers;
    double contentWidth = layout.width - layout.spacing * (columnsInRow - 1);
    double contentHeight = layout.height - layout.spacing * (layout.rows - 1);
    double left = LCWindowGridBoundary(horizontal, columnsInRow, column);
    double right = LCWindowGridBoundary(horizontal, columnsInRow, column + 1);
    double top = LCWindowGridBoundary(rowDividers, layout.rows, row);
    double bottom = LCWindowGridBoundary(rowDividers, layout.rows, row + 1);
    frame.width = (right - left) * contentWidth;
    frame.height = (bottom - top) * contentHeight;
    frame.x = left * contentWidth + column * layout.spacing;
    frame.y = top * contentHeight + row * layout.spacing;
    return frame;
}

static inline LCWindowGridRect LCWindowGridFrame(LCWindowGridLayout layout, size_t index) {
    return LCWindowGridFrameWithDividers(layout, index, NULL, NULL, NULL);
}

#endif
