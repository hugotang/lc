#ifndef LCWindowKeyboardGeometry_h
#define LCWindowKeyboardGeometry_h

#include "WindowGridLayout.h"

static inline bool LCKeyboardRectIsValid(LCWindowGridRect rect) {
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) &&
           rect.width > 0 && rect.height > 0;
}

// Floating keyboards and hardware-keyboard accessory bars must not reflow the whole desktop.
static inline LCWindowGridRect LCKeyboardAvailableRect(LCWindowGridRect bounds, LCWindowGridRect keyboard) {
    if (!LCKeyboardRectIsValid(bounds) || !LCKeyboardRectIsValid(keyboard) || keyboard.height <= 80) return bounds;
    double overlap = fmin(bounds.x + bounds.width, keyboard.x + keyboard.width) - fmax(bounds.x, keyboard.x);
    if (overlap < bounds.width * 0.8 || keyboard.y + keyboard.height < bounds.y + bounds.height - 2 ||
        keyboard.y >= bounds.y + bounds.height || keyboard.y <= bounds.y) return bounds;
    bounds.height = keyboard.y - bounds.y;
    return bounds;
}

static inline LCWindowGridRect LCKeyboardFitWindow(LCWindowGridRect frame, LCWindowGridRect available) {
    if (!LCKeyboardRectIsValid(frame) || !LCKeyboardRectIsValid(available)) return frame;
    if (frame.y + frame.height <= available.y + available.height && frame.y >= available.y) return frame;
    frame.height = fmin(frame.height, available.height);
    frame.y = fmax(available.y, fmin(frame.y, available.y + available.height - frame.height));
    return frame;
}

// Restore a floating window after rotation without keeping its temporary keyboard height.
static inline LCWindowGridRect LCKeyboardRestoreWindow(LCWindowGridRect frame, LCWindowGridRect oldBounds, LCWindowGridRect newBounds) {
    if (!LCKeyboardRectIsValid(frame) || !LCKeyboardRectIsValid(oldBounds) || !LCKeyboardRectIsValid(newBounds)) return frame;
    if (oldBounds.x == newBounds.x && oldBounds.y == newBounds.y &&
        oldBounds.width == newBounds.width && oldBounds.height == newBounds.height) return frame;
    frame.x = newBounds.x + (frame.x - oldBounds.x) / oldBounds.width * newBounds.width;
    frame.y = newBounds.y + (frame.y - oldBounds.y) / oldBounds.height * newBounds.height;
    frame.width = fmin(frame.width, newBounds.width);
    frame.height = fmin(frame.height, newBounds.height);
    frame.x = fmax(newBounds.x, fmin(frame.x, newBounds.x + newBounds.width - frame.width));
    frame.y = fmax(newBounds.y, fmin(frame.y, newBounds.y + newBounds.height - frame.height));
    return frame;
}

#endif
