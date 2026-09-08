import Darwin
import Foundation

/// Reads process arguments and listening sockets straight from the kernel. Replaces shelling out
/// to `lsof`, which cost a subprocess per refresh and returned hundreds of unusable ports.
enum ProcessInspector {
    struct Match: Sendable {
        let pid: pid_t
        let arguments: [String]

        func value(forFlag flag: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == flag, index + 1 < arguments.count {
                    return arguments[index + 1]
                }
                if argument.hasPrefix("\(flag)=") {
                    return String(argument.dropFirst(flag.count + 1))
                }
            }
            return nil
        }
    }

    /// First process whose executable path contains every fragment in `pathFragments`.
    static func firstProcess(matchingPathFragments pathFragments: [String]) -> Match? {
        for pid in currentPIDs() {
            guard let path = executablePath(of: pid),
                  pathFragments.allSatisfy({ path.contains($0) }),
                  let arguments = arguments(of: pid) else { continue }
            return Match(pid: pid, arguments: arguments)
        }
        return nil
    }

    /// Finds the Antigravity language server process by matching executable or arguments.
    static func findLanguageServer() -> Match? {
        for pid in currentPIDs() {
            guard let path = executablePath(of: pid) else { continue }
            let isCandidate = path.contains("Antigravity")
                || path.contains("language_server")
                || path.contains("language_server_macos_arm64")
            guard isCandidate, let arguments = arguments(of: pid) else { continue }
            let fullCommand = arguments.joined(separator: " ")
            if fullCommand.contains("language_server") || fullCommand.contains("language_server_macos_arm64") {
                return Match(pid: pid, arguments: arguments)
            }
            if path.contains("Antigravity") && fullCommand.contains("csrf_token") {
                return Match(pid: pid, arguments: arguments)
            }
        }
        return nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func listeningTCPPorts(of pid: pid_t) -> [Int] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, byteCount)
        guard written > 0 else { return [] }

        var ports: Set<Int> = []
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)

        for descriptor in descriptors.prefix(Int(written) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }

            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }

            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if (1024...65535).contains(port) {
                ports.insert(port)
            }
        }
        return Array(ports)
    }

    private static func currentPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }

        return pids.prefix(Int(written) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.reversed()
    }

    /// KERN_PROCARGS2 lays out: argc, the executable path, NUL padding, then the argument strings.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }

        let argumentCount = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argumentCount > 0 else { return nil }

        var tokens: [String] = []
        var index = 4
        while index < size, tokens.count <= argumentCount {
            while index < size, buffer[index] == 0 { index += 1 }
            guard index < size else { break }

            let start = index
            while index < size, buffer[index] != 0 { index += 1 }

            let token = String(decoding: buffer[start..<index], as: UTF8.self)
            if !token.isEmpty {
                tokens.append(token)
            }
        }
        return tokens.isEmpty ? nil : tokens
    }
}
