import Foundation
import IOKit
import IOUSBHost

enum ClipError: LocalizedError {
    case notConnected
    case busy
    case interfaceNotFound
    case timeout
    case usb(String)
    case protocolError(String)
    case rejected(String)
    case verificationFailed(String)
    case diskFull

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "カメラが見つからない（USBで繋がってる？）")
        case .busy: return String(localized: "別のアプリがカメラを使用中。少し待ってからもう一度試してね")
        case .interfaceNotFound: return String(localized: "カメラのUSBインターフェースが見つからない")
        case .timeout: return String(localized: "カメラの応答がタイムアウトした")
        case .usb(let s): return String(localized: "USBエラー: \(s)")
        case .protocolError(let s): return String(localized: "通信エラー: \(s)")
        case .rejected(let s): return String(localized: "カメラに拒否された: \(s)")
        case .verificationFailed(let s): return String(localized: "照合エラー: \(s)")
        case .diskFull: return String(localized: "Macの空き容量が足りない（5GBの余裕を残す設定）")
        }
    }
}

/// Raw USB access to the Narrative Clip 2 (f0f0:cafe): vendor control requests on EP0,
/// bulk IN 0x81 for replies and bulk OUT 0x02 for command payloads.
final class USBTransport {
    static let vendorID = 0xF0F0
    static let productID = 0xCAFE
    static let configurationValue = 1
    static let bulkIn = 0x81
    static let bulkOut = 0x02
    static let chunk = 0x10000

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let readBuffer: NSMutableData

    static func deviceMatching() -> CFMutableDictionary {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber, bcdDevice: nil,
            deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    static var isConnected: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, deviceMatching())
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, Self.deviceMatching())
        guard service != 0 else { throw ClipError.notConnected }
        defer { IOObjectRelease(service) }
        let device = try Self.usb { try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil) }
        let interface: IOUSBHostInterface
        do {
            interface = try Self.openInterface(device: device)
        } catch {
            device.destroy()
            throw error
        }
        self.device = device
        self.interface = interface
        inPipe = try Self.usb { try interface.copyPipe(withAddress: Self.bulkIn) }
        outPipe = try Self.usb { try interface.copyPipe(withAddress: Self.bulkOut) }
        readBuffer = try Self.usb { try interface.ioData(withCapacity: Self.chunk) }
    }

    deinit {
        interface.destroy()
        device.destroy()
    }

    private static func openInterface(device: IOUSBHostDevice) throws -> IOUSBHostInterface {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber, bcdDevice: nil,
            interfaceNumber: 0, configurationValue: configurationValue as NSNumber,
            interfaceClass: nil, interfaceSubclass: nil, interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
        func find() -> io_service_t { IOServiceGetMatchingService(kIOMainPortDefault, matching) }

        var service = find()
        if service == 0 {
            // The camera comes up unconfigured (vendor class, no driver); select configuration 1.
            try usb { try device.__configure(withValue: configurationValue, matchInterfaces: true) }
            for _ in 0..<60 where service == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                service = find()
            }
        }
        guard service != 0 else { throw ClipError.interfaceNotFound }
        defer { IOObjectRelease(service) }
        return try usb { try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) }
    }

    /// Port-resets the camera (like unplugging it). It re-enumerates; open a new transport afterwards.
    func reset() throws {
        try Self.usb { try device.reset() }
    }

    func controlOut(request: UInt8, index: UInt16 = 0, data: Data, timeout: TimeInterval = 5) throws {
        let req = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: request, wValue: 0, wIndex: index,
                                     wLength: UInt16(data.count))
        let buffer = NSMutableData(data: data)
        var transferred = 0
        try Self.usb { try device.__send(req, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout) }
    }

    func controlIn(request: UInt8, index: UInt16 = 0, length: Int, timeout: TimeInterval = 5) throws -> Data {
        let req = IOUSBDeviceRequest(bmRequestType: 0xC0, bRequest: request, wValue: 0, wIndex: index,
                                     wLength: UInt16(length))
        let buffer = NSMutableData(length: length)!
        var transferred = 0
        try Self.usb { try device.__send(req, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout) }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    /// One bulk IN transfer of up to 64 KiB.
    func bulkRead(timeout: TimeInterval) throws -> Data {
        var transferred = 0
        try Self.usb { try inPipe.__sendIORequest(with: readBuffer, bytesTransferred: &transferred, completionTimeout: timeout) }
        return Data(bytes: readBuffer.bytes, count: transferred)
    }

    func bulkWrite(_ data: Data, timeout: TimeInterval = 30) throws {
        // The OUT endpoint can be left halted by an earlier session; writes then fail with EIO.
        try? outPipe.clearStall()
        // IOUSBHost's I/O buffers can't be resized (setLength: throws), so allocate one of the exact size.
        // If it isn't exactly the payload size, fall back to a plain NSMutableData.
        var buffer: NSMutableData = try Self.usb { try interface.ioData(withCapacity: max(data.count, 1)) }
        if buffer.length == data.count {
            data.withUnsafeBytes { buffer.replaceBytes(in: NSRange(location: 0, length: data.count), withBytes: $0.baseAddress!) }
        } else {
            buffer = NSMutableData(data: data)
        }
        var transferred = 0
        try Self.usb { try outPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout) }
    }

    /// Discards anything left in the bulk IN pipe so the next reply isn't read out of step.
    func drain() {
        for _ in 0..<1000 {
            do { _ = try bulkRead(timeout: 0.1) } catch { return }
        }
    }

    private static func usb<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError {
            let code = IOReturn(truncatingIfNeeded: error.code)
            if code == kIOReturnTimeout { throw ClipError.timeout }
            if code == kIOReturnExclusiveAccess || code == kIOReturnNotPermitted { throw ClipError.busy }
            throw ClipError.usb("\(error.localizedDescription) (0x\(String(UInt32(truncatingIfNeeded: error.code), radix: 16)))")
        }
    }
}
