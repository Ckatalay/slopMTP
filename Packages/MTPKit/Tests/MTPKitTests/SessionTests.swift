import Foundation
import Testing
@testable import MTPKit

@Suite struct SessionTests {
    static let mebibyte: Int = 1 << 20
    static let downloadSizes: [Int] = [0, 1, 500, 500 + 12, 1012, 1536, mebibyte - 12, mebibyte, 2 * mebibyte + 77]
    static let uploadSizes: [Int] = [0, 100, 500, 1012, mebibyte - 12, mebibyte + 5000]

    func makeSession(_ responder: MockResponder = MockResponder()) async throws -> (MTPSession, MockResponder) {
        let session = MTPSession(transport: responder)
        try await session.open()
        return (session, responder)
    }

    func temporaryURL(_ name: String = "file.bin") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MTPKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    @Test func opensSessionAndReadsDeviceInfo() async throws {
        let (session, responder) = try await makeSession()
        let info = try #require(await session.deviceInfo)
        #expect(info.manufacturer == "Nintendo")
        #expect(info.model == "Nintendo Switch")
        #expect(info.serialNumber == "SERIAL123")
        #expect(info.supports(.sendObject))
        #expect(responder.sessionOpen)
    }

    @Test func recoversFromStaleSession() async throws {
        let responder = MockResponder()
        _ = try await makeSession(responder)
        // A second client opening while the session is still open must close and reopen.
        let session = MTPSession(transport: responder)
        try await session.open()
        #expect(await session.sessionID == 1)
        #expect(responder.log.suffix(3) == [.openSession, .closeSession, .openSession])
    }

    @Test func reopensSession() async throws {
        let (session, responder) = try await makeSession()
        try await session.reopenSession()
        #expect(responder.log.suffix(2) == [.closeSession, .openSession])
        #expect(try await session.storageIDs() == [MockResponder.storageID])
    }

    @Test func listsStoragesAndContents() async throws {
        let responder = MockResponder()
        let folder = responder.addNode(name: "Games", isFolder: true)
        responder.addNode(parent: folder, name: "game.nsp", data: Data(repeating: 1, count: 1000))
        responder.addNode(name: "readme.txt", data: Data("hi".utf8))
        let (session, _) = try await makeSession(responder)

        let storages = try await session.storages()
        #expect(storages.count == 1)
        #expect(storages[0].info.displayName == "SD Card")
        #expect(storages[0].info.freeSpaceInBytes == 128_000_000_000)

        let root = try await session.contents(storageID: MockResponder.storageID)
        #expect(Set(root.map(\.name)) == ["Games", "readme.txt"])
        #expect(root.first { $0.name == "Games" }?.isFolder == true)

        let children = try await session.contents(storageID: MockResponder.storageID, parent: folder)
        #expect(children.map(\.name) == ["game.nsp"])
        #expect(children[0].size == 1000)
        #expect(children[0].modified != nil)
    }

    @Test func reportsSixtyFourBitSizes() async throws {
        let responder = MockResponder()
        let handle = responder.addNode(name: "huge.xci", data: Data([1]))
        responder.hugeSizeOverride[handle] = 6_000_000_000
        let (session, _) = try await makeSession(responder)
        let object = try await session.object(handle)
        #expect(object.size == 6_000_000_000)
    }

    /// Payload sizes chosen so data containers land exactly on packet and transfer boundaries.
    @Test(arguments: SessionTests.downloadSizes)
    func downloadsExactBytes(size: Int) async throws {
        let responder = MockResponder()
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let handle = responder.addNode(name: "file.bin", data: payload)
        let (session, _) = try await makeSession(responder)

        let object = try await session.object(handle)
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let progress = ProgressRecorder()
        try await session.download(object, to: url, progress: { done, total in progress.record(done, total) })
        #expect(try Data(contentsOf: url) == payload)
        #expect(progress.last?.0 == UInt64(size))

        // The session must still be in sync after the zero-length packet edge cases.
        #expect(try await session.storageIDs() == [MockResponder.storageID])
    }

