import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TextFormat
import Markdown
import SolidRoundedButtonNode
import AuthorizationUtils

private func roundCorners(diameter: CGFloat) -> UIImage {
    UIGraphicsBeginImageContextWithOptions(CGSize(width: diameter, height: diameter), false, 0.0)
    let context = UIGraphicsGetCurrentContext()!
    context.setBlendMode(.copy)
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter)))
    context.setFillColor(UIColor.clear.cgColor)
    context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter)))
    let image = UIGraphicsGetImageFromCurrentImageContext()!.stretchableImage(withLeftCapWidth: Int(diameter / 2.0), topCapHeight: Int(diameter / 2.0))
    UIGraphicsEndImageContext()
    return image
}

private func makeSignUpPasswordField(theme: PresentationTheme, placeholder: String, returnKeyType: UIReturnKeyType) -> TextFieldNode {
    let field = TextFieldNode()
    field.textField.font = Font.regular(20.0)
    field.textField.textColor = theme.list.itemPrimaryTextColor
    field.textField.textAlignment = .natural
    field.textField.returnKeyType = returnKeyType
    field.textField.isSecureTextEntry = true
    field.textField.textContentType = .newPassword
    field.textField.attributedPlaceholder = NSAttributedString(string: placeholder, font: Font.regular(20.0), textColor: theme.list.itemPlaceholderTextColor)
    field.textField.autocapitalizationType = .none
    field.textField.autocorrectionType = .no
    field.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
    field.textField.tintColor = theme.list.itemAccentColor
    return field
}

final class AuthorizationSequenceSignUpControllerNode: ASDisplayNode, UITextFieldDelegate {
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    private let addPhoto: () -> Void
    /// Sign-up with a telesrv login password: the page also asks for the password, twice.
    private let loginPasswordNumber: String?
    private let titleText: String

    private let titleNode: ASTextNode
    private let currentOptionNode: ASTextNode
    private let termsNode: ImmediateTextNode
    
    private let firstNameField: TextFieldNode
    private let lastNameField: TextFieldNode
    private let firstSeparatorNode: ASDisplayNode
    private let lastSeparatorNode: ASDisplayNode
    private let passwordField: TextFieldNode
    private let passwordSeparatorNode: ASDisplayNode
    private let confirmPasswordField: TextFieldNode
    private let confirmPasswordSeparatorNode: ASDisplayNode
    private let currentPhotoNode: ASImageNode
    private let addPhotoButton: HighlightableButtonNode
    private let proceedNode: SolidRoundedButtonNode
    
    private var layoutArguments: (ContainerViewLayout, CGFloat)?
    
    private let appearanceTimestamp = CACurrentMediaTime()
    
    var currentName: (String, String) {
        return (self.firstNameField.textField.text ?? "", self.lastNameField.textField.text ?? "")
    }

    var currentPassword: (String, String) {
        return (self.passwordField.textField.text ?? "", self.confirmPasswordField.textField.text ?? "")
    }

