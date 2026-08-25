import Foundation
import Security

enum CodeSigningInfo {
    /// True when this bundle carries an ad-hoc signature.
    ///
    /// An ad-hoc signature has no certificate, so the designated requirement is
    /// a bare `cdhash`. macOS records that requirement when Accessibility is
    /// granted, and every rebuild changes the hash — the grant silently stops
    /// matching while System Settings still shows the switch on. Knowing this at
    /// runtime lets the onboarding say what is actually wrong instead of
    /// suggesting the user toggle the switch again.
    static let isAdHocSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        // kSecCodeSignatureAdhoc
        return flags & 0x0000_0002 != 0
    }()
}