    @Test(arguments: SessionTests.uploadSizes)
    func uploadsExactBytes(size: Int) async throws {
        let responder = MockResponder()
        let folder = responder.addNode(name: "Upload", isFolder: true)
        let (session, _) = try await makeSession(responder)

        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let url = try temporaryURL("upload.bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let zlpBefore = responder.zeroLengthPacketsReceived
        let handle = try await session.upload(url, storageID: MockResponder.storageID, parent: folder)
        let node = try #require(responder.nodes[handle])
        #expect(node.data == payload)
        #expect(node.parent == folder)
        #expect(node.name == "upload.bin")

        let expectZLP = (12 + size) % responder.maxPacketSize == 0
        #expect((responder.zeroLengthPacketsReceived - zlpBefore > 0) == expectZLP)
    }

    @Test func listsLargeFoldersWithPropList() async throws {
        let responder = MockResponder()
        let folder = responder.addNode(name: "Album", isFolder: true)
        for index in 0..<10 {
            responder.addNode(parent: folder, name: "shot\(index).jpg", data: Data(repeating: UInt8(index), count: 100 + index))
        }
        let (session, _) = try await makeSession(responder)
        let before = responder.log.count
        let items = try await session.contents(storageID: MockResponder.storageID, parent: folder)
        let used = responder.log[before...]
        #expect(items.count == 10)
        #expect(items.map(\.size) == (0..<10).map { UInt64(100 + $0) })
        #expect(used.contains(.getObjectPropList))
        #expect(!used.contains(.getObjectInfo))
    }

    @Test func fallsBackForObjectsMissingFromPropList() async throws {
        let responder = MockResponder()
        var handles: [UInt32] = []
        for index in 0..<6 {
            handles.append(responder.addNode(name: "file\(index).bin", data: Data(count: index)))
        }
        responder.omitFromPropList = [handles[2]]
        let (session, _) = try await makeSession(responder)
        let before = responder.log.count
        let items = try await session.contents(storageID: MockResponder.storageID)
        #expect(items.map(\.name) == (0..<6).map { "file\($0).bin" })
        #expect(responder.log[before...].filter { $0 == .getObjectInfo }.count == 1)
    }

    @Test func resumesInterruptedDownloads() async throws {
        let responder = MockResponder()
        let payload = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let handle = responder.addNode(name: "game.nsp", data: payload)
        let (session, _) = try await makeSession(responder)
        let object = try await session.object(handle)

        let url = try temporaryURL("game.nsp")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Simulate an earlier attempt that stopped after 1 MiB.
        let part = PartialDownload.partURL(for: url)
        try payload.prefix(1 << 20).write(to: part)
        PartialDownload.writeTag(PartialDownload.tag(for: object), to: part)

        let before = responder.log.count
        try await session.download(object, to: url)
        #expect(try Data(contentsOf: url) == payload)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(responder.log[before...].contains(.getPartialObject64))
        #expect(!responder.log[before...].contains(.getObject))
    }

    @Test func restartsWhenPartialFileIsFromAnotherObject() async throws {
        let responder = MockResponder()
        let payload = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        let handle = responder.addNode(name: "a.bin", data: payload)
        let (session, _) = try await makeSession(responder)
        let object = try await session.object(handle)

        let url = try temporaryURL("a.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let part = PartialDownload.partURL(for: url)
        try Data(repeating: 0xFF, count: 1000).write(to: part)
        PartialDownload.writeTag("something else", to: part)

        try await session.download(object, to: url)
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func readsPartialData() async throws {
        let responder = MockResponder()
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let handle = responder.addNode(name: "shot.jpg", data: payload)
        let (session, _) = try await makeSession(responder)
        #expect(try await session.partialData(of: handle, count: 4096) == payload.prefix(4096))
        #expect(try await session.partialData(of: handle, offset: 9000, count: 4096) == payload.suffix(1000))
    }

    @Test func deliversDeviceEvents() async throws {
        let (session, responder) = try await makeSession()
        let stream = session.events()
        responder.emit(.objectAdded, [42])
        responder.emit(.storageInfoChanged, [MockResponder.storageID])
        var received: [PTPEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received.map(\.eventCode) == [.objectAdded, .storageInfoChanged])
        #expect(received[0].parameters == [42])
    }

    @Test func createsRenamesAndDeletes() async throws {
        let (session, responder) = try await makeSession()
        let folder = try await session.createFolder(name: "Backups", storageID: MockResponder.storageID)
        #expect(responder.nodes[folder]?.isFolder == true)
        #expect(responder.nodes[folder]?.parent == 0)

        try await session.rename(folder, to: "Backups 2024")
        #expect(responder.nodes[folder]?.name == "Backups 2024")

        try await session.delete(folder)
        #expect(responder.nodes[folder] == nil)
    }

    @Test func surfacesDeviceErrors() async throws {
        let (session, _) = try await makeSession()
        await #expect(throws: MTPError.response(.invalidObjectHandle, operation: .getObjectInfo)) {
            try await session.objectInfo(9999)
        }
        // A failed transaction must not desynchronize the session.
        #expect(try await session.storageIDs().count == 1)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UInt64, UInt64)] = []

    func record(_ done: UInt64, _ total: UInt64) {
        lock.withLock { values.append((done, total)) }
    }

    var last: (UInt64, UInt64)? { lock.withLock { values.last } }
}
