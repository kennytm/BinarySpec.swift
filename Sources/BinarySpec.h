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

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <fcntl.h>

FOUNDATION_EXPORT double BinarySpecVersionNumber;

FOUNDATION_EXPORT const unsigned char BinarySpecVersionString[];

/// Creates a non-blocking socket.
///
/// This is a C function because `fcntl()` cannot be exported to Swift yet.
static inline int BinarySpec_createNonBlockingSocket(int family, int type) {
    int sck = socket(family, type, 0);
    if (sck < 0) {
        return -1;
    }

    int res = fcntl(sck, F_SETFL, O_NONBLOCK | fcntl(sck, F_GETFL));
    if (res < 0) {
        close(sck);
        return -1;
    }

    int yes = 1;
    setsockopt(sck, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(sck, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

    return sck;
}

static inline int fcntl0(int fd, int option) {
    return fcntl(fd, option);
}

static inline int fcntl1(int fd, int option, int value) {
    return fcntl(fd, option, value);
}
