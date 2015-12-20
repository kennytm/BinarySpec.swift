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

// See http://stackoverflow.com/a/4948967/ for how this number is chosen.
#if arch(x86_64) || arch(arm64)
    private let HASH_MAGIC = -0x61c8864680b583eb
#else
    private let HASH_MAGIC = -0x61c88647
#endif

infix operator |+> {
    associativity left
    precedence 140
}

/// Combine two hash values. The algorithm is the same as `boost::hash_combine`.
internal func |+><T: Hashable>(seed: Int, obj: T) -> Int {
    return seed ^ (obj.hashValue &+ HASH_MAGIC &+ (seed << 6) &+ (seed >> 2))
}
