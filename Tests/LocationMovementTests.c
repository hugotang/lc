#include <assert.h>
#include <stdio.h>
#include "../LiveContainer/Tweaks/LocationMovement.h"

int main(void) {
    double lat, lon, course;
    LCLocationAdvance(0, 0, 0, 1, 1.4, 1, &lat, &lon, &course);
    assert(fabs(lat * 111195.0802 - 1.4) < 0.001 && fabs(lon) < 1e-9 && course == 0);
    LCLocationAdvance(0, 0, 1, 0, 6, 1, &lat, &lon, &course);
    assert(fabs(lon * 111195.0802 - 6) < 0.001 && fabs(lat) < 1e-9 && course == 90);
    LCLocationAdvance(0, 179.99999, 1, 0, 6, 1, &lat, &lon, &course);
    assert(lon < -179.999 && lon >= -180);
    LCLocationAdvance(0, -179.99999, -1, 0, 6, 1, &lat, &lon, &course);
    assert(lon > 179.999 && lon <= 180 && course == 270);
    for (double pole = -90; pole <= 90; pole += 180) {
        LCLocationAdvance(pole, 0, 1, 0, 6, 1, &lat, &lon, &course);
        assert(isfinite(lat) && isfinite(lon) && fabs(lat) <= 90 && fabs(lon) <= 180);
    }
    LCLocationAdvance(22.3193, 114.1694, -1, -1, 6, 0, &lat, &lon, &course);
    assert(fabs(lat - 22.3193) < 1e-9 && fabs(lon - 114.1694) < 1e-9 && course == 225);
    puts("Location movement tests passed");
}
