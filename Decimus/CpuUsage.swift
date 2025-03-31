// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

func cpuUsage() throws -> Double {
    var taskInfoCount: mach_msg_type_number_t = mach_msg_type_number_t(TASK_INFO_MAX)
    var tinfo = [integer_t](repeating: 0, count: Int(taskInfoCount))

    let getTaskInfo: kern_return_t = task_info(mach_task_self_,
                                               task_flavor_t(TASK_BASIC_INFO),
                                               &tinfo,
                                               &taskInfoCount)
    guard getTaskInfo == KERN_SUCCESS else { throw getTaskInfo }

    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    defer {
        // Ensure we dealloc the thread list.
        let size = MemoryLayout<thread_act_t>.stride * Int(threadCount)
        if let threadList = threadList {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threadList),
                          vm_size_t(threadCount))
        }
    }

    let getThreads = task_threads(mach_task_self_, &threadList, &threadCount)
    guard getThreads == KERN_SUCCESS else { throw getThreads }

    var totalCpuUsage: Double = 0
    guard let threadList = threadList else { fatalError() }
    for thread in 0 ..< Int(threadCount) {
        var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
        var threadInfo = [integer_t](repeating: 0, count: Int(threadInfoCount))
        let getThreadInfo = thread_info(threadList[thread],
                                        thread_flavor_t(THREAD_BASIC_INFO),
                                        &threadInfo,
                                        &threadInfoCount)
        guard getThreadInfo == KERN_SUCCESS else { throw getThreadInfo }

        let threadBasicInfo = convertThreadInfoToThreadBasicInfo(threadInfo)
        if threadBasicInfo.flags != TH_FLAGS_IDLE {
            totalCpuUsage += (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
        }
    }
    return totalCpuUsage
}

private func convertThreadInfoToThreadBasicInfo(_ threadInfo: [integer_t]) -> thread_basic_info {
    var result = thread_basic_info()
    result.user_time = time_value_t(seconds: threadInfo[0], microseconds: threadInfo[1])
    result.system_time = time_value_t(seconds: threadInfo[2], microseconds: threadInfo[3])
    result.cpu_usage = threadInfo[4]
    result.policy = threadInfo[5]
    result.run_state = threadInfo[6]
    result.flags = threadInfo[7]
    result.suspend_count = threadInfo[8]
    result.sleep_time = threadInfo[9]
    return result
}
