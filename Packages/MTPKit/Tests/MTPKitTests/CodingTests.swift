import Foundation
import Testing
@testable import MTPKit

@Suite struct CodingTests {
    @Test func integersAreLittleEndian() throws {
        var w = PTPDataWriter()
        w.write(UInt16(0x1234))
        w.write(UInt32(0xAABB_CCDD))
        w.write(UInt64(0x0102_0304_0506_0708))
        #expect([UInt8](w.data) == [0x34, 0x12, 0xDD, 0xCC, 0xBB, 0xAA, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])

        var r = PTPDataReader(w.data)
        #expect(try r.read(UInt16.self) == 0x1234)
        #expect(try r.read(UInt32.self) == 0xAABB_CCDD)
        #expect(try r.read(UInt64.self) == 0x0102_0304_0506_0708)
        #expect(r.isAtEnd)
    }

    @Test func stringsRoundTrip() throws {
        for value in ["", "a", "Zelda — Tears of the Kingdom [0100F2C0115B6000].nsp", "日本語ファイル"] {
            var w = PTPDataWriter()
            w.writeString(value)
            var r = PTPDataReader(w.data)
            #expect(try r.readString() == value)
            #expect(r.isAtEnd)
        }
    }

    @Test func stringEncodingIncludesTerminator() {
        var w = PTPDataWriter()
        w.writeString("AB")
        #expect([UInt8](w.data) == [3, 0x41, 0, 0x42, 0, 0, 0])
    }

    @Test func truncatedDataThrows() {
        var r = PTPDataReader(Data([0x01, 0x02]))
        #expect(throws: MTPError.self) { try r.read(UInt32.self) }
    }

    @Test func commandContainerLayout() throws {
        let data = PTPContainer.encode(type: .command, code: 0x1007, transactionID: 5, parameters: [0x0001_0001, 0, 0xFFFF_FFFF])
        #expect(data.count == 24)
        let header = try PTPContainerHeader(parsing: data)
        #expect(header == PTPContainerHeader(length: 24, type: .command, code: 0x1007, transactionID: 5))
        #expect(try PTPContainer.parameters(in: data, header: header) == [0x0001_0001, 0, 0xFFFF_FFFF])
    }

    @Test func objectInfoRoundTrip() throws {
        let info = ObjectInfo(
            storageID: 0x0001_0001, format: .association, compressedSize: 0,
            parentObject: 7, associationType: 1, filename: "Saves", modificationDate: "20240102T030405"
        )
        let parsed = try ObjectInfo(parsing: info.encoded)
        #expect(parsed == info)
        #expect(parsed.isFolder)
    }

    @Test func parsesPTPDates() throws {
        let utc = try #require(PTPDate.parse("20240102T030405Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utc)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2024, 1, 2, 3, 4, 5])

        let offset = try #require(PTPDate.parse("20240102T030405.0+0200"))
        #expect(utc.timeIntervalSince(offset) == 7200)
        #expect(PTPDate.parse("garbage") == nil)
        #expect(PTPDate.parse("19700101T000000") == nil)
    }
}

@Suite struct USBTransportTests {
    @Test func parsesExclusiveOwner() throws {
        let owner = try #require(USBTransport.parseExclusiveOwner("pid 24197, ptpcamerad"))
        #expect(owner.pid == 24197)
        #expect(owner.name == "ptpcamerad")
        #expect(USBTransport.parseExclusiveOwner("garbage") == nil)
    }
}
