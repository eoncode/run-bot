import Foundation
import Combine
import Darwin

/// Observable view-model that periodically samples CPU, memory, and disk metrics.
final class SystemStatsViewModel: ObservableObject {
    @Published var current: SystemStats = .zero

    /// Rolling history arrays for sparkline charts (last 60 samples).
    @Published var cpuHistory:  [Double] = Array(repeating: 0, count: 60)
    @Published var memHistory:  [Double] = Array(repeating: 0, count: 60)
    @Published var diskHistory: [Double] = Array(repeating: 0, count: 60)

    private var timer: Timer?
    private var prevCPUInfo: processor_info_array_t?
    private var prevNumCPUInfo: mach_msg_type_number_t = 0

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    deinit {
        timer?.invalidate()
        if let prev = prevCPUInfo {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), vm_size_t(prevNumCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
    }

    private func sample() {
        let cpu  = sampleCPU()
        let mem  = sampleMemory()
        let disk = sampleDisk()

        let stats = SystemStats(
            cpuPct:    cpu,
            memUsedGB: mem.used,
            memTotalGB: mem.total,
            diskUsedGB: disk.used,
            diskTotalGB: disk.total
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.current = stats
            self.cpuHistory.removeFirst();  self.cpuHistory.append(cpu)
            self.memHistory.removeFirst();  self.memHistory.append(mem.total > 0 ? mem.used / mem.total * 100 : 0)
            self.diskHistory.removeFirst(); self.diskHistory.append(disk.total > 0 ? disk.used / disk.total * 100 : 0)
        }
    }

    // MARK: CPU
    private func sampleCPU() -> Double {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUsU, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            if let prev = prevCPUInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev),
                              vm_size_t(prevNumCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))
            }
            prevCPUInfo    = cpuInfo
            prevNumCPUInfo = numCPUInfo
        }

        guard let prevInfo = prevCPUInfo else { return 0 }

        var totalUsed: Double = 0
        var totalAll:  Double = 0
        let numCPUs = Int(numCPUsU)

        for i in 0 ..< numCPUs {
            let base = Int32(CPU_STATE_MAX) * Int32(i)
            let user   = Double(cpuInfo[Int(base) + Int(CPU_STATE_USER)]   - prevInfo[Int(base) + Int(CPU_STATE_USER)])
            let sys    = Double(cpuInfo[Int(base) + Int(CPU_STATE_SYSTEM)]  - prevInfo[Int(base) + Int(CPU_STATE_SYSTEM)])
            let idle   = Double(cpuInfo[Int(base) + Int(CPU_STATE_IDLE)]    - prevInfo[Int(base) + Int(CPU_STATE_IDLE)])
            let nice   = Double(cpuInfo[Int(base) + Int(CPU_STATE_NICE)]    - prevInfo[Int(base) + Int(CPU_STATE_NICE)])
            let used   = user + sys + nice
            let all    = used + idle
            totalUsed += used
            totalAll  += all
        }
        guard totalAll > 0 else { return 0 }
        return (totalUsed / totalAll) * 100
    }

    // MARK: Memory
    private func sampleMemory() -> (used: Double, total: Double) {
        var stats  = vm_statistics64()
        var count  = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize   = Double(vm_kernel_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return (0, totalBytes / 1e9) }
        let usedPages  = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
        return (usedPages * pageSize / 1e9, totalBytes / 1e9)
    }

    // MARK: Disk
    private func sampleDisk() -> (used: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free  = attrs[.systemFreeSize] as? Int64
        else { return (0, 0) }
        let totalGB = Double(total) / 1e9
        let usedGB  = Double(total - free) / 1e9
        return (usedGB, totalGB)
    }
}
