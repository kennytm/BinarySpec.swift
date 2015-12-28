/*

Copyright 2015 HiHex Ltd.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in
compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied. See the License for the specific language governing permissions and limitations under the
License.

*/

private enum BinarySpecToken {
    case Number(UIntMax)
    case IntegerType(Int) // B, H, T, I, Q
    case Skip // x
    case Bytes // s
    case Variable // %
    case UntilStart // (
    case UntilEnd // )
    case SwitchStart // {
    case SwitchEnd // }
    case Equals // =
    case Star // *
    case Comma // ,
    case Plus // +
    case Minus // -
    case Endian(Int) // <, >
}

private class BinarySpecTokenizer {
    private enum State {
        case None
        case Zero
        case ZeroX
        case Hexadecimal(UIntMax)
        case Decimal(UIntMax)
    }

    private var state = State.None
    private let tokenizer: BinarySpecToken -> ()

    private func resetState() {
        switch state {
        case .None:
            break
        case .Zero:
            tokenizer(.Number(0))
        case .ZeroX:
            tokenizer(.Number(0))
            tokenizer(.Skip)
        case let .Hexadecimal(a):
            tokenizer(.Number(a))
        case let .Decimal(a):
            tokenizer(.Number(a))
        }
        state = .None
    }

    private func parseChar(c: UTF8Char) {
        var token: BinarySpecToken

        switch c {
        case 0x48, 0x68: // H
            token = .IntegerType(2)
        case 0x54, 0x74: // T
            token = .IntegerType(3)
        case 0x49, 0x69: // I
            token = .IntegerType(4)
        case 0x51, 0x71: // Q
            token = .IntegerType(8)
        case 0x58, 0x78: // X
            if case .Zero = state {
                state = .ZeroX
                return
            } else {
                token = .Skip
            }
        case 0x53, 0x73: // S
            token = .Bytes
        case 0x25: // %
            token = .Variable
        case 0x28: // (
            token = .UntilStart
        case 0x29: // )
            token = .UntilEnd
        case 0x7b: // {
            token = .SwitchStart
        case 0x7d: // }
            token = .SwitchEnd
        case 0x3d: // =
            token = .Equals
        case 0x2a: // *
            token = .Star
        case 0x3c: // <
            token = .Endian(NS_LittleEndian)
        case 0x3e: // >
            token = .Endian(NS_BigEndian)
        case 0x2c: // ,
            token = .Comma
        case 0x2b: // +
            token = .Plus
        case 0x2d: // -
            token = .Minus

        case 0x30 ... 0x39: // 0 ~ 9
            let digit = UIntMax(c - 0x30)
            switch state {
            case .None:
                state = digit == 0 ? .Zero : .Decimal(digit)
            case .Zero:
                state = .Decimal(digit)
            case .ZeroX:
                state = .Hexadecimal(digit)
            case let .Decimal(a):
                state = .Decimal(10*a + digit)
            case let .Hexadecimal(a):
                state = .Hexadecimal(16*a + digit)
            }
            return

        case 0x41 ... 0x46, 0x61 ... 0x66: // A ~ F
            let digit = UIntMax((c & ~0x20) - 0x41 + 10)
            switch state {
            case .ZeroX:
                state = .Hexadecimal(digit)
            case let .Hexadecimal(a):
                state = .Hexadecimal(16*a + digit)
            default:
                resetState()
                if digit == 0xb {
                    tokenizer(.IntegerType(1))
                }
            }
            return

        default:
            resetState()
            return
        }

        resetState()
        tokenizer(token)
    }

    private init(_ tokenizer: BinarySpecToken -> ()) {
        self.tokenizer = tokenizer
    }

    private func parse(input: String) {
        input.utf8.forEach(self.parseChar)
    }
}

internal class BinarySpecParser {
    private struct State {
        var specs: [BinarySpec] = []
        var curCase: UIntMax? = nil
    }

    private var variableNames = 0 ..< 0
    private var endian = NS_LittleEndian
    private var states = [State()]
    private var currentNumber: UIntMax = 1
    private var nextIntegerTypeIsVariable = false
    private var nextCaseIsDefault = false
    private let variablePrefix: String
    private var variableOffsetDirection = 0

    private func provideVariable() -> String {
        let index = variableNames.endIndex
        variableNames = variableNames.startIndex ... variableNames.endIndex
        return "\(variablePrefix)\(index)"
    }

    private func consumeVariable() -> String {
        let index = variableNames.startIndex
        variableNames = variableNames.startIndex.successor() ..< variableNames.endIndex
        return "\(variablePrefix)\(index)"
    }

    private func consumeCurrentNumber() -> UIntMax {
        let number = currentNumber
        currentNumber = 1
        return number
    }

