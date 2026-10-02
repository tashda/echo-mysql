#if canImport(CMariaDB)
internal import CMariaDB
#else
internal import CMariaDBSystem
#endif
import Foundation

/// What `LOAD DATA LOCAL INFILE` may read (decision D17): only the data given to
/// ``MDBConnection/loadLocal(_:name:data:)`` for that statement, never a file. A server that asks
/// for any other name is refused, so a hostile server cannot read the Mac's files.
final class MDBLocalInfileSlot {
    var name: String?
    var data = Data()
    var offset = 0
    var refusal: String?
}

extension MDBConnection {
    /// Replaces Connector/C's file-reading handler with one that serves only the slot's data.
    func installLocalInfileHandler() {
        guard let handle else { return }
        mysql_set_local_infile_handler(
            handle, mdbLocalInfileInit, mdbLocalInfileRead, mdbLocalInfileEnd, mdbLocalInfileError,
            Unmanaged.passUnretained(localInfile).toOpaque()
        )
    }

    /// Runs a `LOAD DATA LOCAL INFILE '<name>' …` statement, serving `data` as that file. The
    /// connection must have been opened with `allowLocalInfile`.
    public func loadLocal(_ sql: String, name: String, data: Data) async throws -> MDBCommandResult {
        localInfile.name = name
        localInfile.data = data
        localInfile.offset = 0
        localInfile.refusal = nil
        defer {
            localInfile.name = nil
            localInfile.data = Data()
        }
        let events = try await execute(sql)
        for case .done(let result) in events { return result }
        throw MDBError(.server, message: "LOAD DATA returned no result.")
    }
}

private func mdbLocalInfileSlot(_ pointer: UnsafeMutableRawPointer?) -> MDBLocalInfileSlot? {
    pointer.map { Unmanaged<MDBLocalInfileSlot>.fromOpaque($0).takeUnretainedValue() }
}

private func mdbLocalInfileInit(
    _ info: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ filename: UnsafePointer<CChar>?,
    _ userdata: UnsafeMutableRawPointer?
) -> Int32 {
    info?.pointee = userdata
    guard let slot = mdbLocalInfileSlot(userdata) else { return 1 }
    let requested = filename.map { String(cString: $0) }
    guard let name = slot.name, requested == name else {
        slot.refusal = "Echo only sends the data of its own imports; the server asked for \(requested ?? "a file")."
        return 1
    }
    slot.offset = 0
    return 0
}

private func mdbLocalInfileRead(_ info: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> Int32 {
    guard let slot = mdbLocalInfileSlot(info), let buffer else { return -1 }
    let count = min(Int(length), slot.data.count - slot.offset)
    guard count > 0 else { return 0 }
    slot.data.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress {
            UnsafeMutableRawPointer(buffer).copyMemory(from: base + slot.offset, byteCount: count)
        }
    }
    slot.offset += count
    return Int32(count)
}

private func mdbLocalInfileEnd(_ info: UnsafeMutableRawPointer?) {}

private func mdbLocalInfileError(_ info: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> Int32 {
    let message = mdbLocalInfileSlot(info)?.refusal ?? "The import data could not be read."
    if let buffer, length > 0 {
        let bytes = Array(message.utf8.prefix(Int(length) - 1))
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { UnsafeMutableRawPointer(buffer).copyMemory(from: base, byteCount: bytes.count) }
        }
        buffer[bytes.count] = 0
    }
    return 2000 // CR_UNKNOWN_ERROR
}
