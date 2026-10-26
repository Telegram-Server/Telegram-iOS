import Foundation
import SwiftSignalKit
import MtProtoKit

/// The login switches a telesrv server publishes in `help.getAppConfig`, which it answers before
/// login (TgSever docs: password-login.md, code-login-switch.md, sign-up-switch.md).
///
/// Every key is absent on official servers and older telesrv builds, and absent means the stock
/// behaviour: code login only, sign-up open.
public struct TelesrvLoginConfiguration: Equatable {
    /// `telesrv_features` lists `"password_login"`: the five `telesrv.*` login password methods are on.
    public var passwordLogin: Bool
    /// `telesrv_code_login_disabled`: the server issues no login codes. The server only allows it
    /// while password login is on, so it is ignored otherwise.
    public var codeLoginDisabled: Bool
    /// `telesrv_sign_up_disabled`: numbers without an account cannot create one.
    public var signUpDisabled: Bool

    public static let `default` = TelesrvLoginConfiguration(passwordLogin: false, codeLoginDisabled: false, signUpDisabled: false)

    public init(passwordLogin: Bool, codeLoginDisabled: Bool, signUpDisabled: Bool) {
        self.passwordLogin = passwordLogin
        self.codeLoginDisabled = codeLoginDisabled && passwordLogin
        self.signUpDisabled = signUpDisabled
    }

    public static func with(appConfigurationData data: JSON?) -> TelesrvLoginConfiguration {
        guard case let .dictionary(dict)? = data else {
            return .default
        }
        var passwordLogin = false
        if case let .array(features)? = dict["telesrv_features"] {
            passwordLogin = features.contains(.string("password_login"))
        }
        var codeLoginDisabled = false
        if case let .bool(value)? = dict["telesrv_code_login_disabled"] {
            codeLoginDisabled = value
        }
        var signUpDisabled = false
        if case let .bool(value)? = dict["telesrv_sign_up_disabled"] {
            signUpDisabled = value
        }
        return TelesrvLoginConfiguration(passwordLogin: passwordLogin, codeLoginDisabled: codeLoginDisabled, signUpDisabled: signUpDisabled)
    }

    public static func with(appConfiguration: AppConfiguration) -> TelesrvLoginConfiguration {
        return self.with(appConfigurationData: appConfiguration.data)
    }
}

/// Fetches the login switches over an unauthorized account's network. The hash is 0, so the server
/// always answers with the full config. A failed request yields `nil`: the caller keeps the stock
/// code login and relies on the server's refusals (`CODE_LOGIN_DISABLED`, `SIGN_UP_DISABLED`).
public func telesrvFetchLoginConfiguration(account: UnauthorizedAccount) -> Signal<TelesrvLoginConfiguration?, NoError> {
    return requestAppConfiguration(network: account.network, hash: 0)
    |> map { result -> TelesrvLoginConfiguration? in
        switch result {
        case let .updated(data, _):
            return TelesrvLoginConfiguration.with(appConfigurationData: data)
        case .notModified:
            return nil
        }
    }
    |> `catch` { _ -> Signal<TelesrvLoginConfiguration?, NoError> in
        return .single(nil)
    }
    |> timeout(15.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
}
