import Foundation
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState

/// telesrv staff permissions: why the open chat may not be sent to, or nil. Custom chat contents
/// (quick replies, business messages) are the account's own drafts and are never restricted.
func telesrvSendRestriction(context: AccountContext, state: ChatPresentationInterfaceState) -> TelesrvPermissions.SendRestriction? {
    let permissions = context.telesrvPermissions
    if permissions.isUnrestricted {
        return nil
    }
    if case .customChatContents = state.subject {
        return nil
    }
    guard let peer = state.renderedPeer?.peer else {
        return nil
    }
    return permissions.sendRestriction(peer: EnginePeer(peer), accountPeerId: context.account.peerId)
}
