import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import UndoUI

// The account's telesrv login password: set, change, remove, or reset a forgotten one
// (TgSever docs/password-login.md, "Managing the login password").

private enum TelesrvLoginPasswordField {
    case current
    case new
    case confirmation
}

private final class TelesrvLoginPasswordControllerArguments {
    let updateFieldText: (TelesrvLoginPasswordField, String) -> Void
    let selectNextInputItem: (TelesrvLoginPasswordEntryTag) -> Void
    let save: () -> Void
    let remove: () -> Void
    let forgot: () -> Void

    init(updateFieldText: @escaping (TelesrvLoginPasswordField, String) -> Void, selectNextInputItem: @escaping (TelesrvLoginPasswordEntryTag) -> Void, save: @escaping () -> Void, remove: @escaping () -> Void, forgot: @escaping () -> Void) {
        self.updateFieldText = updateFieldText
        self.selectNextInputItem = selectNextInputItem
        self.save = save
        self.remove = remove
        self.forgot = forgot
    }
}

private enum TelesrvLoginPasswordSection: Int32 {
    case current
    case new
    case actions
}

private enum TelesrvLoginPasswordEntryTag: ItemListItemTag {
    case current
    case new
    case confirmation

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? TelesrvLoginPasswordEntryTag {
            return self == other
        } else {
            return false
        }
    }
}

private enum TelesrvLoginPasswordEntry: ItemListNodeEntry, Equatable {
    case currentHeader(String)
    case current(String, String)
    case newHeader(String)
    case new(String, String)
    case confirmation(String, String)
    case info(String)
    case remove(String, Bool)
    case forgot(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .currentHeader, .current:
            return TelesrvLoginPasswordSection.current.rawValue
        case .newHeader, .new, .confirmation, .info:
            return TelesrvLoginPasswordSection.new.rawValue
        case .remove, .forgot:
            return TelesrvLoginPasswordSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .currentHeader:
            return 0
        case .current:
            return 1
        case .newHeader:
            return 2
        case .new:
            return 3
        case .confirmation:
            return 4
        case .info:
            return 5
        case .remove:
            return 6
        case .forgot:
            return 7
        }
    }

    static func <(lhs: TelesrvLoginPasswordEntry, rhs: TelesrvLoginPasswordEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TelesrvLoginPasswordControllerArguments
        switch self {
        case let .currentHeader(text), let .newHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .current(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .password, returnKeyType: .next, spacing: 0.0, tag: TelesrvLoginPasswordEntryTag.current, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateFieldText(.current, updatedText)
            }, action: {
                arguments.selectNextInputItem(TelesrvLoginPasswordEntryTag.current)
            })
        case let .new(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .password, returnKeyType: .next, spacing: 0.0, tag: TelesrvLoginPasswordEntryTag.new, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateFieldText(.new, updatedText)
            }, action: {
                arguments.selectNextInputItem(TelesrvLoginPasswordEntryTag.new)
            })
        case let .confirmation(placeholder, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .password, returnKeyType: .done, spacing: 0.0, tag: TelesrvLoginPasswordEntryTag.confirmation, sectionId: self.section, textUpdated: { updatedText in
                arguments.updateFieldText(.confirmation, updatedText)
            }, action: {
                arguments.save()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .remove(text, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: enabled ? .destructive : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.remove()
            })
        case let .forgot(text, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.forgot()
            })
        }
    }
}

private struct TelesrvLoginPasswordControllerState: Equatable {
    var hasPassword: Bool
    var currentText: String = ""
    var newText: String = ""
    var confirmationText: String = ""
    var saving: Bool = false

    init(hasPassword: Bool) {
        self.hasPassword = hasPassword
    }
}

private func telesrvLoginPasswordControllerEntries(presentationData: PresentationData, state: TelesrvLoginPasswordControllerState) -> [TelesrvLoginPasswordEntry] {
    let strings = presentationData.strings
    var entries: [TelesrvLoginPasswordEntry] = []
    if state.hasPassword {
        entries.append(.currentHeader(strings.Telesrv_LoginPasswordSettings_CurrentHeader))
        entries.append(.current(strings.Telesrv_LoginPasswordSettings_CurrentPlaceholder, state.currentText))
    }
    entries.append(.newHeader(strings.Telesrv_LoginPasswordSettings_NewHeader))
    entries.append(.new(strings.Telesrv_LoginPasswordSettings_NewPlaceholder, state.newText))
    entries.append(.confirmation(strings.Telesrv_LoginPasswordSettings_ConfirmPlaceholder, state.confirmationText))
    entries.append(.info(strings.Telesrv_LoginPasswordSettings_Info))
    if state.hasPassword {
        entries.append(.remove(strings.Telesrv_LoginPasswordSettings_Remove, !state.saving))
        entries.append(.forgot(strings.Telesrv_LoginPasswordSettings_Forgot, !state.saving))
    }
    return entries
}

private func telesrvLoginPasswordErrorText(strings: PresentationStrings, error: TelesrvLoginPasswordError) -> String {
    switch error {
    case let .floodWait(seconds):
        if seconds > 0 {
            return strings.Telesrv_FloodWait(timeIntervalString(strings: strings, value: seconds)).string
        } else {
            return strings.LoginPassword_FloodError
        }
    case .invalidPassword:
        return strings.LoginPassword_InvalidPasswordError
    case .frozen, .passwordLoginDisabled, .notSet, .signUpDisabled, .invalidFirstName, .invalidPhoneNumber, .phoneNumberOccupied, .accountUnavailable, .restartRequired, .deviceLimitExceeded, .deviceIdRequired, .generic:
        return strings.Login_UnknownError
    }
}

