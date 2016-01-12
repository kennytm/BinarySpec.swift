import BinarySpec

private func dataFromHexString(string: String) -> [UInt8] {
    var range = string.startIndex ..< string.endIndex
    var data = [UInt8]()
    data.reserveCapacity(range.count / 2)
    while !range.isEmpty {
        guard let nextRange = string.rangeOfString("[0-9a-fA-F]{2}", options: .RegularExpressionSearch, range: range, locale: nil) else {
            break
        }
        range = nextRange.endIndex ..< string.endIndex

        let hexRep = string.substringWithRange(nextRange)
        let byte = UInt8(hexRep, radix: 16)!
        data.append(byte)
    }
    return data
}

// To run this playground, please first build the `BinarySpec-OSX` target.

let spec = BinarySpec(parse: ">%Is")
let parser = BinaryParser(spec)

let bytes = dataFromHexString("00 00 00 04 ab cd ef ff")

parser.supply(bytes)

print(parser.parseAll())
