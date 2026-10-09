import Darwin
import Foundation
import Security

/// Only a sudo process below the running Moppo application can request a password.
struct HomebrewAskpassRequest: Sendable {
    struct ProcessIdentity: Sendable {
        let parent: pid_t
        let executable: String
    }

    let applicationPID: pid_t
    let package: String
    let deadline: Date

    init?(environment: [String: String], now: Date = .now) {
        guard let value = environment["HOMEBREW_MOPPO_APP_PID"], let pid = pid_t(value), pid > 1,
              let package = environment["HOMEBREW_MOPPO_CASK"], !package.isEmpty, package.count <= 200,
              !package.hasPrefix("-"), !package.contains(".."), !package.contains("//"),
              package.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46, 47, 64, 95].contains($0) }),
              let expiry = environment["HOMEBREW_MOPPO_AUTH_DEADLINE"], let seconds = Double(expiry), seconds.isFinite,
              seconds > now.timeIntervalSince1970, seconds <= now.addingTimeInterval(300).timeIntervalSince1970
        else { return nil }
        self.applicationPID = pid
        self.package = package
        self.deadline = Date(timeIntervalSince1970: seconds)
    }

    func accepts(
        parentPID: pid_t, applicationExecutable: String, now: Date = .now,
        identity: (pid_t) -> ProcessIdentity? = Self.identity
    ) -> Bool {
        guard now < deadline, identity(parentPID)?.executable == "/usr/bin/sudo" else { return false }
        var pid = parentPID
        var visited = Set<pid_t>()
        for _ in 0..<64 {
            guard pid > 1, visited.insert(pid).inserted, let process = identity(pid) else { return false }
            if pid == applicationPID { return process.executable == applicationExecutable }
            pid = process.parent
        }
        return false
    }

    static func identity(_ pid: pid_t) -> ProcessIdentity? {
        // sysctl permits reading the parent PID of sudo without administrator access.
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout.size(ofValue: info)
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout.size(ofValue: info) else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is unavailable in Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return ProcessIdentity(parent: info.kp_eproc.e_ppid, executable: executable)
    }

    static func isSignedMoppo(_ pid: pid_t) -> Bool {
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownInformation: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInformation) == errSecSuccess,
              let information = ownInformation as? [String: Any],
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
        else { return false }

        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.tommasolaterza.Moppo\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var application: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &application) == errSecSuccess,
              let application else { return false }
        return SecCodeCheckValidity(application, [], requirement) == errSecSuccess
    }
}
