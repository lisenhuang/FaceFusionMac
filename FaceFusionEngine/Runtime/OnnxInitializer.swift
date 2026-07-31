//
//  OnnxInitializer.swift
//  FaceFusionEngine
//
//  The inswapper graph carries a 512x512 matrix ("emap") as its last graph
//  initializer. The source identity embedding has to be projected through that
//  matrix before the model will accept it, and ONNX Runtime offers no way to
//  read a graph initializer back out. So we read it straight from the file.
//
//  Rather than pull in a protobuf dependency, this walks just the handful of
//  protobuf fields we need. The file is memory-mapped, so the multi-hundred-MB
//  weight blobs are skipped over without ever being paged in.
//
//  Relevant schema (onnx.proto):
//    ModelProto.graph        = field 7  (message)
//    GraphProto.initializer  = field 5  (repeated TensorProto)
//    TensorProto.dims        = field 1  (repeated int64, possibly packed)
//    TensorProto.data_type   = field 2  (enum/varint)
//    TensorProto.float_data  = field 4  (repeated float, packed)
//    TensorProto.name        = field 8  (string)
//    TensorProto.raw_data    = field 9  (bytes)
//

import Foundation

struct OnnxTensor {
    var name: String
    var dims: [Int]
    /// ONNX TensorProto.DataType — 1 = FLOAT, 10 = FLOAT16.
    var dataType: Int
    var floats: [Float]
}

enum OnnxInitializerReader {

    /// Reads the final graph initializer, which for inswapper is `emap`.
    static func lastInitializer(ofModelAt url: URL) throws -> OnnxTensor {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try data.withUnsafeBytes { raw -> OnnxTensor in
            guard let base = raw.baseAddress else {
                throw makeEngineNSError(.modelLoadFailed, underlying: "empty model file")
            }
            let buf = UnsafeRawBufferPointer(start: base, count: raw.count)

            // ModelProto -> graph (field 7)
            var graphSpan: Range<Int>?
            var cursor = Reader(buf: buf, index: 0, end: buf.count)
            while let field = try cursor.nextField() {
                if field.number == 7, case .lengthDelimited(let range) = field.payload {
                    graphSpan = range
                }
            }
            guard let graphSpan else {
                throw makeEngineNSError(.modelLoadFailed, underlying: "no GraphProto in model")
            }

            // GraphProto -> initializer (field 5), keep only the last one.
            var lastInit: Range<Int>?
            var graphCursor = Reader(buf: buf, index: graphSpan.lowerBound, end: graphSpan.upperBound)
            while let field = try graphCursor.nextField() {
                if field.number == 5, case .lengthDelimited(let range) = field.payload {
                    lastInit = range
                }
            }
            guard let lastInit else {
                throw makeEngineNSError(.modelLoadFailed, underlying: "graph has no initializers")
            }
            return try parseTensor(buf: buf, span: lastInit)
        }
    }

    private static func parseTensor(buf: UnsafeRawBufferPointer,
                                    span: Range<Int>) throws -> OnnxTensor {
        var name = ""
        var dims: [Int] = []
        var dataType = 0
        var rawData: Range<Int>?
        var packedFloats: Range<Int>?

        var cursor = Reader(buf: buf, index: span.lowerBound, end: span.upperBound)
        while let field = try cursor.nextField() {
            switch (field.number, field.payload) {
            case (1, .varint(let v)):
                dims.append(Int(v))
            case (1, .lengthDelimited(let r)):           // packed dims
                var packed = Reader(buf: buf, index: r.lowerBound, end: r.upperBound)
                while packed.index < packed.end { dims.append(Int(try packed.varint())) }
            case (2, .varint(let v)):
                dataType = Int(v)
            case (4, .lengthDelimited(let r)):
                packedFloats = r
            case (8, .lengthDelimited(let r)):
                name = String(decoding: UnsafeRawBufferPointer(rebasing: buf[r]), as: UTF8.self)
            case (9, .lengthDelimited(let r)):
                rawData = r
            default:
                break
            }
        }

        let count = dims.reduce(1, *)
        var floats = [Float]()

        if let rawData {
            switch dataType {
            case 1:  // FLOAT32
                let expected = count * MemoryLayout<Float>.size
                guard rawData.count >= expected else {
                    throw makeEngineNSError(.modelLoadFailed,
                                            underlying: "initializer raw_data too short (\(rawData.count) < \(expected))")
                }
                floats = [Float](unsafeUninitializedCapacity: count) { dst, initialized in
                    // raw_data has no alignment guarantee inside the file.
                    memcpy(dst.baseAddress!, buf.baseAddress! + rawData.lowerBound, expected)
                    initialized = count
                }
            case 10: // FLOAT16
                let expected = count * 2
                guard rawData.count >= expected else {
                    throw makeEngineNSError(.modelLoadFailed, underlying: "initializer raw_data too short")
                }
                var halves = [UInt16](repeating: 0, count: count)
                halves.withUnsafeMutableBytes {
                    _ = memcpy($0.baseAddress!, buf.baseAddress! + rawData.lowerBound, expected)
                }
                floats = halves.map { Float(float16Bits: $0) }
            default:
                throw makeEngineNSError(.modelLoadFailed,
                                        underlying: "unsupported initializer dtype \(dataType)")
            }
        } else if let packedFloats {
            let n = packedFloats.count / MemoryLayout<Float>.size
            floats = [Float](unsafeUninitializedCapacity: n) { dst, initialized in
                memcpy(dst.baseAddress!, buf.baseAddress! + packedFloats.lowerBound,
                       n * MemoryLayout<Float>.size)
                initialized = n
            }
        } else {
            throw makeEngineNSError(.modelLoadFailed, underlying: "initializer carries no data")
        }

        return OnnxTensor(name: name, dims: dims, dataType: dataType, floats: floats)
    }

    // MARK: - Minimal protobuf wire reader

    private struct Reader {
        let buf: UnsafeRawBufferPointer
        var index: Int
        let end: Int

        enum Payload {
            case varint(UInt64)
            case lengthDelimited(Range<Int>)
            case fixed(Range<Int>)
        }
        struct Field {
            var number: Int
            var payload: Payload
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < end {
                let byte = buf[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 {
                    throw makeEngineNSError(.modelLoadFailed, underlying: "varint overflow")
                }
            }
            throw makeEngineNSError(.modelLoadFailed, underlying: "truncated varint")
        }

        mutating func nextField() throws -> Field? {
            guard index < end else { return nil }
            let key = try varint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                return Field(number: number, payload: .varint(try varint()))
            case 1:
                guard index + 8 <= end else { throw truncated() }
                defer { index += 8 }
                return Field(number: number, payload: .fixed(index ..< index + 8))
            case 2:
                let length = Int(try varint())
                guard length >= 0, index + length <= end else { throw truncated() }
                defer { index += length }
                return Field(number: number, payload: .lengthDelimited(index ..< index + length))
            case 5:
                guard index + 4 <= end else { throw truncated() }
                defer { index += 4 }
                return Field(number: number, payload: .fixed(index ..< index + 4))
            default:
                throw makeEngineNSError(.modelLoadFailed, underlying: "unsupported wire type")
            }
        }

        private func truncated() -> NSError {
            makeEngineNSError(.modelLoadFailed, underlying: "truncated protobuf field")
        }
    }
}
