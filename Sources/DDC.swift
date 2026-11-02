import Foundation
import IOKit

/// DDC/CI over IOAVService (Apple Silicon). The IOAVService functions are private
/// IOKit symbols, so they are resolved at runtime with dlsym.
enum DDC {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static let handle = dlopen(nil, RTLD_NOW)
    private static let createFn: CreateFn? = dlsym(handle, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let writeFn: I2CFn? = dlsym(handle, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFn.self) }
    private static let readFn: I2CFn? = dlsym(handle, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFn.self) }

    static var isSupported: Bool { createFn != nil && writeFn != nil && readFn != nil }

    /// VCP feature code for luminance (brightness).
    static let brightnessCode: UInt8 = 0x10

    /// An external display's DDC channel, identified by the EDID vendor/product of its framebuffer.
    struct Endpoint {
        let vendor: Int
        let product: Int
        let name: String
        let service: CFTypeRef
    }

    /// Walks the IORegistry. Each external `DCPAVServiceProxy` is preceded by the
    /// `AppleCLCD2` framebuffer node it belongs to, which carries the display's EDID identity.
    static func discover() -> [Endpoint] {
        guard let createFn else { return [] }
        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var result: [Endpoint] = []
        var vendor = 0, product = 0, name = ""
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var buf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &buf)
            let cls = String(cString: buf)

            if cls == "AppleCLCD2" || cls == "IOMobileFramebufferShim" {
                // Reset first: a framebuffer without attributes must not inherit the previous monitor's identity.
                vendor = 0; product = 0; name = ""
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let p = attrs["ProductAttributes"] as? [String: Any] {
                    vendor = (p["LegacyManufacturerID"] as? Int) ?? 0
                    product = (p["ProductID"] as? Int) ?? 0
                    name = (p["ProductName"] as? String) ?? ""
                }
            } else if cls == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let svc = createFn(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                result.append(Endpoint(vendor: vendor, product: product, name: name, service: svc))
            }
        }
        return result
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0x6E ^ 0x51, ^) }

    /// DDC "Set VCP Feature". Returns true when the I2C write was accepted.
    @discardableResult
    static func setVCP(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let writeFn else { return false }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(checksum(packet))
        for _ in 0..<3 {
            if writeFn(service, 0x37, 0x51, &packet, UInt32(packet.count)) == 0 { return true }
            usleep(20_000)
        }
        return false
    }

    /// DDC "Get VCP Feature". Returns the current and maximum value.
    static func getVCP(_ service: CFTypeRef, code: UInt8) -> (current: Int, max: Int)? {
        guard let writeFn, let readFn else { return nil }
        for _ in 0..<4 {
            var request: [UInt8] = [0x82, 0x01, code]
            request.append(checksum(request))
            guard writeFn(service, 0x37, 0x51, &request, UInt32(request.count)) == 0 else { usleep(20_000); continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard readFn(service, 0x37, 0x51, &reply, UInt32(reply.count)) == 0,
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { continue }
            let maxValue = (Int(reply[6]) << 8) | Int(reply[7])
            guard maxValue > 0 else { continue }   // a max of 0 is a bogus reply, not a usable range
            return (current: (Int(reply[8]) << 8) | Int(reply[9]), max: maxValue)
        }
        return nil
    }
}
