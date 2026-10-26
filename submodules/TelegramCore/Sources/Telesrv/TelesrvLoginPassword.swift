import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

// Phone number + login password, the telesrv protocol extension (TgSever docs/password-login.md).
// The five methods come from submodules/TelegramApi/telesrv.tl:
//   telesrv.getLoginPassword#e35bc783, telesrv.signInWithPassword#b57ee87d,
//   telesrv.signUpWithPassword#e57cf5b6, telesrv.getMyLoginPassword#70c0eadb,
//   telesrv.updateLoginPassword#917c32ca.
// `flags` is always 0. The SRP math is the 2FA one (passwordKDF / passwordUpdateKDF).

public enum TelesrvLoginPasswordError: Equatable {
    case generic
    /// `420 FLOOD_WAIT_X`; the wait in seconds, 0 when the server named none.
    case floodWait(Int32)
    /// `406 PHONE_NUMBER_INVALID` from the lookup: a malformed or reserved number.
    case invalidPhoneNumber
    /// `403 PASSWORD_LOGIN_DISABLED`: the operator switched password login off.
    case passwordLoginDisabled
    /// `400 PASSWORD_LOGIN_NOT_SET`: the account exists but has no login password.
    case notSet
    /// `400 SIGN_UP_DISABLED`: the number has no account and sign-up is closed.
    case signUpDisabled
    /// `400 PASSWORD_HASH_INVALID`: wrong password (for an update with no current password: the
    /// reset window is off or has passed).
    case invalidPassword
    /// `400 FIRSTNAME_INVALID`.
    case invalidFirstName
    /// `400 PHONE_NUMBER_OCCUPIED`: the number was registered meanwhile. The state is now sign-in.
    case phoneNumberOccupied
    /// `406 PHONE_NUMBER_INVALID` after a valid proof: the account was deleted or is not a user.
    case accountUnavailable
    /// The account behind the number changed between the lookup and the submission (it got or lost
    /// a password, or appeared or vanished). Start again from the phone number.
    case restartRequired
    /// `AUTHORIZATIONS_TOO_MUCH`: the account is used on as many devices as its limit allows.
    case deviceLimitExceeded
    /// `DEVICE_ID_REQUIRED`: the account has a device limit and this client reported no device id.
    case deviceIdRequired
    /// `420 FROZEN_METHOD_INVALID`: the account is frozen.
    case frozen
}

private func telesrvFloodWaitSeconds(_ description: String) -> Int32? {
    guard description.hasPrefix("FLOOD_WAIT") else {
        return nil
    }
    if let range = description.range(of: "_", options: .backwards), let value = Int32(description[range.upperBound...]) {
        return value
    }
    return 0
}

private func telesrvLoginPasswordError(_ error: MTRpcError) -> TelesrvLoginPasswordError {
    let description = error.errorDescription ?? ""
    if let seconds = telesrvFloodWaitSeconds(description) {
        return .floodWait(seconds)
    }
    switch description {
    case "PASSWORD_LOGIN_DISABLED":
        return .passwordLoginDisabled
    case "PASSWORD_LOGIN_NOT_SET":
        return .notSet
    case "SIGN_UP_DISABLED":
        return .signUpDisabled
    case "PASSWORD_HASH_INVALID":
        return .invalidPassword
    case "FIRSTNAME_INVALID":
        return .invalidFirstName
    case "PHONE_NUMBER_OCCUPIED":
        return .phoneNumberOccupied
    case "PHONE_NUMBER_INVALID":
        return .invalidPhoneNumber
    case "AUTHORIZATIONS_TOO_MUCH":
        return .deviceLimitExceeded
    case "DEVICE_ID_REQUIRED":
        return .deviceIdRequired
    case "FROZEN_METHOD_INVALID":
        return .frozen
    default:
        return .generic
    }
}

/// A challenge that cannot be answered any more: used, expired, issued under a rotated temporary key,
/// or invalidated by a password change. A fresh `getLoginPassword` answers each of them.
private func telesrvIsStaleChallengeError(_ error: MTRpcError) -> Bool {
    switch error.errorDescription ?? "" {
    case "SRP_ID_INVALID", "SRP_PASSWORD_CHANGED", "AUTH_KEY_PERM_EMPTY":
        return true
    default:
        return false
    }
}

