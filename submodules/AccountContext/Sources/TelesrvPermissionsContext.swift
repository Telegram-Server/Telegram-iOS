import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

/// telesrv staff permissions of the account, read from its app config. A protocol extension rather
/// than a requirement, so every `AccountContext` (the test harness's included) has it without
/// providing it.
public extension AccountContext {
    /// The permissions as of the current app config.
    var telesrvPermissions: TelesrvPermissions {
        return TelesrvPermissions.with(appConfiguration: self.currentAppConfiguration.with { $0 })
    }

    /// The permissions, updated whenever the app config changes (the server sends `updateConfig`
    /// when an administrator changes them).
    var telesrvPermissionsSignal: Signal<TelesrvPermissions, NoError> {
        return self.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.App())
        |> map { appConfiguration -> TelesrvPermissions in
            return TelesrvPermissions.with(appConfiguration: appConfiguration)
        }
        |> distinctUntilChanged
    }

    /// `canSendMessagesToPeer`, also refused by the staff permissions: the check every chat picker
    /// that sends (forward, share, quick reply) uses.
    func telesrvCanSendMessagesToPeer(_ peer: EnginePeer, ignoreDefault: Bool = false) -> Bool {
        return canSendMessagesToPeer(peer, ignoreDefault: ignoreDefault) && self.telesrvPermissions.canSend(to: peer, accountPeerId: self.account.peerId)
    }

    /// Contact pickers: whether the user may be offered as a private-chat destination.
    func telesrvInSendWhitelist(_ peer: EnginePeer) -> Bool {
        switch peer {
        case .user:
            return self.telesrvPermissions.inSendWhitelist(userId: peer.id, accountPeerId: self.account.peerId)
        case let .secretChat(secretChat):
            return self.telesrvPermissions.inSendWhitelist(userId: secretChat.regularPeerId, accountPeerId: self.account.peerId)
        default:
            return true
        }
    }
}

public extension TelesrvPermissions.SendRestriction {
    /// The text shown in place of the input field, and when a send is refused.
    func text(strings: PresentationStrings) -> String {
        switch self {
        case .restricted:
            return strings.Telesrv_Permission_SendRestricted
        case .notInWhitelist:
            return strings.Telesrv_Permission_SendWhitelistRestricted
        }
    }
}

public extension ShareControllerAccountContext {
    /// `canSendMessagesToPeer`, also refused by the staff permissions (share sheets, the share extension).
    func telesrvCanSendMessagesToPeer(_ peer: EnginePeer) -> Bool {
        return canSendMessagesToPeer(peer) && TelesrvPermissions.with(appConfiguration: self.appConfiguration).canSend(to: peer, accountPeerId: self.accountPeerId)
    }
}
