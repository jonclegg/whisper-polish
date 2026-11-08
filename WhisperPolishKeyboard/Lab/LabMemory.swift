import Foundation
import os

/// EXPERIMENT: the memory numbers iOS judges the keyboard by.
enum LabMemory {
    /// What jetsam counts against the extension's limit.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Resident pages, including clean file-backed ones jetsam doesn't count.
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    static func availableMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }

    /// Appends a line to lab/breadcrumbs.log and flushes it, so the last line
    /// before a kill survives.
    static func breadcrumb(_ event: String) {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
            .appendingPathComponent("lab/breadcrumbs.log")
        let line = String(format: "%.3f %@ footprint=%.1f available=%.1f\n", Date().timeIntervalSince1970, event, footprintMB(), availableMB())
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.synchronize()
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func snapshot() -> [String: Double] {
        ["footprint_mb": footprintMB(), "resident_mb": residentMB(), "available_mb": availableMB()]
    }

    /// Tracks the highest footprint while work runs.
    final class PeakWatcher {
        private let lock = OSAllocatedUnfairLock(initialState: 0.0)
        private var timer: DispatchSourceTimer?

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [lock] in
                let now = LabMemory.footprintMB()
                lock.withLock { $0 = max($0, now) }
            }
            timer.resume()
            self.timer = timer
        }

        func stop() -> Double {
            timer?.cancel()
            timer = nil
            return lock.withLock { max($0, LabMemory.footprintMB()) }
        }
    }
}