/// What `telesrv.getLoginPassword` / `telesrv.getMyLoginPassword` returned.
struct TelesrvLoginPasswordChallenge {
    let hasPassword: Bool
    /// The algorithm to hash a new password with (`new_algo`).
    let nextDerivation: TwoStepPasswordDerivation
    /// The algorithm of the current password and its SRP challenge, when one is set.
    let currentDerivation: TwoStepPasswordDerivation?
    let srpSessionData: TwoStepSRPSessionData?

    init(_ password: Api.account.Password) {
        switch password {
        case let .password(data):
            self.hasPassword = (data.flags & (1 << 2)) != 0
            self.nextDerivation = TwoStepPasswordDerivation(data.newAlgo)
            self.currentDerivation = data.currentAlgo.flatMap(TwoStepPasswordDerivation.init)
            if let srpB = data.srpB, let srpId = data.srpId {
                self.srpSessionData = TwoStepSRPSessionData(id: srpId, B: srpB.makeData())
            } else {
                self.srpSessionData = nil
            }
        }
    }
}

private func telesrvGetLoginPassword(network: Network, phoneNumber: String) -> Signal<TelesrvLoginPasswordChallenge, MTRpcError> {
    return network.request(Api.functions.telesrv.getLoginPassword(flags: 0, phoneNumber: phoneNumber), automaticFloodWait: false)
    |> map(TelesrvLoginPasswordChallenge.init)
}

private func telesrvCheckPassword(network: Network, password: String, challenge: TelesrvLoginPasswordChallenge) -> Api.InputCheckPasswordSRP? {
    guard let derivation = challenge.currentDerivation, let srpSessionData = challenge.srpSessionData else {
        return nil
    }
    guard let result = passwordKDF(encryptionProvider: network.encryptionProvider, keychain: network.context.keychain, password: password, derivation: derivation, srpSessionData: srpSessionData) else {
        return nil
    }
    return .inputCheckPasswordSRP(.init(srpId: result.id, A: Buffer(data: result.A), M1: Buffer(data: result.M1)))
}

/// `new_settings` for a new login password, hashed with `new_algo` (salt1 gets its 32 random
/// bytes appended inside `passwordUpdateKDF`). `nil` removes the password. There is no recovery
/// email (the server rejects one) and the hint is ignored.
private func telesrvNewPasswordSettings(network: Network, password: String?, derivation: TwoStepPasswordDerivation) -> Api.account.PasswordInputSettings? {
    guard let password = password else {
        return .passwordInputSettings(.init(flags: 1 << 0, newAlgo: .passwordKdfAlgoUnknown, newPasswordHash: Buffer(data: Data()), hint: "", email: nil, newSecureSettings: nil))
    }
    guard let (hash, updatedDerivation) = passwordUpdateKDF(encryptionProvider: network.encryptionProvider, keychain: network.context.keychain, password: password, derivation: derivation) else {
        return nil
    }
    return .passwordInputSettings(.init(flags: 1 << 0, newAlgo: updatedDerivation.apiAlgo, newPasswordHash: Buffer(data: hash), hint: "", email: nil, newSecureSettings: nil))
}

// MARK: - Login (unauthorized account)

public enum TelesrvLoginPasswordLookupResult {
    /// The account has a login password; the state is now `.loginPasswordEntry`.
    case signIn
    /// No account has the number; the state is now `.loginPasswordSignUp`.
    case signUp
}

/// The first step of password login: asks the server what the number is, and moves the
/// authorization state to the matching page.
public func telesrvBeginLoginPassword(account: UnauthorizedAccount, phoneNumber: String, syncContacts: Bool) -> Signal<TelesrvLoginPasswordLookupResult, TelesrvLoginPasswordError> {
    return telesrvGetLoginPassword(network: account.network, phoneNumber: phoneNumber)
    |> mapError(telesrvLoginPasswordError)
    |> mapToSignal { challenge -> Signal<TelesrvLoginPasswordLookupResult, TelesrvLoginPasswordError> in
        return account.postbox.transaction { transaction -> TelesrvLoginPasswordLookupResult in
            if challenge.hasPassword {
                transaction.setState(UnauthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, contents: .loginPasswordEntry(number: phoneNumber, syncContacts: syncContacts)))
                return .signIn
            } else {
                transaction.setState(UnauthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, contents: .loginPasswordSignUp(number: phoneNumber, syncContacts: syncContacts)))
                return .signUp
            }
        }
        |> castError(TelesrvLoginPasswordError.self)
    }
}