    private func appendToSeq(spec: BinarySpec) {
        states[states.endIndex.predecessor()].specs.append(spec)
    }

    private func extendToSeq<S: SequenceType where S.Generator.Element == BinarySpec>(specs: S) {
        states[states.endIndex.predecessor()].specs += specs
    }

    private func modifyLastSpec(modifier: BinarySpec -> BinarySpec) {
        withUnsafeMutablePointer(&states[states.endIndex.predecessor()]) {
            withUnsafeMutablePointer(&$0.memory.specs[$0.memory.specs.endIndex.predecessor()]) {
                $0.memory = modifier($0.memory)
            }
        }
    }

    private static func combineSpecs(specs: [BinarySpec]) -> BinarySpec {
        switch specs.count {
        case 0:
            return .Skip(0)
        case 1:
            return specs[0]
        default:
            return .Seq(specs)
        }
    }

    private func popState(modifier: (BinarySpec, BinarySpec, UIntMax?) -> BinarySpec) {
        let lastState = states.removeLast()
        let poppedSpec = BinarySpecParser.combineSpecs(lastState.specs)
        let lastStateIndex = states.endIndex.predecessor()
        let lastSpecIndex = states[lastStateIndex].specs.endIndex.predecessor()
        let newSpec = modifier(states[lastStateIndex].specs[lastSpecIndex], poppedSpec, lastState.curCase)
        states[lastStateIndex].specs[lastSpecIndex] = newSpec
    }

    private func popToSwitch() {
        popState { sw, newSpec, caseNum in
            guard case let .Switch(sel, cases, def) = sw else { fatalError() }
            if let cn = caseNum {
                var modifiedCases = cases
                modifiedCases[cn] = newSpec
                return .Switch(selector: sel, cases: modifiedCases, `default`: def)
            } else {
                return .Switch(selector: sel, cases: cases, `default`: newSpec)
            }
        }
    }

    private func parseToken(token: BinarySpecToken) {
        switch token {
        case let .Number(a):
            precondition(!nextIntegerTypeIsVariable || variableOffsetDirection != 0, "expected integer type after '%'")
            currentNumber = a

        case let .IntegerType(a):
            let intSpec = a > 1 ? IntSpec(length: a, endian: endian) : .Byte
            if nextIntegerTypeIsVariable {
                nextIntegerTypeIsVariable = false
                let variableName = provideVariable()
                let offset: IntMax
                switch variableOffsetDirection {
                case 1:
                    offset = IntMax(bitPattern: currentNumber)
                case -1:
                    offset = -IntMax(bitPattern: currentNumber)
                default:
                    offset = 0
                }
                appendToSeq(.Variable(intSpec, variableName, offset: offset))
                variableOffsetDirection = 0
            } else {
                let count = Int(consumeCurrentNumber())
                let specs = Repeat(count: count, repeatedValue: BinarySpec.Integer(intSpec))
                extendToSeq(specs)
            }

        case .Skip:
            let count = Int(consumeCurrentNumber())
            appendToSeq(.Skip(count))

        case .Bytes:
            let variableName = consumeVariable()
            appendToSeq(.Bytes(variableName))

        case .Variable:
            precondition(currentNumber == 1, "unexpected '%' after number")
            nextIntegerTypeIsVariable = true

        case let .Endian(a):
            endian = a

        case .UntilStart:
            let variableName = consumeVariable()
            appendToSeq(.Until(variableName, .Stop))
            states.append(State())

        case .UntilEnd:
            popState { sp, newSpec, _ in
                guard case let .Until(a, .Stop) = sp else { fatalError() }
                return .Until(a, newSpec)
            }

        case .SwitchStart:
            let variableName = consumeVariable()
            appendToSeq(.Switch(selector: variableName, cases: [:], `default`: .Stop))
            states.append(State())

        case .SwitchEnd:
            popToSwitch()

        case .Equals:
            states[states.endIndex.predecessor()].curCase = nextCaseIsDefault ? nil : consumeCurrentNumber()
            nextCaseIsDefault = false

        case .Star:
            nextCaseIsDefault = true

        case .Comma:
            popToSwitch()
            states.append(State())

        case .Plus:
            variableOffsetDirection = 1

        case .Minus:
            variableOffsetDirection = -1
        }
    }

    internal init(variablePrefix: String) {
        self.variablePrefix = variablePrefix
    }

    internal func parse(s: String) {
        let tokenizer = BinarySpecTokenizer(self.parseToken)
        tokenizer.parse(s)
    }

    internal var spec: BinarySpec {
        return BinarySpecParser.combineSpecs(states[0].specs)
    }
}
