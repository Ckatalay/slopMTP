import Foundation
@testable import MTPKit

/// An in-memory MTP responder that behaves like a USB device at the packet level:
/// IN transfers end on short packets, and containers that fill a whole number of packets
/// are followed by a zero-length packet.
final class MockResponder: MTPTransport, @unchecked Sendable {
    struct Node {
        var parent: UInt32
        var name: String
        var isFolder: Bool
        var data: Data
    }

    let maxPacketSize: Int
    static let storageID: UInt32 = 0x0001_0001

    var nodes: [UInt32: Node] = [:]
    var nextHandle: UInt32 = 100
    var supportedOperations: [OperationCode] = [
        .getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo,
        .getObjectHandles, .getObjectInfo, .getObject, .deleteObject, .sendObjectInfo,
        .sendObject, .getObjectPropValue, .setObjectPropValue, .getObjectPropList, .getPartialObject64,
    ]
    /// Handles left out of GetObjectPropList replies, to exercise the per-object fallback.
    var omitFromPropList: Set<UInt32> = []
    private var eventHandler: (@Sendable (Data) -> Void)?
    /// Pretend this object is larger than 4 GiB in ObjectInfo, while reporting the real size via ObjectSize.
    var hugeSizeOverride: [UInt32: UInt64] = [:]

    private(set) var sessionOpen = false
    private(set) var log: [OperationCode] = []
    private(set) var zeroLengthPacketsReceived = 0

    private var inQueue: [Data] = []
    private var pendingCommand: (code: OperationCode, transactionID: UInt32, params: [UInt32])?
    private var outBuffer = Data()
    private var pendingSendObjectHandle: UInt32?

    init(maxPacketSize: Int = 512) {
        self.maxPacketSize = maxPacketSize
    }

    // MARK: - MTPTransport

    func write(_ data: Data, timeout: TimeInterval) throws {
        if data.isEmpty {
            zeroLengthPacketsReceived += 1
            return
        }
        if let pending = pendingCommand {
            outBuffer.append(data)
            let header = try PTPContainerHeader(parsing: outBuffer)
            if outBuffer.count >= Int(header.length) {
                let payload = outBuffer.dropFirst(PTPContainerHeader.size)
                outBuffer = Data()
                pendingCommand = nil
                handle(pending.code, pending.transactionID, pending.params, dataIn: Data(payload))
            }
            return
        }

        let header = try PTPContainerHeader(parsing: data)
        precondition(header.type == .command)
        let code = OperationCode(header.code)
        let params = try PTPContainer.parameters(in: data, header: header)
        log.append(code)

        if [.sendObjectInfo, .sendObject, .setObjectPropValue, .sendObjectPropList].contains(code) {
            pendingCommand = (code, header.transactionID, params)
        } else {
            handle(code, header.transactionID, params, dataIn: nil)
        }
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard !inQueue.isEmpty else { throw MTPError.timeout }
        var front = inQueue.removeFirst()
        if front.count > maxLength {
            let chunk = front.prefix(maxLength)
            front = front.dropFirst(maxLength)
            inQueue.insert(Data(front), at: 0)
            return Data(chunk)
        }
        return front
    }

    func cancelTransaction(_ transactionID: UInt32) throws {
        inQueue.removeAll()
        pendingCommand = nil
        outBuffer = Data()
    }

    func close() {}

    func startEventStream(_ handler: @escaping @Sendable (Data) -> Void) -> Bool {
        eventHandler = handler
        return true
    }

    func stopEventStream() {
        eventHandler = nil
    }

    func emit(_ code: EventCode, _ parameters: [UInt32] = []) {
        eventHandler?(PTPContainer.encode(type: .event, code: code.rawValue, transactionID: 0, parameters: parameters))
    }

    // MARK: - Responder

    private func enqueue(container: Data) {
        inQueue.append(container)
        if container.count % maxPacketSize == 0 {
            inQueue.append(Data())
        }
    }

    private func respond(_ code: ResponseCode, _ transactionID: UInt32, _ params: [UInt32] = []) {
        enqueue(container: PTPContainer.encode(type: .response, code: code.rawValue, transactionID: transactionID, parameters: params))
    }