private enum TelesrvSignInStep {
    case authorization(Api.auth.Authorization)
    case cloudPassword(hint: String)
}

/// Signs in with the login password of the number in the `.loginPasswordEntry` state. An account
/// that also has a 2FA cloud password moves to the stock `.passwordEntry` state instead.
public func telesrvSignInWithLoginPassword(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, password: String, forcedPasswordSetupNotice: @escaping (Int32) -> (NoticeEntryKey, CodableEntry)?) -> Signal<Never, TelesrvLoginPasswordError> {
    return account.postbox.transaction { transaction -> (String, Bool)? in
        if let state = transaction.getState() as? UnauthorizedAccountState, case let .loginPasswordEntry(number, syncContacts) = state.contents {
            return (number, syncContacts)
        }
        return nil
    }
    |> castError(TelesrvLoginPasswordError.self)
    |> mapToSignal { numberAndSyncContacts -> Signal<Never, TelesrvLoginPasswordError> in
        guard let (number, syncContacts) = numberAndSyncContacts else {
            return .fail(.generic)
        }
        let network = account.network

        // Every answer burns the challenge, so each attempt starts with a fresh one. A stale
        // challenge is retried once, as the server documents for a rotated temporary key.
        func attempt(retryStaleChallenge: Bool) -> Signal<TelesrvSignInStep, TelesrvLoginPasswordError> {
            return telesrvGetLoginPassword(network: network, phoneNumber: number)
            |> mapError(telesrvLoginPasswordError)
            |> mapToSignal { challenge -> Signal<TelesrvSignInStep, TelesrvLoginPasswordError> in
                guard challenge.hasPassword else {
                    return .fail(.restartRequired)
                }
                guard let check = telesrvCheckPassword(network: network, password: password, challenge: challenge) else {
                    return .fail(.generic)
                }
                return network.request(Api.functions.telesrv.signInWithPassword(flags: 0, phoneNumber: number, password: check), automaticFloodWait: false)
                |> map { authorization -> TelesrvSignInStep in
                    return .authorization(authorization)
                }
                |> `catch` { error -> Signal<TelesrvSignInStep, TelesrvLoginPasswordError> in
                    if error.errorDescription == "SESSION_PASSWORD_NEEDED" {
                        return network.request(Api.functions.account.getPassword(), automaticFloodWait: false)
                        |> mapError(telesrvLoginPasswordError)
                        |> map { result -> TelesrvSignInStep in
                            switch result {
                            case let .password(passwordData):
                                return .cloudPassword(hint: passwordData.hint ?? "")
                            }
                        }
                    } else if retryStaleChallenge && telesrvIsStaleChallengeError(error) {
                        return attempt(retryStaleChallenge: false)
                    } else if error.errorDescription == "PHONE_NUMBER_INVALID" {
                        return .fail(.accountUnavailable)
                    } else if telesrvIsStaleChallengeError(error) {
                        return .fail(.restartRequired)
                    } else {
                        return .fail(telesrvLoginPasswordError(error))
                    }
                }
            }
        }

        return attempt(retryStaleChallenge: true)
        |> mapToSignal { step -> Signal<Never, TelesrvLoginPasswordError> in
            switch step {
            case let .cloudPassword(hint):
                return account.postbox.transaction { transaction -> Void in
                    transaction.setState(UnauthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, contents: .passwordEntry(hint: hint, number: number, code: nil, suggestReset: false, syncContacts: syncContacts)))
                }
                |> ignoreValues
                |> castError(TelesrvLoginPasswordError.self)
            case let .authorization(authorization):
                return telesrvApplyAuthorization(accountManager: accountManager, account: account, authorization: authorization, syncContacts: syncContacts, isSignUp: false, avatar: nil, forcedPasswordSetupNotice: forcedPasswordSetupNotice)
            }
        }
    }
}

public struct TelesrvSignUpAvatar {
    public let data: Data
    public let video: Signal<UploadedPeerPhotoData?, NoError>?
    public let videoStartTimestamp: Double?

    public init(data: Data, video: Signal<UploadedPeerPhotoData?, NoError>?, videoStartTimestamp: Double?) {
        self.data = data
        self.video = video
        self.videoStartTimestamp = videoStartTimestamp
    }
}

