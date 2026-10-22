#ifndef LC_PERFORMANCE_METRICS_H
#define LC_PERFORMANCE_METRICS_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>

// 100% is one fully occupied CPU core. Multi-core processes may exceed 100%.
// Missing samples, counter resets and suspension gaps are not zero CPU usage.
static inline double LCPerformanceCPUPercent(double previousCPU, double previousTime, double cpu, double time) {
    double elapsed = time - previousTime;
    if (!isfinite(previousCPU) || previousCPU < 0 || !isfinite(cpu) || cpu < previousCPU ||
        !isfinite(previousTime) || previousTime <= 0 || !isfinite(time) || elapsed <= 0 || elapsed > 3.0) return NAN;
    double percent = 100.0 * (cpu - previousCPU) / elapsed;
    return isfinite(percent) ? percent : NAN;
}

enum { LCPerformanceResponseCapacity = 600 };
typedef struct {
    double timestamps[LCPerformanceResponseCapacity], milliseconds[LCPerformanceResponseCapacity];
    unsigned count, next;
} LCPerformanceResponseHistory;

static inline void LCPerformanceRecordResponse(LCPerformanceResponseHistory *history, double timestamp, double milliseconds) {
    if (!history || !isfinite(timestamp) || timestamp <= 0 || !isfinite(milliseconds) || milliseconds < 0) return;
    history->timestamps[history->next] = timestamp;
    history->milliseconds[history->next] = milliseconds;
    history->next = (history->next + 1) % LCPerformanceResponseCapacity;
    if (history->count < LCPerformanceResponseCapacity) history->count++;
}

static inline int LCPerformanceCompareDouble(const void *left, const void *right) {
    double a = *(const double *)left, b = *(const double *)right;
    return (a > b) - (a < b);
}

// Nearest-rank percentiles of at most 600 successful group replies in the last 10 s.
// Sorting happens once per UI sample, never on the event-forwarding path.
static inline unsigned LCPerformanceResponsePercentiles(const LCPerformanceResponseHistory *history, double now, double *p50, double *p95) {
    *p50 = *p95 = NAN;
    if (!history || !isfinite(now)) return 0;
    double values[LCPerformanceResponseCapacity];
    unsigned count = 0;
    for (unsigned i = 0; i < history->count && i < LCPerformanceResponseCapacity; i++) {
        double age = now - history->timestamps[i];
        if (age >= 0 && age <= 10.0) values[count++] = history->milliseconds[i];
    }
    if (!count) return 0;
    qsort(values, count, sizeof(double), LCPerformanceCompareDouble);
    *p50 = values[(unsigned)ceil(count * 0.5) - 1];
    *p95 = values[(unsigned)ceil(count * 0.95) - 1];
    return count;
}

#endif
