#ifndef LC_PROCESS_METRICS_H
#define LC_PROCESS_METRICS_H

#import <Foundation/Foundation.h>
#include <sys/resource.h>
#include <mach/mach.h>

// Read only this process. Guests report through their existing PID-bound channel;
// no task-for-pid access, background timer, new entitlement or polling thread.
static inline NSDictionary *LCReadProcessMetrics(void) {
    NSMutableDictionary *sample = [NSMutableDictionary dictionary];
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        sample[@"cpuSeconds"] = @(usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
            usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
    }
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS && count >= TASK_VM_INFO_REV1_COUNT) {
        sample[@"footprintBytes"] = @(info.phys_footprint);
    }
    sample[@"timestamp"] = @(NSProcessInfo.processInfo.systemUptime);
    return sample.copy;
}

#endif
