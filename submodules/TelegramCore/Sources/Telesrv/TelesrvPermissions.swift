import Foundation
import Postbox
import MtProtoKit

/// Staff permissions of the account (TgSever `set-permissions`, issue #118), from the
/// `telesrv_permissions` app config key. The key is present only while the account is restricted;
/// without it nothing is forbidden, which is also what official servers and older telesrv builds mean.
///
/// The server enforces every rule itself (`403 TELESRV_PERMISSION_*`); the client hides or explains
/// what would be refused. The rules follow the Android and Desktop clients:
/// - Saved Messages are never restricted.
/// - `send` off forbids sending everywhere else; the whitelist is not an exception to it.
/// - With `send` on and the whitelist enabled, private and secret chats may only send to the listed
///   users. Groups and channels are not affected.
/// - `clear_history` covers private chats and Saved Messages only: clearing a group or channel is
///   never refused.
public struct TelesrvPermissions: Equatable {
    public enum Action: String, CaseIterable {
        case send = "send"
        case delete = "delete"
        case edit = "edit"
        case clearHistory = "clear_history"
        case createGroup = "create_group"
        case createChannel = "create_channel"
        case joinGroup = "join_group"
        case joinChannel = "join_channel"
        case leaveGroup = "leave_group"
        case leaveChannel = "leave_channel"
        case addContact = "add_contact"
    }

    /// The actions the server forbids.
    public let forbidden: Set<Action>
    public let sendWhitelistEnabled: Bool
    /// Raw user ids of the send whitelist.
    public let sendWhitelist: Set<Int64>

    public static let unrestricted = TelesrvPermissions(forbidden: [], sendWhitelistEnabled: false, sendWhitelist: [])

    public init(forbidden: Set<Action>, sendWhitelistEnabled: Bool, sendWhitelist: Set<Int64>) {
        self.forbidden = forbidden
        self.sendWhitelistEnabled = sendWhitelistEnabled
        self.sendWhitelist = sendWhitelist
    }

    public var isUnrestricted: Bool {
        return self.forbidden.isEmpty && !self.sendWhitelistEnabled
    }

    /// Parses `telesrv_permissions`. A value counts only when it is a JSON bool `false`: a missing,
    /// `true` or malformed value allows the action.
    public static func with(appConfigurationData data: JSON?) -> TelesrvPermissions {
        guard case let .dictionary(dict)? = data, case let .dictionary(permissions)? = dict["telesrv_permissions"] else {
            return .unrestricted
        }
        var forbidden = Set<Action>()
        for action in Action.allCases {
            if case .bool(false)? = permissions[action.rawValue] {
                forbidden.insert(action)
            }
        }
        var sendWhitelistEnabled = false
        var sendWhitelist = Set<Int64>()
        if case let .dictionary(whitelist)? = permissions["send_whitelist"] {
            if case let .bool(value)? = whitelist["enabled"] {
                sendWhitelistEnabled = value
            }
            if case let .array(ids)? = whitelist["user_ids"] {
                for id in ids {
                    if case let .number(value) = id {
                        sendWhitelist.insert(Int64(value.rounded()))
                    }
                }
            }
        }
        return TelesrvPermissions(forbidden: forbidden, sendWhitelistEnabled: sendWhitelistEnabled, sendWhitelist: sendWhitelist)
    }

    public static func with(appConfiguration: AppConfiguration) -> TelesrvPermissions {
        return self.with(appConfigurationData: appConfiguration.data)
    }

    public func allows(_ action: Action) -> Bool {
        return !self.forbidden.contains(action)
    }

    public enum SendRestriction: Equatable {
        /// `send` is off.
        case restricted
        /// The chat's user is not on the send whitelist.
        case notInWhitelist
    }

