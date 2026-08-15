import Foundation
import Darwin

public struct PortProbe {
    public init() {}

    public func canConnect(host: String, port: Int, timeout: TimeInterval = 1.0) -> Bool {
        guard (1...65535).contains(port), timeout > 0 else { return false }
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: Int32(IPPROTO_TCP),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }

        let timeoutNanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                let originalFlags = fcntl(fd, F_GETFL, 0)
                guard originalFlags >= 0,
                      fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                    close(fd)
                    current = info.ai_next
                    continue
                }
                let status = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
                if status == 0 {
                    close(fd)
                    return true
                }
                if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    var pollStatus: Int32 = -1
                    repeat {
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard now < deadline else { break }
                        let remaining = max(UInt64(1), (deadline - now) / 1_000_000)
                        let remainingMilliseconds = Int32(min(UInt64(Int32.max), remaining))
                        pollStatus = Darwin.poll(&descriptor, 1, remainingMilliseconds)
                    } while pollStatus < 0 && errno == EINTR

                    if pollStatus > 0 {
                        var socketError: Int32 = 0
                        var errorLength = socklen_t(MemoryLayout<Int32>.size)
                        let optionStatus = withUnsafeMutablePointer(to: &socketError) {
                            getsockopt(fd, SOL_SOCKET, SO_ERROR, $0, &errorLength)
                        }
                        if optionStatus == 0 && socketError == 0 {
                            close(fd)
                            return true
                        }
                    }
                }
                close(fd)
            }
            current = info.ai_next
        }
        return false
    }
}