/// Creates an account for the number in the `.loginPasswordSignUp` state with a login password.
/// A number that was registered meanwhile moves the state to `.loginPasswordEntry` and fails with
/// `.phoneNumberOccupied`.
public func telesrvSignUpWithLoginPassword(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, firstName: String, lastName: String, password: String, avatar: TelesrvSignUpAvatar?, forcedPasswordSetupNotice: @escaping (Int32) -> (NoticeEntryKey, CodableEntry)?) -> Signal<Never, TelesrvLoginPasswordError> {
    return account.postbox.transaction { transaction -> (String, Bool)? in
        if let state = transaction.getState() as? UnauthorizedAccountState, case let .loginPasswordSignUp(number, syncContacts) = state.contents {
            return (number, syncContacts)
        }
        return nil
    }
    |> castError(TelesrvLoginPasswordError.self)
    |> mapToSignal { numberAndSyncContacts -> Signal<Never, TelesrvLoginPasswordError> in
        guard let (number, syncContacts) = numberAndSyncContacts else {
            return .fail(.generic)
        }
        let network = account.network

        let movedToSignIn: Signal<Never, TelesrvLoginPasswordError> = account.postbox.transaction { transaction -> Void in
            transaction.setState(UnauthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, contents: .loginPasswordEntry(number: number, syncContacts: syncContacts)))
        }
        |> ignoreValues
        |> castError(TelesrvLoginPasswordError.self)

        return telesrvGetLoginPassword(network: network, phoneNumber: number)
        |> mapError(telesrvLoginPasswordError)
        |> mapToSignal { challenge -> Signal<Never, TelesrvLoginPasswordError> in
            if challenge.hasPassword {
                return movedToSignIn
                |> then(.fail(.phoneNumberOccupied))
            }
            guard let newSettings = telesrvNewPasswordSettings(network: network, password: password, derivation: challenge.nextDerivation) else {
                return .fail(.generic)
            }
            return network.request(Api.functions.telesrv.signUpWithPassword(flags: 0, phoneNumber: number, firstName: firstName, lastName: lastName, newSettings: newSettings), automaticFloodWait: false)
            |> mapError(telesrvLoginPasswordError)
            |> mapToSignal { authorization -> Signal<Never, TelesrvLoginPasswordError> in
                return telesrvApplyAuthorization(accountManager: accountManager, account: account, authorization: authorization, syncContacts: syncContacts, isSignUp: true, avatar: avatar, forcedPasswordSetupNotice: forcedPasswordSetupNotice)
            }
            |> `catch` { error -> Signal<Never, TelesrvLoginPasswordError> in
                if error == .phoneNumberOccupied {
                    return movedToSignIn
                    |> then(.fail(.phoneNumberOccupied))
                }
                return .fail(error)
            }
        }
    }
}