    /// Why sending to the chat would be refused, or nil when it is allowed.
    ///
    /// - `userId`: the chat's user for a private chat, the other user of a secret chat; nil for a
    ///   group or channel. A secret chat whose user is unknown passes `secretChatWithUnknownUser`.
    public func sendRestriction(chatPeerId: EnginePeer.Id, userId: EnginePeer.Id?, accountPeerId: EnginePeer.Id, secretChatWithUnknownUser: Bool = false) -> SendRestriction? {
        if self.isUnrestricted {
            return nil
        }
        if chatPeerId == accountPeerId {
            return nil
        }
        if !self.allows(.send) {
            return .restricted
        }
        if self.sendWhitelistEnabled {
            if let userId {
                if userId != accountPeerId && !self.sendWhitelist.contains(userId.id._internalGetInt64Value()) {
                    return .notInWhitelist
                }
            } else if secretChatWithUnknownUser {
                return .notInWhitelist
            }
        }
        return nil
    }

    public func sendRestriction(peer: EnginePeer, accountPeerId: EnginePeer.Id) -> SendRestriction? {
        switch peer {
        case let .user(user):
            return self.sendRestriction(chatPeerId: user.id, userId: user.id, accountPeerId: accountPeerId)
        case let .secretChat(secretChat):
            return self.sendRestriction(chatPeerId: secretChat.id, userId: secretChat.regularPeerId, accountPeerId: accountPeerId)
        case .legacyGroup, .channel, .community:
            return self.sendRestriction(chatPeerId: peer.id, userId: nil, accountPeerId: accountPeerId)
        }
    }

    public func canSend(to peer: EnginePeer, accountPeerId: EnginePeer.Id) -> Bool {
        return self.sendRestriction(peer: peer, accountPeerId: accountPeerId) == nil
    }

    /// Whether the user may be picked as a private-chat destination (contact pickers).
    public func inSendWhitelist(userId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> Bool {
        return !self.sendWhitelistEnabled || userId == accountPeerId || self.sendWhitelist.contains(userId.id._internalGetInt64Value())
    }

    /// Clearing history: refused only for private chats, secret chats and Saved Messages.
    public func canClearHistory(peerId: EnginePeer.Id) -> Bool {
        switch peerId.namespace {
        case Namespaces.Peer.CloudUser, Namespaces.Peer.SecretChat:
            return self.allows(.clearHistory)
        default:
            return true
        }
    }

    /// Deleting a chat: a private chat's deletion clears its history; a group's or channel's leaves it.
    public func canDeleteChat(peer: EnginePeer) -> Bool {
        switch peer {
        case .user, .secretChat:
            return self.allows(.clearHistory)
        case .legacyGroup, .community:
            return self.allows(.leaveGroup)
        case let .channel(channel):
            return self.canLeave(isBroadcast: channel.info.telesrvIsBroadcast)
        }
    }

    public func canJoin(isBroadcast: Bool) -> Bool {
        return self.allows(isBroadcast ? .joinChannel : .joinGroup)
    }

    public func canJoin(peer: EnginePeer) -> Bool {
        if case let .channel(channel) = peer {
            return self.canJoin(isBroadcast: channel.info.telesrvIsBroadcast)
        }
        return self.allows(.joinGroup)
    }

    public func canLeave(isBroadcast: Bool) -> Bool {
        return self.allows(isBroadcast ? .leaveChannel : .leaveGroup)
    }

    public func canLeave(peer: EnginePeer) -> Bool {
        switch peer {
        case let .channel(channel):
            return self.canLeave(isBroadcast: channel.info.telesrvIsBroadcast)
        case .legacyGroup, .community:
            return self.allows(.leaveGroup)
        case .user, .secretChat:
            return true
        }
    }

    public func canCreate(isBroadcast: Bool) -> Bool {
        return self.allows(isBroadcast ? .createChannel : .createGroup)
    }
}

/// Whether a request was refused for a staff permission.
func telesrvIsPermissionError(_ error: MTRpcError) -> Bool {
    return (error.errorDescription ?? "").hasPrefix("TELESRV_PERMISSION_")
}

private extension TelegramChannelInfo {
    var telesrvIsBroadcast: Bool {
        if case .broadcast = self {
            return true
        } else {
            return false
        }
    }
}

/// The account's staff permissions as stored with its app config.
func telesrvCurrentPermissions(transaction: Transaction) -> TelesrvPermissions {
    let appConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
    return TelesrvPermissions.with(appConfiguration: appConfiguration)
}
