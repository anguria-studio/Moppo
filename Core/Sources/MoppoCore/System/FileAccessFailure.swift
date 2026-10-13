import Foundation

/// Identifies access denial without changing file permissions.
public enum FileAccessFailure {
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileWriteNoPermission.rawValue
            || error.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