    private func sendData(_ payload: Data, _ code: OperationCode, _ transactionID: UInt32) {
        var container = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.size + payload.count), type: .data,
            code: code.rawValue, transactionID: transactionID
        ).encoded
        container.append(payload)
        enqueue(container: container)
    }

    private func handle(_ code: OperationCode, _ tid: UInt32, _ params: [UInt32], dataIn: Data?) {
        if code != .getDeviceInfo && code != .openSession && !sessionOpen {
            respond(.sessionNotOpen, tid)
            return
        }

        switch code {
        case .getDeviceInfo:
            var w = PTPDataWriter()
            w.write(UInt16(100))
            w.write(UInt32(6))
            w.write(UInt16(100))
            w.writeString("microsoft.com: 1.0;")
            w.write(UInt16(0))
            w.writeArray(supportedOperations.map(\.rawValue))
            w.writeArray([UInt16]())
            w.writeArray([UInt16]())
            w.writeArray([UInt16]())
            w.writeArray([UInt16(0x3000), 0x3001])
            w.writeString("Nintendo")
            w.writeString("Nintendo Switch")
            w.writeString("1.0.0")
            w.writeString("SERIAL123")
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .openSession:
            if sessionOpen {
                respond(.sessionAlreadyOpen, tid)
            } else {
                sessionOpen = true
                respond(.ok, tid)
            }

        case .closeSession:
            sessionOpen = false
            respond(.ok, tid)

        case .getStorageIDs:
            var w = PTPDataWriter()
            w.writeArray([Self.storageID])
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .getStorageInfo:
            guard params.first == Self.storageID else { return respond(.invalidStorageID, tid) }
            var w = PTPDataWriter()
            w.write(UInt16(0x0004))
            w.write(UInt16(0x0002))
            w.write(UInt16(0))
            w.write(UInt64(256_000_000_000))
            w.write(UInt64(128_000_000_000))
            w.write(UInt32(0xFFFF_FFFF))
            w.writeString("SD Card")
            w.writeString("")
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .getObjectHandles:
            let parent = params[2] == MTPConstants.rootParent ? 0 : params[2]
            let handles = nodes.filter { $0.value.parent == parent }.keys.sorted()
            var w = PTPDataWriter()
            w.writeArray(handles)
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .getObjectInfo:
            guard let node = nodes[params[0]] else { return respond(.invalidObjectHandle, tid) }
            let realSize = hugeSizeOverride[params[0]] ?? UInt64(node.data.count)
            let info = ObjectInfo(
                storageID: Self.storageID,
                format: node.isFolder ? .association : .undefined,
                compressedSize: realSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(realSize),
                parentObject: node.parent,
                associationType: node.isFolder ? 1 : 0,
                filename: node.name,
                modificationDate: "20240102T030405"
            )
            sendData(info.encoded, code, tid)
            respond(.ok, tid)

        case .getObjectPropValue:
            guard let node = nodes[params[0]] else { return respond(.invalidObjectHandle, tid) }
            var w = PTPDataWriter()
            switch ObjectPropertyCode(UInt16(params[1])) {
            case .objectSize: w.write(hugeSizeOverride[params[0]] ?? UInt64(node.data.count))
            case .objectFileName: w.writeString(node.name)
            default: return respond(.invalidObjectPropCode, tid)
            }
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .setObjectPropValue:
            guard nodes[params[0]] != nil, let dataIn else { return respond(.invalidObjectHandle, tid) }
            var r = PTPDataReader(dataIn)
            nodes[params[0]]?.name = (try? r.readString()) ?? ""
            respond(.ok, tid)

        case .getObjectPropList:
            let parent = params[0] == 0 ? 0 : params[0]
            let children = nodes.filter { $0.value.parent == parent && !omitFromPropList.contains($0.key) }.sorted { $0.key < $1.key }
            var w = PTPDataWriter()
            w.write(UInt32(children.count * 6))
            for (handle, node) in children {
                func element(_ code: ObjectPropertyCode, _ type: PTPDataType) {
                    w.write(handle)
                    w.write(code.rawValue)
                    w.write(type.rawValue)
                }
                element(.storageID, .uint32); w.write(Self.storageID)
                element(.objectFormat, .uint16); w.write(node.isFolder ? ObjectFormat.association.rawValue : ObjectFormat.undefined.rawValue)
                element(.objectSize, .uint64); w.write(hugeSizeOverride[handle] ?? UInt64(node.data.count))
                element(.objectFileName, .string); w.writeString(node.name)
                element(.parentObject, .uint32); w.write(node.parent)
                // An array-typed property the parser must skip.
                w.write(handle); w.write(UInt16(0xDC03)); w.write(UInt16(0x4002)); w.writeArray([UInt8(1), 2, 3])
            }
            sendData(w.data, code, tid)
            respond(.ok, tid)

        case .getPartialObject64:
            guard let node = nodes[params[0]], !node.isFolder else { return respond(.invalidObjectHandle, tid) }
            let offset = Int(UInt64(params[1]) | UInt64(params[2]) << 32)
            let end = min(node.data.count, offset + Int(params[3]))
            sendData(offset < end ? node.data.subdata(in: offset..<end) : Data(), code, tid)
            respond(.ok, tid, [UInt32(max(0, end - offset))])

        case .getObject:
            guard let node = nodes[params[0]], !node.isFolder else { return respond(.invalidObjectHandle, tid) }
            sendData(node.data, code, tid)
            respond(.ok, tid)

        case .deleteObject:
            guard nodes.removeValue(forKey: params[0]) != nil else { return respond(.invalidObjectHandle, tid) }
            respond(.ok, tid)

        case .sendObjectInfo:
            guard let dataIn, let info = try? ObjectInfo(parsing: dataIn) else { return respond(.invalidParameter, tid) }
            let parent = params[1] == MTPConstants.rootParent ? 0 : params[1]
            let handle = nextHandle
            nextHandle += 1
            nodes[handle] = Node(parent: parent, name: info.filename, isFolder: info.isFolder, data: Data())
            pendingSendObjectHandle = info.isFolder ? nil : handle
            respond(.ok, tid, [Self.storageID, params[1], handle])

        case .sendObject:
            guard let handle = pendingSendObjectHandle, let dataIn else { return respond(.generalError, tid) }
            nodes[handle]?.data = dataIn
            pendingSendObjectHandle = nil
            respond(.ok, tid)

        default:
            respond(.operationNotSupported, tid)
        }
    }

    @discardableResult
    func addNode(parent: UInt32 = 0, name: String, isFolder: Bool = false, data: Data = Data()) -> UInt32 {
        let handle = nextHandle
        nextHandle += 1
        nodes[handle] = Node(parent: parent, name: name, isFolder: isFolder, data: data)
        return handle
    }
}
