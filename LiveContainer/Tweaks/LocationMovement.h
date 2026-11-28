#pragma once
#include <math.h>

// Great-circle motion in metres. Never scale longitude by cos(latitude), which
// becomes unstable at the poles. Result crosses the antimeridian continuously.
static inline void LCLocationAdvance(double latitude, double longitude, double east, double north,
                                     double speed, double elapsed, double *lat, double *lon, double *course) {
    double bearing = atan2(east, north), radians = 3.14159265358979323846 / 180.0;
    double angular = speed * elapsed / 6371008.8;
    double start = latitude * radians;
    double end = asin(fmax(-1, fmin(1, sin(start) * cos(angular) + cos(start) * sin(angular) * cos(bearing))));
    double longitudeEnd = longitude * radians + atan2(sin(bearing) * sin(angular) * cos(start),
                                                       cos(angular) - sin(start) * sin(end));
    *lat = end / radians;
    *lon = fmod(longitudeEnd / radians + 540.0, 360.0) - 180.0;
    *course = fmod(bearing / radians + 360.0, 360.0);
}