/// The login password screen of Privacy and Security. `updatedHasPassword` reports a set or removed
/// password to the caller.
public func telesrvLoginPasswordController(context: AccountContext, hasPassword: Bool, updatedHasPassword: @escaping (Bool) -> Void) -> ViewController {
    let initialState = TelesrvLoginPasswordControllerState(hasPassword: hasPassword)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((TelesrvLoginPasswordControllerState) -> TelesrvLoginPasswordControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var dismissImpl: (() -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var presentToastImpl: ((String) -> Void)?
    var selectNextInputItemImpl: ((TelesrvLoginPasswordEntryTag) -> Void)?

    let actionsDisposable = DisposableSet()
    let saveDisposable = MetaDisposable()
    actionsDisposable.add(saveDisposable)

    let presentAlert: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
    }

    /// `currentPassword` nil: no password yet, or a reset without the old one. `newPassword` nil: removal.
    let perform: (String?, String?, Bool) -> Void = { currentPassword, newPassword, isReset in
        updateState { state in
            var state = state
            state.saving = true
            return state
        }
        saveDisposable.set((context.engine.auth.telesrvUpdateLoginPassword(currentPassword: currentPassword, newPassword: newPassword)
        |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.saving = false
                return state
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            if isReset, case .invalidPassword = error {
                presentAlert(presentationData.strings.Telesrv_LoginPasswordSettings_ResetUnavailable)
            } else {
                presentAlert(telesrvLoginPasswordErrorText(strings: presentationData.strings, error: error))
            }
        }, completed: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            updatedHasPassword(newPassword != nil)
            presentToastImpl?(newPassword != nil ? presentationData.strings.Telesrv_LoginPasswordSettings_Saved : presentationData.strings.Telesrv_LoginPasswordSettings_Removed)
            dismissImpl?()
        }))
    }

    /// The new password from the two fields, or nil after telling the user what is wrong.
    let validatedNewPassword: () -> String? = {
        let state = stateValue.with { $0 }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if state.newText.isEmpty {
            return nil
        }
        if state.newText != state.confirmationText {
            presentAlert(presentationData.strings.Telesrv_SignUp_PasswordMismatch)
            return nil
        }
        return state.newText
    }

    let saveImpl: () -> Void = {
        let state = stateValue.with { $0 }
        guard !state.saving else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if state.hasPassword && state.currentText.isEmpty {
            presentAlert(presentationData.strings.Telesrv_LoginPasswordSettings_EnterCurrent)
            return
        }
        guard let newPassword = validatedNewPassword() else {
            return
        }
        perform(state.hasPassword ? state.currentText : nil, newPassword, false)
    }

    let arguments = TelesrvLoginPasswordControllerArguments(updateFieldText: { field, text in
        updateState { state in
            var state = state
            switch field {
            case .current:
                state.currentText = text
            case .new:
                state.newText = text
            case .confirmation:
                state.confirmationText = text
            }
            return state
        }
    }, selectNextInputItem: { tag in
        selectNextInputItemImpl?(tag)
    }, save: {
        saveImpl()
    }, remove: {
        let state = stateValue.with { $0 }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if state.currentText.isEmpty {
            presentAlert(presentationData.strings.Telesrv_LoginPasswordSettings_EnterCurrent)
            return
        }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: presentationData.strings.Telesrv_LoginPasswordSettings_RemoveConfirmation, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Telesrv_LoginPasswordSettings_RemoveAction, action: {
                perform(state.currentText, nil, false)
            })
        ]))
    }, forgot: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: presentationData.strings.Telesrv_LoginPasswordSettings_ForgotText, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Telesrv_LoginPasswordSettings_ResetAction, action: {
                guard let newPassword = validatedNewPassword() else {
                    selectNextInputItemImpl?(TelesrvLoginPasswordEntryTag.current)
                    return
                }
                perform(nil, newPassword, true)
            })
        ]))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightNavigationButton: ItemListNavigationButton
        if state.saving {
            rightNavigationButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else {
            let enabled = !state.newText.isEmpty && (!state.hasPassword || !state.currentText.isEmpty)
            rightNavigationButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: enabled, action: {
                saveImpl()
            })
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.Telesrv_LoginPasswordSettings_Title), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: telesrvLoginPasswordControllerEntries(presentationData: presentationData, state: state), style: .blocks, focusItemTag: state.hasPassword ? TelesrvLoginPasswordEntryTag.current : TelesrvLoginPasswordEntryTag.new, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionsDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentToastImpl = { [weak controller] text in
        guard let navigationController = controller?.navigationController as? NavigationController else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        navigationController.presentOverlay(controller: UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), action: { _ in return false }), inGlobal: false, blockInteraction: false)
    }
    selectNextInputItemImpl = { [weak controller] currentTag in
        guard let controller = controller else {
            return
        }
        var resultItemNode: ItemListSingleLineInputItemNode?
        var focusOnNext = false
        let _ = controller.frameForItemNode({ itemNode in
            if let itemNode = itemNode as? ItemListSingleLineInputItemNode, let tag = itemNode.tag {
                if focusOnNext && resultItemNode == nil {
                    resultItemNode = itemNode
                    return true
                } else if currentTag.isEqual(to: tag) {
                    focusOnNext = true
                }
            }
            return false
        })
        if let resultItemNode = resultItemNode {
            resultItemNode.focus()
        }
    }
    return controller
}
