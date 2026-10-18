// Geometry shared by the virtual window host and the standalone layout tests.
#ifndef LCWindowGridLayout_h
#define LCWindowGridLayout_h

#include <math.h>
#include <stddef.h>

typedef struct {
    double x, y, width, height;
} LCWindowGridRect;

typedef struct {
    size_t count, rows, columns;
    double width, height, spacing;
} LCWindowGridLayout;

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

static inline LCWindowGridRect LCWindowGridFrame(LCWindowGridLayout layout, size_t index) {
    LCWindowGridRect frame = {0};
    if (index >= layout.count || layout.rows == 0 || layout.columns == 0) {
        return frame;
    }

    size_t row = index / layout.columns;
    size_t column = index % layout.columns;
    size_t remaining = layout.count - row * layout.columns;
    size_t columnsInRow = remaining < layout.columns ? remaining : layout.columns;
    // Let an incomplete final row use the available width.
    frame.width = (layout.width - layout.spacing * (columnsInRow - 1)) / columnsInRow;
    frame.height = (layout.height - layout.spacing * (layout.rows - 1)) / layout.rows;
    frame.x = column * (frame.width + layout.spacing);
    frame.y = row * (frame.height + layout.spacing);
    return frame;
}

#endif
