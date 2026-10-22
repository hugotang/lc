#include "../MultitaskSupport/PerformanceMetrics.h"
#include <assert.h>
#include <float.h>
#include <stdio.h>

int main(void) {
    assert(LCPerformanceCPUPercent(1, 100, 1.5, 101) == 50);
    assert(LCPerformanceCPUPercent(1, 100, 3.5, 101) == 250);
    assert(LCPerformanceCPUPercent(1, 100, 1, 101) == 0);
    assert(isnan(LCPerformanceCPUPercent(2, 100, 1, 101)));
    assert(isnan(LCPerformanceCPUPercent(0, 0, 1, 101)));
    assert(isnan(LCPerformanceCPUPercent(1, 100, 2, 100)));
    assert(isnan(LCPerformanceCPUPercent(1, 100, 2, 104)));
    assert(isnan(LCPerformanceCPUPercent(NAN, 100, 2, 101)));
    assert(isnan(LCPerformanceCPUPercent(1, 100, INFINITY, 101)));
    assert(isnan(LCPerformanceCPUPercent(1, 100, DBL_MAX, 101)));
    LCPerformanceResponseHistory history = {0};
    double p50, p95;
    assert(LCPerformanceResponsePercentiles(&history, 100, &p50, &p95) == 0);
    assert(isnan(p50) && isnan(p95));
    for (int i = 1; i <= 100; i++) LCPerformanceRecordResponse(&history, 100, i);
    assert(LCPerformanceResponsePercentiles(&history, 101, &p50, &p95) == 100);
    assert(p50 == 50 && p95 == 95);
    assert(LCPerformanceResponsePercentiles(&history, 110.01, &p50, &p95) == 0);
    assert(isnan(p50) && isnan(p95));
    assert(LCPerformanceResponsePercentiles(&history, 99, &p50, &p95) == 0);
    LCPerformanceRecordResponse(&history, NAN, 1);
    LCPerformanceRecordResponse(&history, 100, NAN);
    LCPerformanceRecordResponse(&history, 100, -1);
    assert(history.count == 100);
    for (int i = 0; i < 1000; i++) LCPerformanceRecordResponse(&history, 200, 12);
    assert(history.count == 600);
    assert(LCPerformanceResponsePercentiles(&history, 201, &p50, &p95) == 600);
    assert(p50 == 12 && p95 == 12);
    puts("Performance metric tests passed (multi-core CPU, missing/reset/stale counters, bounded percentiles, expiry and invalid numbers).");
    return 0;
}