    var currentPhoto: UIImage? = nil {
        didSet {
            if let currentPhoto = self.currentPhoto {
                self.currentPhotoNode.image = generateImage(CGSize(width: 110.0, height: 110.0), contextGenerator: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    context.setBlendMode(.copy)
                    context.draw(currentPhoto.cgImage!, in: CGRect(origin: CGPoint(), size: size))
                    context.setBlendMode(.destinationOut)
                    context.draw(roundCorners(diameter: size.width).cgImage!, in: CGRect(origin: CGPoint(), size: size))
                })
            } else {
                self.currentPhotoNode.image = nil
            }
        }
    }
    
    var signUpWithName: ((String, String) -> Void)?
    var openTermsOfService: (() -> Void)?
    
    var inProgress: Bool = false {
        didSet {
            self.firstNameField.alpha = self.inProgress ? 0.6 : 1.0
            self.lastNameField.alpha = self.inProgress ? 0.6 : 1.0
            self.passwordField.alpha = self.inProgress ? 0.6 : 1.0
            self.confirmPasswordField.alpha = self.inProgress ? 0.6 : 1.0
            
            if self.inProgress != oldValue {
                if self.inProgress {
                    self.proceedNode.transitionToProgress()
                } else {
                    self.proceedNode.transitionFromProgress()
                }
            }
        }
    }
    
    init(theme: PresentationTheme, strings: PresentationStrings, loginPasswordNumber: String?, addPhoto: @escaping () -> Void) {
        self.theme = theme
        self.strings = strings
        self.addPhoto = addPhoto
        self.loginPasswordNumber = loginPasswordNumber
        self.titleText = loginPasswordNumber != nil ? strings.Telesrv_SignUp_Title : strings.Login_InfoTitle

        self.titleNode = ASTextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        self.titleNode.attributedText = NSAttributedString(string: self.titleText, font: Font.semibold(28.0), textColor: theme.list.itemPrimaryTextColor)
        self.titleNode.accessibilityIdentifier = "Auth.SetName.Title"

        self.currentOptionNode = ASTextNode()
        self.currentOptionNode.isUserInteractionEnabled = false
        self.currentOptionNode.displaysAsynchronously = false
        let noticeText: String
        if let loginPasswordNumber = loginPasswordNumber {
            noticeText = strings.Telesrv_SignUp_Text(loginPasswordNumber).string
        } else {
            noticeText = strings.Login_InfoHelp
        }
        self.currentOptionNode.attributedText = NSAttributedString(string: noticeText, font: Font.regular(16.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)
        
        self.termsNode = ImmediateTextNode()
        self.termsNode.textAlignment = .center
        self.termsNode.maximumNumberOfLines = 0
        self.termsNode.displaysAsynchronously = false
        let body = MarkdownAttributeSet(font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)
        let link = MarkdownAttributeSet(font: Font.regular(13.0), textColor: theme.list.itemAccentColor, additionalAttributes: [TelegramTextAttributes.URL: ""])
        self.termsNode.attributedText = parseMarkdownIntoAttributedString(strings.Login_TermsOfServiceLabel.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "]", with: "]()"), attributes: MarkdownAttributes(body: body, bold: body, link: link, linkAttribute: { _ in nil }), textAlignment: .center)
        
        self.firstSeparatorNode = ASDisplayNode()
        self.firstSeparatorNode.isLayerBacked = true
        self.firstSeparatorNode.backgroundColor = self.theme.list.itemPlainSeparatorColor
        
        self.lastSeparatorNode = ASDisplayNode()
        self.lastSeparatorNode.isLayerBacked = true
        self.lastSeparatorNode.backgroundColor = self.theme.list.itemPlainSeparatorColor
        
        self.firstNameField = TextFieldNode()
        self.firstNameField.textField.font = Font.regular(20.0)
        self.firstNameField.textField.textColor = self.theme.list.itemPrimaryTextColor
        self.firstNameField.textField.textAlignment = .natural
        self.firstNameField.textField.returnKeyType = .next
        self.firstNameField.textField.attributedPlaceholder = NSAttributedString(string: self.strings.UserInfo_FirstNamePlaceholder, font: self.firstNameField.textField.font, textColor: self.theme.list.itemPlaceholderTextColor)
        self.firstNameField.textField.autocapitalizationType = .words
        self.firstNameField.textField.autocorrectionType = .no
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            self.firstNameField.textField.textContentType = .givenName
        }
        self.firstNameField.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.firstNameField.textField.tintColor = theme.list.itemAccentColor
        self.firstNameField.textField.accessibilityIdentifier = "Auth.SetName.FirstNameField"

        self.lastNameField = TextFieldNode()
        self.lastNameField.textField.font = Font.regular(20.0)
        self.lastNameField.textField.textColor = self.theme.list.itemPrimaryTextColor
        self.lastNameField.textField.textAlignment = .natural
        self.lastNameField.textField.returnKeyType = .done
        self.lastNameField.textField.attributedPlaceholder = NSAttributedString(string: strings.UserInfo_LastNamePlaceholder, font: self.lastNameField.textField.font, textColor: self.theme.list.itemPlaceholderTextColor)
        self.lastNameField.textField.autocapitalizationType = .words
        self.lastNameField.textField.autocorrectionType = .no
        if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
            self.lastNameField.textField.textContentType = .familyName
        }
        self.lastNameField.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.lastNameField.textField.tintColor = theme.list.itemAccentColor
        self.lastNameField.textField.accessibilityIdentifier = "Auth.SetName.LastNameField"

        self.passwordSeparatorNode = ASDisplayNode()
        self.passwordSeparatorNode.isLayerBacked = true
        self.passwordSeparatorNode.backgroundColor = theme.list.itemPlainSeparatorColor

        self.confirmPasswordSeparatorNode = ASDisplayNode()
        self.confirmPasswordSeparatorNode.isLayerBacked = true
        self.confirmPasswordSeparatorNode.backgroundColor = theme.list.itemPlainSeparatorColor

        self.passwordField = makeSignUpPasswordField(theme: theme, placeholder: strings.Telesrv_SignUp_PasswordPlaceholder, returnKeyType: .next)
        self.confirmPasswordField = makeSignUpPasswordField(theme: theme, placeholder: strings.Telesrv_SignUp_ConfirmPasswordPlaceholder, returnKeyType: .done)
        if loginPasswordNumber != nil {
            self.lastNameField.textField.returnKeyType = .next
        }

        self.currentPhotoNode = ASImageNode()
        self.currentPhotoNode.isUserInteractionEnabled = false
        self.currentPhotoNode.displaysAsynchronously = false
        self.currentPhotoNode.displayWithoutProcessing = true
        
        self.addPhotoButton = HighlightableButtonNode()
        self.addPhotoButton.setImage(generateTintedImage(image: UIImage(bundleImageName: "Avatar/EditAvatarIconLarge"), color: self.theme.list.itemAccentColor), for: .normal)
        self.addPhotoButton.setBackgroundImage(generateFilledCircleImage(diameter: 110.0, color: self.theme.list.itemAccentColor.withAlphaComponent(0.1), strokeColor: nil, strokeWidth: nil, backgroundColor: nil), for: .normal)
                
        self.addPhotoButton.addSubnode(self.currentPhotoNode)
        self.addPhotoButton.allowsGroupOpacity = true
        
        self.proceedNode = SolidRoundedButtonNode(title: self.strings.Login_Continue, theme: SolidRoundedButtonTheme(theme: self.theme), glass: false, height: 50.0, cornerRadius: 50.0 * 0.5)
        self.proceedNode.progressType = .embedded
        self.proceedNode.accessibilityIdentifier = "Auth.SetName.ContinueButton"
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.backgroundColor = self.theme.list.plainBackgroundColor
        
        self.firstNameField.textField.delegate = self
        self.lastNameField.textField.delegate = self
        self.passwordField.textField.delegate = self
        self.confirmPasswordField.textField.delegate = self

        self.addSubnode(self.firstSeparatorNode)
        self.addSubnode(self.lastSeparatorNode)
        self.addSubnode(self.firstNameField)
        self.addSubnode(self.lastNameField)
        if loginPasswordNumber != nil {
            self.addSubnode(self.passwordSeparatorNode)
            self.addSubnode(self.confirmPasswordSeparatorNode)
            self.addSubnode(self.passwordField)
            self.addSubnode(self.confirmPasswordField)
        }
        self.addSubnode(self.titleNode)
        self.addSubnode(self.currentOptionNode)
        self.addSubnode(self.termsNode)
        self.termsNode.isHidden = true
        self.addSubnode(self.addPhotoButton)
        self.addSubnode(self.proceedNode)
        
        self.addPhotoButton.addTarget(self, action: #selector(self.addPhotoPressed), forControlEvents: .touchUpInside)
        
        self.termsNode.linkHighlightColor = self.theme.list.itemAccentColor.withAlphaComponent(0.2)
        self.termsNode.highlightAttributeAction = { attributes in
            if let _ = attributes[NSAttributedString.Key(rawValue: TelegramTextAttributes.URL)] {
                return NSAttributedString.Key(rawValue: TelegramTextAttributes.URL)
            } else {
                return nil
            }
        }
        self.termsNode.tapAttributeAction = { [weak self] attributes, _ in
            if let _ = attributes[NSAttributedString.Key(rawValue: TelegramTextAttributes.URL)] {
                self?.openTermsOfService?()
            }
        }
        
        self.proceedNode.pressed = { [weak self] in
            if let strongSelf = self {
                let name = strongSelf.currentName
                strongSelf.signUpWithName?(name.0, name.1)
            }
        }
    }
    
    func updateData(firstName: String, lastName: String, hasTermsOfService: Bool) {
        self.termsNode.isHidden = !hasTermsOfService
        self.firstNameField.textField.attributedText = NSAttributedString(string: firstName, font: Font.regular(20.0), textColor: self.theme.list.itemPlaceholderTextColor)
        self.lastNameField.textField.attributedText = NSAttributedString(string: lastName, font: Font.regular(20.0), textColor: self.theme.list.itemPlaceholderTextColor)
        
        if let (layout, navigationHeight) = self.layoutArguments {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .immediate)
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let previousInputHeight = self.layoutArguments?.0.inputHeight ?? 0.0
        let newInputHeight = layout.inputHeight ?? 0.0
        
        self.layoutArguments = (layout, navigationBarHeight)
        
        var layout = layout
        if CACurrentMediaTime() - self.appearanceTimestamp < 2.0, newInputHeight < previousInputHeight {
            layout = layout.withUpdatedInputHeight(previousInputHeight)
        }
        
        // iPhone Duo: beside a side strip the content keeps to the band between the side insets. With equal
        // insets (every other phone) it keeps the full width.
        let insetsDiffer = layout.safeInsets.left != layout.safeInsets.right
        let bandMinX: CGFloat = insetsDiffer ? layout.safeInsets.left : 0.0
        let bandWidth: CGFloat = insetsDiffer ? layout.size.width - layout.safeInsets.left - layout.safeInsets.right : layout.size.width
        
        let maximumWidth: CGFloat = min(430.0, bandWidth)
        
        // The bottom button spans iPhone Duo's side strip; it keeps clear only of a corner block at the bottom.
        let bottomSideInsets = layout.bottomEdgeSideInsets()
        let bottomBandMinX: CGFloat = insetsDiffer ? bottomSideInsets.left : 0.0
        let bottomBandWidth: CGFloat = insetsDiffer ? layout.size.width - bottomSideInsets.left - bottomSideInsets.right : layout.size.width
        let bottomMaximumWidth: CGFloat = min(430.0, bottomBandWidth)
        
        var insets = layout.insets(options: [.statusBar])
        if let inputHeight = layout.inputHeight {
            insets.bottom = max(inputHeight, layout.standardInputHeight)
        }
        
        let additionalBottomInset: CGFloat = layout.size.width > 320.0 ? 90.0 : 10.0
                
        self.titleNode.attributedText = NSAttributedString(string: self.titleText, font: Font.semibold(28.0), textColor: self.theme.list.itemPrimaryTextColor)
        let titleSize = self.titleNode.measure(CGSize(width: maximumWidth, height: CGFloat.greatestFiniteMagnitude))
        
        let fieldHeight: CGFloat = 54.0
        
        let sideInset: CGFloat = 24.0
        let innerInset: CGFloat = 16.0
        
        let noticeSize = self.currentOptionNode.measure(CGSize(width: maximumWidth - 28.0, height: CGFloat.greatestFiniteMagnitude))
        let termsSize = self.termsNode.updateLayout(CGSize(width: maximumWidth - 28.0, height: CGFloat.greatestFiniteMagnitude))
        
        let avatarSize: CGSize = CGSize(width: 110.0, height: 110.0)
        var items: [AuthorizationLayoutItem] = []
        items.append(AuthorizationLayoutItem(node: self.addPhotoButton, size: avatarSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 16.0, maxValue: 16.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        self.currentPhotoNode.frame = CGRect(origin: CGPoint(), size: avatarSize)
        
        items.append(AuthorizationLayoutItem(node: self.titleNode, size: titleSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 18.0, maxValue: 18.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.currentOptionNode, size: noticeSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 20.0, maxValue: 20.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        
        items.append(AuthorizationLayoutItem(node: self.firstNameField, size: CGSize(width: bandWidth - (sideInset + innerInset) * 2.0, height: fieldHeight), spacingBefore: AuthorizationLayoutItemSpacing(weight: 32.0, maxValue: 60.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.firstSeparatorNode, size: CGSize(width: bandWidth - sideInset * 2.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        
        items.append(AuthorizationLayoutItem(node: self.lastNameField, size: CGSize(width: bandWidth - (sideInset + innerInset) * 2.0, height: fieldHeight), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        items.append(AuthorizationLayoutItem(node: self.lastSeparatorNode, size: CGSize(width: bandWidth - sideInset * 2.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))

        if self.loginPasswordNumber != nil {
            items.append(AuthorizationLayoutItem(node: self.passwordField, size: CGSize(width: bandWidth - (sideInset + innerInset) * 2.0, height: fieldHeight), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            items.append(AuthorizationLayoutItem(node: self.passwordSeparatorNode, size: CGSize(width: bandWidth - sideInset * 2.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            items.append(AuthorizationLayoutItem(node: self.confirmPasswordField, size: CGSize(width: bandWidth - (sideInset + innerInset) * 2.0, height: fieldHeight), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
            items.append(AuthorizationLayoutItem(node: self.confirmPasswordSeparatorNode, size: CGSize(width: bandWidth - sideInset * 2.0, height: UIScreenPixel), spacingBefore: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        }

        items.append(AuthorizationLayoutItem(node: self.termsNode, size: termsSize, spacingBefore: AuthorizationLayoutItemSpacing(weight: 48.0, maxValue: 100.0), spacingAfter: AuthorizationLayoutItemSpacing(weight: 0.0, maxValue: 0.0)))
        
        if layout.size.width > 320.0 {
            self.proceedNode.isHidden = false
            
            let inset: CGFloat = 24.0
            let proceedHeight = self.proceedNode.updateLayout(width: bottomMaximumWidth - 48.0, transition: transition)
            let proceedSize = CGSize(width: bottomMaximumWidth - 48.0, height: proceedHeight)
            transition.updateFrame(node: self.proceedNode, frame: CGRect(origin: CGPoint(x: bottomBandMinX + floorToScreenPixels((bottomBandWidth - proceedSize.width) / 2.0), y: layout.size.height - insets.bottom - proceedSize.height - inset), size: proceedSize))
        } else {
            insets.top = navigationBarHeight
            self.proceedNode.isHidden = true
        }
        
        let _ = layoutAuthorizationItems(bounds: CGRect(origin: CGPoint(x: bandMinX, y: insets.top), size: CGSize(width: bandWidth, height: layout.size.height - insets.top - insets.bottom - additionalBottomInset)), items: items, transition: transition, failIfDoesNotFit: false)
    }
    
    func activateInput() {
        self.firstNameField.textField.becomeFirstResponder()
    }
    
    func animateError() {
        if self.firstNameField.textField.text == nil || self.firstNameField.textField.text!.isEmpty {
            self.firstNameField.layer.addShakeAnimation()
        }
    }
    
    func animatePasswordError() {
        if (self.passwordField.textField.text ?? "").isEmpty {
            self.passwordField.layer.addShakeAnimation()
            self.passwordField.textField.becomeFirstResponder()
        } else {
            self.confirmPasswordField.textField.text = ""
            self.confirmPasswordField.layer.addShakeAnimation()
            self.confirmPasswordField.textField.becomeFirstResponder()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === self.firstNameField.textField {
            self.lastNameField.textField.becomeFirstResponder()
        } else if self.loginPasswordNumber != nil && textField === self.lastNameField.textField {
            self.passwordField.textField.becomeFirstResponder()
        } else if textField === self.passwordField.textField {
            self.confirmPasswordField.textField.becomeFirstResponder()
        } else {
            let name = self.currentName
            self.signUpWithName?(name.0, name.1)
        }
        return false
    }
    
    @objc private func addPhotoPressed() {
        self.addPhoto()
    }
}