/// Turns an `auth.authorization` into the authorized account, as `authorizeWithCode` and
/// `signUpWithName` do.
private func telesrvApplyAuthorization(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, authorization: Api.auth.Authorization, syncContacts: Bool, isSignUp: Bool, avatar: TelesrvSignUpAvatar?, forcedPasswordSetupNotice: @escaping (Int32) -> (NoticeEntryKey, CodableEntry)?) -> Signal<Never, TelesrvLoginPasswordError> {
    switch authorization {
    case .authorizationSignUpRequired:
        return .fail(.restartRequired)
    case let .authorization(authorizationData):
        let (otherwiseReloginDays, futureAuthToken, apiUser) = (authorizationData.otherwiseReloginDays, authorizationData.futureAuthToken, authorizationData.user)
        if let futureAuthToken = futureAuthToken {
            storeFutureLoginToken(accountManager: accountManager, token: futureAuthToken.makeData())
        }

        let user = TelegramUser(user: apiUser)
        var isSupportUser = false
        if let phone = user.phone, phone.hasPrefix("42") {
            isSupportUser = true
        }

        let appliedState = account.postbox.transaction { transaction -> Void in
            let state = AuthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, peerId: user.id, state: nil, invalidatedChannels: [])
            if isSignUp, let hole = account.postbox.seedConfiguration.initializeChatListWithHole.topLevel {
                transaction.replaceChatListHole(groupId: .root, index: hole.index, hole: nil)
            }
            initializedAppSettingsAfterLogin(transaction: transaction, appVersion: account.networkArguments.appVersion, syncContacts: syncContacts)
            transaction.setState(state)
            if let otherwiseReloginDays = otherwiseReloginDays, let value = forcedPasswordSetupNotice(otherwiseReloginDays) {
                transaction.setNoticeEntry(key: value.0, value: value.1)
            }
        }
        |> ignoreValues
        |> castError(TelesrvLoginPasswordError.self)

        let switchedAccounts = accountManager.transaction { transaction -> Void in
            switchToAuthorizedAccount(transaction: transaction, account: account, isSupportUser: isSupportUser)
        }
        |> ignoreValues
        |> castError(TelesrvLoginPasswordError.self)

        if let avatar = avatar {
            let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
            account.postbox.mediaBox.storeResourceData(resource.id, data: avatar.data)

            return _internal_updatePeerPhotoInternal(postbox: account.postbox, network: account.network, stateManager: nil, accountPeerId: user.id, peer: .single(user), photo: _internal_uploadedPeerPhoto(postbox: account.postbox, network: account.network, resource: resource), video: avatar.video, videoStartTimestamp: avatar.videoStartTimestamp, mapResourceToAvatarSizes: { _, _ in .single([:]) })
            |> `catch` { _ -> Signal<UpdatePeerPhotoStatus, TelesrvLoginPasswordError> in
                return .complete()
            }
            |> mapToSignal { result -> Signal<Never, TelesrvLoginPasswordError> in
                switch result {
                case .complete:
                    return .complete()
                case .progress:
                    return .never()
                }
            }
            |> then(appliedState)
            |> then(switchedAccounts)
        } else {
            return appliedState
            |> then(switchedAccounts)
        }
    }
}

// MARK: - Managing the login password (signed in)

public struct TelesrvLoginPasswordState: Equatable {
    public let hasPassword: Bool
}

func _internal_telesrvLoginPasswordState(network: Network) -> Signal<TelesrvLoginPasswordState, TelesrvLoginPasswordError> {
    return network.request(Api.functions.telesrv.getMyLoginPassword(flags: 0), automaticFloodWait: false)
    |> mapError(telesrvLoginPasswordError)
    |> map { result -> TelesrvLoginPasswordState in
        return TelesrvLoginPasswordState(hasPassword: TelesrvLoginPasswordChallenge(result).hasPassword)
    }
}

/// Sets, changes or removes the account's login password.
///
/// - `currentPassword`: the current login password; `nil` when none is set, or to reset a forgotten
///   one (the server allows that only inside its reset window and answers `.invalidPassword`
///   otherwise).
/// - `newPassword`: the new login password; `nil` removes it.
func _internal_telesrvUpdateLoginPassword(network: Network, currentPassword: String?, newPassword: String?) -> Signal<Never, TelesrvLoginPasswordError> {
    func attempt(retryStaleChallenge: Bool) -> Signal<Never, TelesrvLoginPasswordError> {
        return network.request(Api.functions.telesrv.getMyLoginPassword(flags: 0), automaticFloodWait: false)
        |> map(TelesrvLoginPasswordChallenge.init)
        |> mapError(telesrvLoginPasswordError)
        |> mapToSignal { challenge -> Signal<Never, TelesrvLoginPasswordError> in
            let current: Api.InputCheckPasswordSRP
            if let currentPassword = currentPassword, challenge.hasPassword {
                guard let check = telesrvCheckPassword(network: network, password: currentPassword, challenge: challenge) else {
                    return .fail(.generic)
                }
                current = check
            } else {
                current = .inputCheckPasswordEmpty
            }
            guard let newSettings = telesrvNewPasswordSettings(network: network, password: newPassword, derivation: challenge.nextDerivation) else {
                return .fail(.generic)
            }
            return network.request(Api.functions.telesrv.updateLoginPassword(flags: 0, current: current, newSettings: newSettings), automaticFloodWait: false)
            |> `catch` { error -> Signal<Api.Bool, TelesrvLoginPasswordError> in
                if retryStaleChallenge && telesrvIsStaleChallengeError(error) {
                    return attempt(retryStaleChallenge: false)
                    |> map { _ -> Api.Bool in }
                }
                return .fail(telesrvLoginPasswordError(error))
            }
            |> ignoreValues
        }
    }
    return attempt(retryStaleChallenge: true)
}
