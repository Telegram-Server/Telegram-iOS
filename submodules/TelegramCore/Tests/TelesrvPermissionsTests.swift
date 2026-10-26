import XCTest
import Postbox
@testable import TelegramCore

final class TelesrvPermissionsTests: XCTestCase {
    private let account = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1))
    private let alice = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(2))
    private let bob = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(3))
    private let group = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(4))
    private let secretChat = EnginePeer.Id(namespace: Namespaces.Peer.SecretChat, id: EnginePeer.Id.Id._internalFromInt64Value(5))

    private func permissions(_ values: [String: JSON]) -> TelesrvPermissions {
        return TelesrvPermissions.with(appConfigurationData: .dictionary(["telesrv_permissions": .dictionary(values)]))
    }

    func testMissingKeyRestrictsNothing() {
        XCTAssertTrue(TelesrvPermissions.with(appConfigurationData: nil).isUnrestricted)
        XCTAssertTrue(TelesrvPermissions.with(appConfigurationData: .dictionary([:])).isUnrestricted)
        XCTAssertTrue(self.permissions([:]).isUnrestricted)
    }

    func testOnlyJSONFalseForbids() {
        let value = self.permissions([
            "send": .bool(true),
            "delete": .bool(false),
            "edit": .string("false"),
            "clear_history": .number(0.0),
            "join_channel": .bool(false)
        ])
        XCTAssertTrue(value.allows(.send))
        XCTAssertFalse(value.allows(.delete))
        XCTAssertTrue(value.allows(.edit))
        XCTAssertTrue(value.allows(.clearHistory))
        XCTAssertFalse(value.canJoin(isBroadcast: true))
        XCTAssertTrue(value.canJoin(isBroadcast: false))
    }

    func testSendOffAllowsOnlySavedMessages() {
        let value = self.permissions([
            "send": .bool(false),
            "send_whitelist": .dictionary(["enabled": .bool(true), "user_ids": .array([.number(2)])])
        ])
        XCTAssertNil(value.sendRestriction(chatPeerId: self.account, userId: self.account, accountPeerId: self.account))
        XCTAssertEqual(value.sendRestriction(chatPeerId: self.alice, userId: self.alice, accountPeerId: self.account), .restricted)
        XCTAssertEqual(value.sendRestriction(chatPeerId: self.group, userId: nil, accountPeerId: self.account), .restricted)
    }

    func testWhitelistLimitsPrivateChatsOnly() {
        let value = self.permissions([
            "send_whitelist": .dictionary(["enabled": .bool(true), "user_ids": .array([.number(2)])])
        ])
        XCTAssertNil(value.sendRestriction(chatPeerId: self.alice, userId: self.alice, accountPeerId: self.account))
        XCTAssertEqual(value.sendRestriction(chatPeerId: self.bob, userId: self.bob, accountPeerId: self.account), .notInWhitelist)
        XCTAssertNil(value.sendRestriction(chatPeerId: self.group, userId: nil, accountPeerId: self.account))
        XCTAssertNil(value.sendRestriction(chatPeerId: self.account, userId: self.account, accountPeerId: self.account))
        // A secret chat is judged by its other user, and refused when that user is unknown.
        XCTAssertNil(value.sendRestriction(chatPeerId: self.secretChat, userId: self.alice, accountPeerId: self.account))
        XCTAssertEqual(value.sendRestriction(chatPeerId: self.secretChat, userId: self.bob, accountPeerId: self.account), .notInWhitelist)
        XCTAssertEqual(value.sendRestriction(chatPeerId: self.secretChat, userId: nil, accountPeerId: self.account, secretChatWithUnknownUser: true), .notInWhitelist)

        XCTAssertTrue(value.inSendWhitelist(userId: self.alice, accountPeerId: self.account))
        XCTAssertFalse(value.inSendWhitelist(userId: self.bob, accountPeerId: self.account))
        XCTAssertTrue(value.inSendWhitelist(userId: self.account, accountPeerId: self.account))
    }

    func testDisabledWhitelistIsIgnored() {
        let value = self.permissions([
            "send_whitelist": .dictionary(["enabled": .bool(false), "user_ids": .array([.number(2)])])
        ])
        XCTAssertTrue(value.isUnrestricted)
        XCTAssertNil(value.sendRestriction(chatPeerId: self.bob, userId: self.bob, accountPeerId: self.account))
    }

    func testClearHistoryCoversPrivateChatsOnly() {
        let value = self.permissions(["clear_history": .bool(false)])
        XCTAssertFalse(value.canClearHistory(peerId: self.alice))
        XCTAssertFalse(value.canClearHistory(peerId: self.account))
        XCTAssertFalse(value.canClearHistory(peerId: self.secretChat))
        XCTAssertTrue(value.canClearHistory(peerId: self.group))
    }

    func testCreateAndLeaveFollowTheChatKind() {
        let value = self.permissions(["create_channel": .bool(false), "leave_group": .bool(false)])
        XCTAssertFalse(value.canCreate(isBroadcast: true))
        XCTAssertTrue(value.canCreate(isBroadcast: false))
        XCTAssertFalse(value.canLeave(isBroadcast: false))
        XCTAssertTrue(value.canLeave(isBroadcast: true))
    }
}
