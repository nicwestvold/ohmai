import Darwin
import Foundation

/// ohmai's own resource use, read on demand (never polled) so showing it costs nothing idle.
struct Footprint: Equatable {
    /// Physical footprint: the "Memory" figure Activity Monitor shows.
    let memoryBytes: UInt64?
    /// The app bundle on disk.
    let diskBytes: UInt64?

    static func current() -> Footprint {
        Footprint(memoryBytes: physicalFootprint(), diskBytes: allocatedSize(of: Bundle.main.bundleURL))
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func allocatedSize(of url: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    var summary: String {
        let style = ByteCountFormatStyle(style: .memory)
        let memory = memoryBytes.map { Int64($0).formatted(style) } ?? "?"
        let disk = diskBytes.map { Int64($0).formatted(.byteCount(style: .file)) } ?? "?"
        return "\(memory) memory · \(disk) on disk"
    }
}
