import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import TelegramPresentationData
import ChatInputAccessoryPanel
import AccountContext
import TelegramCore
import SwiftSignalKit
import ComponentFlow
import Display
import GlassBackgroundComponent
import MultilineTextComponent
import MultilineTextWithEntitiesComponent
import TelegramStringFormatting
import PhotoResources
import TextFormat
import CompositeTextNode
import ChatInterfaceState

private func generateCloseIcon() -> UIImage {
    return generateImage(CGSize(width: 12.0, height: 12.0), contextGenerator: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setBlendMode(.copy)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2.0)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 1.0, y: 1.0))
        context.addLine(to: CGPoint(x: size.width - 1.0, y: size.height - 1.0))
        context.strokePath()
        context.move(to: CGPoint(x: size.width - 1.0, y: 1.0))
        context.addLine(to: CGPoint(x: 1.0, y: size.height - 1.0))
        context.strokePath()
    })!.withRenderingMode(.alwaysTemplate)
}

private func textStringForForwardedMessage(_ message: EngineMessage, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> (text: NSAttributedString, entities: [MessageTextEntity], isMedia: Bool) {
    if let richText = message.richText {
        return (richText.instantPage.previewAttributedText(strings: strings, dateTimeFormat: dateTimeFormat, associatedMedia: message.associatedMedia), [], false)
    }
    for media in message.media {
        switch media {
        case _ as TelegramMediaImage:
            return (NSAttributedString(string: strings.Message_Photo), [], true)
        case let file as TelegramMediaFile:
            if file.isVideoSticker || file.isAnimatedSticker {
                return (NSAttributedString(string: strings.Message_Sticker), [], true)
            }
            var fileName: String = strings.Message_File
            for attribute in file.attributes {
                switch attribute {
                case .Sticker:
                    return (NSAttributedString(string: strings.Message_Sticker), [], true)
                case let .FileName(name):
                    fileName = name
                case let .Audio(isVoice, _, title, performer, _):
                    if isVoice {
                        return (NSAttributedString(string: strings.Message_Audio), [], true)
                    } else {
                        if let title = title, let performer = performer, !title.isEmpty, !performer.isEmpty {
                            return (NSAttributedString(string: title + " — " + performer), [], true)
                        } else if let title = title, !title.isEmpty {
                            return (NSAttributedString(string: title), [], true)
                        } else if let performer = performer, !performer.isEmpty {
                            return (NSAttributedString(string: performer), [], true)
                        } else {
                            return (NSAttributedString(string: strings.Message_Audio), [], true)
                        }
                    }
                case .Video:
                    if file.isAnimated {
                        return (NSAttributedString(string: strings.Message_Animation), [], true)
                    } else {
                        return (NSAttributedString(string: strings.Message_Video), [], true)
                    }
                default:
                    break
                }
            }
            return (NSAttributedString(string: fileName), [], true)
        case _ as TelegramMediaContact:
            return (NSAttributedString(string: strings.Message_Contact), [], true)
        case let game as TelegramMediaGame:
            return (NSAttributedString(string: game.title), [], true)
        case _ as TelegramMediaMap:
            return (NSAttributedString(string: strings.Message_Location), [], true)
        case _ as TelegramMediaAction:
            return (NSAttributedString(), [], true)
        case _ as TelegramMediaPoll:
            return (NSAttributedString(string: strings.ForwardedPolls(1)), [], true)
        case let todo as TelegramMediaTodo:
            return (NSAttributedString(string: todo.text), [], true)
        case let dice as TelegramMediaDice:
            return (NSAttributedString(string: dice.emoji), [], true)
        case let invoice as TelegramMediaInvoice:
            return (NSAttributedString(string: invoice.title), [], true)
        default:
            break
        }
    }
    return (NSAttributedString(string: message.text), message._asMessage().textEntitiesAttribute?.entities ?? [], false)
}

public final class ChatInputMessageAccessoryPanel: Component {
    public typealias EnvironmentType = ChatInputAccessoryPanelEnvironment

    public enum Contents: Equatable {
        public final class Reply: Equatable {
            public let id: EngineMessage.Id
            public let quote: EngineMessageReplyQuote?
            public let innerSubject: EngineMessageReplyInnerSubject?
            public let message: EngineMessage?
            public let extraIds: [EngineMessage.Id]

            public init(id: EngineMessage.Id, quote: EngineMessageReplyQuote?, innerSubject: EngineMessageReplyInnerSubject?, message: EngineMessage?, extraIds: [EngineMessage.Id] = []) {
                self.id = id
                self.quote = quote
                self.innerSubject = innerSubject
                self.message = message
                self.extraIds = extraIds
            }

            public static func ==(lhs: Reply, rhs: Reply) -> Bool {
                if lhs.id != rhs.id {
                    return false
                }
                if lhs.extraIds != rhs.extraIds {
                    return false
                }
                if lhs.quote != rhs.quote {
                    return false
                }
                if lhs.innerSubject != rhs.innerSubject {
                    return false
                }
                if lhs.message?.id != rhs.message?.id {
                    return false
                }
                if lhs.message?.stableVersion != rhs.message?.stableVersion {
                    return false
                }
                return true
            }
        }

        public final class Edit: Equatable {
            public let id: EngineMessage.Id
            public let message: EngineMessage?

            public init(id: EngineMessage.Id, message: EngineMessage?) {
                self.id = id
                self.message = message
            }

            public static func ==(lhs: Edit, rhs: Edit) -> Bool {
                if lhs.id != rhs.id {
                    return false
                }
                if lhs.message?.id != rhs.message?.id {
                    return false
                }
                if lhs.message?.stableVersion != rhs.message?.stableVersion {
                    return false
                }
                return true
            }
        }
        
        public final class Forward: Equatable {
            public let messageIds: [EngineMessage.Id]
            public let forwardOptionsState: ChatInterfaceForwardOptionsState?
            
            public init(messageIds: [EngineMessage.Id], forwardOptionsState: ChatInterfaceForwardOptionsState?) {
                self.messageIds = messageIds
                self.forwardOptionsState = forwardOptionsState
            }
            
            public static func ==(lhs: Forward, rhs: Forward) -> Bool {
                if lhs.messageIds != rhs.messageIds {
                    return false
                }
                if lhs.forwardOptionsState != rhs.forwardOptionsState {
                    return false
                }
                return true
            }
        }
        
        public final class LinkPreview: Equatable {
            public let url: String
            public let webpage: TelegramMediaWebpage
            
            public init(url: String, webpage: TelegramMediaWebpage) {
                self.url = url
                self.webpage = webpage
            }
            
            public static func ==(lhs: LinkPreview, rhs: LinkPreview) -> Bool {
                if lhs.url != rhs.url {
                    return false
                }
                if lhs.webpage != rhs.webpage {
                    return false
                }
                return true
            }
        }
        
        public final class SuggestPost: Equatable {
            public let state: ChatInterfaceState.PostSuggestionState
            
            public init(state: ChatInterfaceState.PostSuggestionState) {
                self.state = state
            }
            
            public static func ==(lhs: SuggestPost, rhs: SuggestPost) -> Bool {
                if lhs.state != rhs.state {
                    return false
                }
                return true
            }
        }

        case reply(Reply)
        case edit(Edit)
        case forward(Forward)
        case linkPreview(LinkPreview)
        case suggestPost(SuggestPost)
    }
    
    let context: AccountContext
    let contents: Contents
    let chatPeerId: EnginePeer.Id?
    let action: ((UIView) -> Void)?
    let longPressAction: ((UIView) -> Void)?
    let dismiss: (UIView) -> Void
    let requestLayout: (() -> Void)?
    let dismissDeckCard: ((EngineMessage.Id) -> Void)?

    public init(
        context: AccountContext,
        contents: Contents,
        chatPeerId: EnginePeer.Id?,
        action: ((UIView) -> Void)?,
        longPressAction: ((UIView) -> Void)? = nil,
        dismiss: @escaping (UIView) -> Void,
        requestLayout: (() -> Void)? = nil,
        dismissDeckCard: ((EngineMessage.Id) -> Void)? = nil
    ) {
        self.context = context
        self.contents = contents
        self.chatPeerId = chatPeerId
        self.action = action
        self.longPressAction = longPressAction
        self.dismiss = dismiss
        self.requestLayout = requestLayout
        self.dismissDeckCard = dismissDeckCard
    }

    public static func ==(lhs: ChatInputMessageAccessoryPanel, rhs: ChatInputMessageAccessoryPanel) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.contents != rhs.contents {
            return false
        }
        if lhs.chatPeerId != rhs.chatPeerId {
            return false
        }
        if (lhs.action == nil) != (rhs.action == nil) {
            return false
        }
        if (lhs.longPressAction == nil) != (rhs.longPressAction == nil) {
            return false
        }
        return true
    }
    
    public final class View: UIView, ChatInputAccessoryPanelView {
        private let closeButton: HighlightTrackingButton
        private let closeButtonIcon: GlassBackgroundView.ContentImageView
        private let longPressGestureRecognizer: UILongPressGestureRecognizer
        
        private let lineView: UIImageView
        private let titleNode: CompositeTextNode
        private let text = ComponentView<Empty>()
        private let tintText = ComponentView<Empty>()
        
        public let contentTintView: UIView
        
        private var isUpdating: Bool = false
        private var component: ChatInputMessageAccessoryPanel?
        private weak var state: EmptyComponentState?
        private var environment: EnvironmentType?
        
        private var messages: [EngineMessage] = []
        private var contentDisposable: Disposable?
        private var subscribedMessageIds: [EngineMessage.Id]?
        
        private var deckMessageIds: [EngineMessage.Id] = []
        private var deckActiveIndex: Int = 0
        private let deckCounterButton: HighlightTrackingButton
        private let deckCounterLabel: UILabel
        private var isDeckCardAppearancePending = false
        private var isDeckExpanded = false
        private var deckMessages: [EngineMessage.Id: EngineMessage] = [:]
        private var deckDisposable: Disposable?
        private var deckEdgeViews: [UIView] = []
        private var deckRowViews: [EngineMessage.Id: DeckPanelRowView] = [:]
        // Previews of the deck's photos and videos, rendered ahead so the list shows them as it opens
        private var deckThumbnailImages: [EngineMedia.Id: UIImage] = [:]
        private var deckThumbnailLoading = Set<EngineMedia.Id>()
        private let deckThumbnailDisposables = DisposableDict<EngineMedia.Id>()
        private let deckThumbnailLocalDisposables = DisposableDict<EngineMedia.Id>()
        private var isCardHiddenByDeckList = false
        private var lastPanelHeight: CGFloat?
        // The deck, or the single reply left in an open list after the rest was removed
        private var deckListMessageIds: [EngineMessage.Id] = []
        
        private var inlineTextStarImage: UIImage?
        private var inlineTextTonImage: (UIImage, UIColor)?
        
        public var transitionData: ChatInputAccessoryPanelTransitionData? {
            guard let textView = self.text.view else {
                return nil
            }
            return ChatInputAccessoryPanelTransitionData(
                titleView: self.titleNode.view,
                textView: textView,
                lineView: self.lineView,
                imageView: nil
            )
        }
        
        public var storedFrameBeforeDismissed: CGRect?
        public private(set) var needsLayoutUpdate = false
        
        override public init(frame: CGRect) {
            self.contentTintView = UIView()
            
            self.closeButton = HighlightTrackingButton()
            self.closeButtonIcon = GlassBackgroundView.ContentImageView()
            self.longPressGestureRecognizer = UILongPressGestureRecognizer()
            
            self.lineView = UIImageView()
            self.titleNode = CompositeTextNode()
            self.titleNode.displaysAsynchronously = false
            
            self.deckCounterButton = HighlightTrackingButton()
            self.deckCounterButton.isHidden = true
            self.deckCounterLabel = UILabel()
            self.deckCounterLabel.textAlignment = .center
            self.deckCounterLabel.clipsToBounds = true
            self.deckCounterLabel.isUserInteractionEnabled = false
            self.deckCounterLabel.font = Font.with(size: 12.0, weight: .semibold, traits: .monospacedNumbers)
            self.deckCounterLabel.textColor = .white
            self.deckCounterButton.addSubview(self.deckCounterLabel)
            
            super.init(frame: frame)
            
            self.addSubview(self.lineView)
            self.addSubview(self.titleNode.view)
            
            self.addSubview(self.closeButtonIcon)
            self.contentTintView.addSubview(self.closeButtonIcon.tintMask)
            self.addSubview(self.closeButton)
            self.addSubview(self.deckCounterButton)
            
            self.closeButton.addTarget(self, action: #selector(self.closeButtonPressed), for: .touchUpInside)
            self.deckCounterButton.addTarget(self, action: #selector(self.deckCounterPressed), for: .touchUpInside)
            
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))

            self.longPressGestureRecognizer.addTarget(self, action: #selector(self.longPressGesture(_:)))
            self.longPressGestureRecognizer.isEnabled = false
            self.addGestureRecognizer(self.longPressGestureRecognizer)
        }
        
        required public init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            self.contentDisposable?.dispose()
            self.deckDisposable?.dispose()
            self.deckThumbnailDisposables.dispose()
            self.deckThumbnailLocalDisposables.dispose()
            if let recognizer = self.deckDismissGestureRecognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
        
        @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
            guard let component = self.component else {
                return
            }
            if case .ended = recognizer.state {
                if !self.deckMessageIds.isEmpty || self.isDeckExpanded {
                    if self.isDeckExpanded {
                        self.setDeckExpanded(false)
                    } else {
                        self.deckCounterPressed()
                    }
                    return
                }
                component.action?(self)
            }
        }
        
        private var deckDismissGestureRecognizer: DeckDismissGestureRecognizer?
        
        // A recognizer on the window rather than a view over it: the window hit-tests through its own host
        // and never reaches views added to it directly
        private func updateDeckDismissRecognizer(isActive: Bool) {
            if isActive, let window = self.window {
                if let current = self.deckDismissGestureRecognizer, current.view === window {
                    return
                }
                self.deckDismissGestureRecognizer.flatMap { $0.view?.removeGestureRecognizer($0) }
                let recognizer = DeckDismissGestureRecognizer()
                recognizer.panelView = self
                recognizer.dismiss = { [weak self] in
                    guard let self, self.isDeckExpanded else {
                        return
                    }
                    self.setDeckExpanded(false)
                }
                window.addGestureRecognizer(recognizer)
                self.deckDismissGestureRecognizer = recognizer
            } else if let recognizer = self.deckDismissGestureRecognizer {
                self.deckDismissGestureRecognizer = nil
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
        
        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if self.window == nil {
                self.updateDeckDismissRecognizer(isActive: false)
            }
        }
        
        @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
            guard let component = self.component else {
                return
            }
            if case .began = recognizer.state {
                if !self.deckMessageIds.isEmpty {
                    if !self.isDeckExpanded {
                        HapticFeedback().impact(.light)
                        self.layer.animateSpring(from: 0.96 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                        self.setDeckExpanded(true)
                    }
                    return
                }
                component.longPressAction?(self)
            }
        }

        private func setDeckExpanded(_ isExpanded: Bool) {
            guard let component = self.component else {
                return
            }
            if isExpanded && self.deckActiveIndex != 0 {
                self.deckActiveIndex = 0
            }
            self.isDeckExpanded = isExpanded
            if let requestLayout = component.requestLayout {
                // The host does not render an unchanged component again
                self.needsLayoutUpdate = true
                requestLayout()
            } else {
                self.state?.updated(transition: .spring(duration: 0.4), isLocal: true)
            }
        }
        
        @objc private func deckCounterPressed() {
            guard self.deckMessageIds.count > 1 else {
                return
            }
            if self.isDeckExpanded {
                self.setDeckExpanded(false)
                return
            }
            self.deckActiveIndex = (self.deckActiveIndex + 1) % self.deckMessageIds.count
            self.animateDeckCardChange(isRemoval: false)
            
            if !self.isUpdating {
                self.state?.updated(transition: .immediate, isLocal: true)
            }
        }
        
        // The visible card is swiped away (or shrinks away when removed); the next one rises once its message is loaded
        private func animateDeckCardChange(isRemoval: Bool) {
            for contentView in [self.titleNode.view, self.text.view].compactMap({ $0 }) {
                if let snapshotView = contentView.snapshotView(afterScreenUpdates: false) {
                    snapshotView.frame = contentView.frame
                    self.addSubview(snapshotView)
                    if isRemoval {
                        snapshotView.layer.anchorPoint = CGPoint(x: 0.0, y: 0.5)
                        snapshotView.frame = contentView.frame
                    }
                    UIView.animate(withDuration: isRemoval ? 0.2 : 0.25, delay: 0.0, options: [.curveEaseIn], animations: {
                        snapshotView.transform = isRemoval ? CGAffineTransform(scaleX: 0.85, y: 0.85) : CGAffineTransform(translationX: 0.0, y: -14.0)
                        snapshotView.alpha = 0.0
                    }, completion: { _ in
                        snapshotView.removeFromSuperview()
                    })
                }
                contentView.alpha = 0.0
            }
            self.isDeckCardAppearancePending = true
            Queue.mainQueue().after(0.35) { [weak self] in
                guard let self, self.isDeckCardAppearancePending else {
                    return
                }
                self.isDeckCardAppearancePending = false
                for contentView in [self.titleNode.view, self.text.view].compactMap({ $0 }) {
                    contentView.alpha = 1.0
                    contentView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                }
            }
            self.deckCounterLabel.layer.animateSpring(from: 0.8 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
        }
        
        @objc private func closeButtonPressed() {
            guard let component = self.component else {
                return
            }
            if !self.deckMessageIds.isEmpty, let dismissDeckCard = component.dismissDeckCard {
                dismissDeckCard(self.deckMessageIds[self.deckActiveIndex])
                return
            }
            component.dismiss(self)
        }
        
        // A load now and then never reports back; one that has produced nothing after a moment is started again
        private func loadDeckThumbnail(_ thumbnail: DeckPanelThumbnail, side: CGFloat, attempt: Int) {
            let mediaId = thumbnail.mediaId
            let boundingSize = CGSize(width: side, height: side)
            let thumbnailArguments = TransformImageArguments(corners: ImageCorners(radius: 4.0), imageSize: thumbnail.dimensions.aspectFilled(boundingSize), boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets())
            if attempt < 10 {
                Queue.mainQueue().after(0.4, { [weak self] in
                    guard let self, self.deckThumbnailImages[mediaId] == nil, self.deckThumbnailLoading.contains(mediaId) else {
                        return
                    }
                    self.loadDeckThumbnail(thumbnail, side: side, attempt: attempt + 1)
                })
            }
            if let localData = thumbnail.localData {
                self.deckThumbnailLocalDisposables.set((localData
                |> map { data -> UIImage? in
                    guard let source = UIImage(data: data), source.size.width > 0.0, source.size.height > 0.0 else {
                        return nil
                    }
                    let scale = max(boundingSize.width / source.size.width, boundingSize.height / source.size.height)
                    let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = UIScreenScale
                    return UIGraphicsImageRenderer(size: boundingSize, format: format).image { _ in
                        UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: boundingSize), cornerRadius: 4.0).addClip()
                        source.draw(in: CGRect(origin: CGPoint(x: (boundingSize.width - drawSize.width) / 2.0, y: (boundingSize.height - drawSize.height) / 2.0), size: drawSize))
                    }
                }
                ).startStrict(next: { [weak self] image in
                    guard let self, let image, self.deckThumbnailImages[mediaId] == nil else {
                        return
                    }
                    self.deckThumbnailImages[mediaId] = image
                    for rowView in self.deckRowViews.values where rowView.thumbnailMediaId == mediaId {
                        rowView.setThumbnail(image)
                    }
                }), forKey: mediaId)
            }
            self.deckThumbnailDisposables.set((thumbnail.signal
            |> deliverOn(Queue.concurrentDefaultQueue())
            |> map { transform -> UIImage? in
                return transform(thumbnailArguments)?.generateImage()
            }
            |> deliverOnMainQueue).startStrict(next: { [weak self] image in
                guard let self, let image else {
                    return
                }
                self.deckThumbnailImages[mediaId] = image
                for rowView in self.deckRowViews.values where rowView.thumbnailMediaId == mediaId {
                    rowView.setThumbnail(image)
                }
            }), forKey: mediaId)
        }
        
        public func update(component: ChatInputMessageAccessoryPanel, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.isUpdating = true
            self.needsLayoutUpdate = false
            defer {
                self.isUpdating = false
            }
            
            let environment = environment[EnvironmentType.self].value
            
            var updatedDeckMessageIds: [EngineMessage.Id] = []
            if case let .reply(reply) = component.contents, !reply.extraIds.isEmpty {
                updatedDeckMessageIds = [reply.id] + reply.extraIds
            }
            let wasDeckExpanded = self.isDeckExpanded
            if updatedDeckMessageIds != self.deckMessageIds {
                var previousMessageIds = self.deckMessageIds
                if previousMessageIds.isEmpty, let previousComponent = self.component, case let .reply(previousReply) = previousComponent.contents {
                    previousMessageIds = [previousReply.id]
                }
                let previousActiveIndex = self.deckActiveIndex
                let previousActiveId: EngineMessage.Id? = previousActiveIndex < previousMessageIds.count ? previousMessageIds[previousActiveIndex] : nil
                
                var currentMessageIds = updatedDeckMessageIds
                if currentMessageIds.isEmpty, case let .reply(reply) = component.contents {
                    currentMessageIds = [reply.id]
                }
                // Cards were removed from this deck, rather than a new reply set up
                let isSameDeck = currentMessageIds.contains(where: { previousMessageIds.contains($0) })
                
                self.deckMessageIds = updatedDeckMessageIds
                if updatedDeckMessageIds.isEmpty {
                    self.deckActiveIndex = 0
                } else if let previousActiveId, let index = updatedDeckMessageIds.firstIndex(of: previousActiveId) {
                    self.deckActiveIndex = index
                } else if isSameDeck {
                    self.deckActiveIndex = min(previousActiveIndex, updatedDeckMessageIds.count - 1)
                } else {
                    self.deckActiveIndex = 0
                }
                
                if !wasDeckExpanded, isSameDeck, let previousActiveId, !currentMessageIds.contains(previousActiveId) {
                    self.animateDeckCardChange(isRemoval: true)
                }
                // An open list stays open while cards are removed from it, down to the last one
                self.isDeckExpanded = wasDeckExpanded && !currentMessageIds.isEmpty
                if self.isDeckExpanded {
                    self.deckActiveIndex = 0
                }
                self.deckDisposable?.dispose()
                // Remaining rows keep their messages while the new subscription catches up
                self.deckMessages = self.deckMessages.filter { currentMessageIds.contains($0.key) }
                if !updatedDeckMessageIds.isEmpty {
                    self.deckDisposable = (component.context.engine.data.subscribe(
                        EngineDataList(updatedDeckMessageIds.map { id in
                            return TelegramEngine.EngineData.Item.Messages.Message(id: id)
                        })
                    )
                    |> deliverOnMainQueue).startStrict(next: { [weak self] messages in
                        guard let self else {
                            return
                        }
                        var deckMessages: [EngineMessage.Id: EngineMessage] = [:]
                        for message in messages {
                            if let message {
                                deckMessages[message.id] = message
                            }
                        }
                        self.deckMessages = deckMessages
                        if self.isDeckExpanded && !self.isUpdating {
                            self.state?.updated(transition: .immediate, isLocal: true)
                        }
                    })
                }
            }
            
            let messageIds: [EngineMessage.Id]
            switch component.contents {
            case let .edit(edit):
                messageIds = [edit.id]
            case let .reply(reply):
                messageIds = self.deckMessageIds.isEmpty ? [reply.id] : [self.deckMessageIds[self.deckActiveIndex]]
            case let .forward(forward):
                messageIds = forward.messageIds
            case .linkPreview, .suggestPost:
                messageIds = []
            }
            
            if self.subscribedMessageIds != messageIds {
                self.subscribedMessageIds = messageIds
                self.contentDisposable?.dispose()
                if !messageIds.isEmpty {
                    self.contentDisposable = (component.context.engine.data.subscribe(
                        EngineDataList(messageIds.map { id in
                            return TelegramEngine.EngineData.Item.Messages.Message(id: id)
                        })
                    )
                    |> deliverOnMainQueue).startStrict(next: { [weak self] messages in
                        guard let self else {
                            return
                        }
                        self.messages = messages.compactMap { $0 }
                        if !self.isUpdating {
                            self.state?.updated(transition: .immediate, isLocal: true)
                        }
                        if self.isDeckCardAppearancePending {
                            self.isDeckCardAppearancePending = false
                            for contentView in [self.titleNode.view, self.text.view].compactMap({ $0 }) {
                                contentView.alpha = 1.0
                                contentView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: 8.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, additive: true)
                                contentView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                            }
                        }
                    })
                }
            }
            
            self.component = component
            self.state = state
            self.environment = environment
            self.longPressGestureRecognizer.isEnabled = component.longPressAction != nil
            
            if self.closeButtonIcon.image == nil {
                self.closeButtonIcon.image = generateCloseIcon()
            }
            if self.lineView.image == nil {
                self.lineView.image = generateImage(CGSize(width: 2.0, height: 3.0), rotatedContext: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    context.setFillColor(UIColor.white.cgColor)
                    context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 1.0).cgPath)
                    context.fillPath()
                })?.withRenderingMode(.alwaysTemplate).stretchableImage(withLeftCapWidth: 0, topCapHeight: 1)
            }
            
            let cardHeight: CGFloat = 52.0
            let deckRowHeight: CGFloat = 40.0
            if case let .reply(reply) = component.contents {
                self.deckListMessageIds = self.deckMessageIds.isEmpty ? [reply.id] : self.deckMessageIds
            } else {
                self.deckListMessageIds = []
            }
            let deckRowCount = self.isDeckExpanded ? self.deckListMessageIds.count : 0
            let deckRowsTop: CGFloat = 6.0
            let size: CGSize
            if deckRowCount > 0 {
                size = CGSize(width: availableSize.width, height: max(cardHeight, deckRowsTop * 2.0 + CGFloat(deckRowCount) * deckRowHeight))
            } else {
                size = CGSize(width: availableSize.width, height: cardHeight)
            }
            
            let containerInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 6.0, right: 0.0)
            
            let lineSize = CGSize(width: 2.0, height: cardHeight - containerInsets.top - containerInsets.bottom)
            let lineFrame = CGRect(origin: CGPoint(x: containerInsets.left, y: containerInsets.top), size: lineSize)
            transition.setFrame(view: self.lineView, frame: lineFrame)
            self.lineView.tintColor = environment.theme.chat.inputPanel.panelControlAccentColor
            
            let closeButtonSize = CGSize(width: 44.0, height: 44.0)
            let closeButtonFrame = CGRect(origin: CGPoint(x: availableSize.width - closeButtonSize.width, y: floor((cardHeight - closeButtonSize.height) * 0.5)), size: closeButtonSize)
            transition.setFrame(view: self.closeButton, frame: closeButtonFrame)
            
            if let image = self.closeButtonIcon.image {
                let closeButtonIconFrame = image.size.centered(in: closeButtonFrame)
                transition.setFrame(view: self.closeButtonIcon, frame: closeButtonIconFrame)
            }
            self.closeButtonIcon.tintColor = environment.theme.chat.inputPanel.inputControlColor
            
            let secondaryTextColor = environment.theme.chat.inputPanel.inputPlaceholderColor
            
            var textString: NSAttributedString
            var isPhoto = false
            if self.messages.count == 1, let message = self.messages.first {
                var text = ""
                let effectiveMessage = message
                //TODO:release media
                /*if let currentEditMediaReference = self.currentEditMediaReference {
                 effectiveMessage = effectiveMessage.withUpdatedMedia([currentEditMediaReference.media])
                 }*/
                let (attributedText, _, _) = descriptionStringForMessage(
                    contentSettings: component.context.currentContentSettings.with { $0 },
                    message: effectiveMessage,
                    strings: environment.strings,
                    nameDisplayOrder: environment.nameDisplayOrder,
                    dateTimeFormat: environment.dateTimeFormat,
                    accountPeerId: component.context.account.peerId
                )
                text = attributedText.string
                
                var updatedMediaReference: AnyMediaReference?
                var imageDimensions: CGSize?
                if !message._asMessage().containsSecretMedia {
                    var candidateMediaReference: AnyMediaReference?
                    for media in message.media {
                        if media is TelegramMediaImage || media is TelegramMediaFile {
                            candidateMediaReference = .message(message: MessageReference(message._asMessage()), media: media)
                            break
                        }
                    }
                    
                    if let imageReference = candidateMediaReference?.concrete(TelegramMediaImage.self) {
                        updatedMediaReference = imageReference.abstract
                        if let representation = largestRepresentationForPhoto(imageReference.media) {
                            imageDimensions = representation.dimensions.cgSize
                        }
                    } else if let fileReference = candidateMediaReference?.concrete(TelegramMediaFile.self) {
                        updatedMediaReference = fileReference.abstract
                        if !fileReference.media.isInstantVideo, let representation = largestImageRepresentation(fileReference.media.previewRepresentations), !fileReference.media.isSticker {
                            imageDimensions = representation.dimensions.cgSize
                        }
                    }
                }
                
                /*let imageNodeLayout = self.imageNode.asyncLayout()
                 var applyImage: (() -> Void)?
                 if let imageDimensions = imageDimensions {
                 let boundingSize = CGSize(width: 35.0, height: 35.0)
                 applyImage = imageNodeLayout(TransformImageArguments(corners: ImageCorners(radius: 2.0), imageSize: imageDimensions.aspectFilled(boundingSize), boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets()))
                 }
                 
                 var mediaUpdated = false
                 if let updatedMediaReference = updatedMediaReference, let previousMediaReference = self.previousMediaReference {
                 mediaUpdated = !updatedMediaReference.media.isEqual(to: previousMediaReference.media)
                 } else if (updatedMediaReference != nil) != (self.previousMediaReference != nil) {
                 mediaUpdated = true
                 }
                 self.previousMediaReference = updatedMediaReference*/
                
                let hasSpoiler = message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
                
                var updateImageSignal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>?
                let _ = updateImageSignal
                if let updatedMediaReference = updatedMediaReference, imageDimensions != nil {
                    if let imageReference = updatedMediaReference.concrete(TelegramMediaImage.self) {
                        updateImageSignal = chatMessagePhotoThumbnail(account: component.context.account, userLocation: MediaResourceUserLocation.peer(message.id.peerId), photoReference: imageReference, blurred: hasSpoiler)
                        isPhoto = true
                    } else if let fileReference = updatedMediaReference.concrete(TelegramMediaFile.self) {
                        if fileReference.media.isVideo {
                            updateImageSignal = chatMessageVideoThumbnail(account: component.context.account, userLocation: MediaResourceUserLocation.peer(message.id.peerId), fileReference: fileReference, blurred: hasSpoiler)
                        } else if let iconImageRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
                            updateImageSignal = chatWebpageSnippetFile(account: component.context.account, userLocation: MediaResourceUserLocation.peer(message.id.peerId), mediaReference: fileReference.abstract, representation: iconImageRepresentation)
                        }
                    }
                } else {
                    updateImageSignal = .single({ _ in return nil })
                }
                
                let isMedia: Bool
                let isText: Bool
                /*if let currentEditMediaReference = self.currentEditMediaReference {
                 effectiveMessage = effectiveMessage.withUpdatedMedia([currentEditMediaReference.media])
                 }*/
                let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
                switch messageContentKind(contentSettings: component.context.currentContentSettings.with { $0 }, message: effectiveMessage, strings: environment.strings, nameDisplayOrder: environment.nameDisplayOrder, dateTimeFormat: presentationData.dateTimeFormat, accountPeerId: component.context.account.peerId) {
                case .text:
                    isMedia = false
                    isText = true
                default:
                    isMedia = effectiveMessage.text.isEmpty
                    isText = false
                }
                
                let textFont = Font.regular(14.0)
                let messageText: NSAttributedString
                if isText, message.richText != nil {
                    messageText = styleInstantPagePreview(attributedText, font: textFont, italicFont: Font.italic(14.0), textColor: environment.theme.chat.inputPanel.primaryTextColor)
                } else if isText {
                    let entities = (message._asMessage().textEntitiesAttribute?.entities ?? []).filter { entity in
                        switch entity.type {
                        case .Spoiler, .CustomEmoji:
                            return true
                        default:
                            return false
                        }
                    }
                    let textColor = environment.theme.chat.inputPanel.primaryTextColor
                    if entities.count > 0 {
                        messageText = stringWithAppliedEntities(trimToLineCount(message.text, lineCount: 1), entities: entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont,  underlineLinks: false, message: message._asMessage())
                    } else {
                        messageText = NSAttributedString(string: text, font: textFont, textColor: isMedia ? secondaryTextColor : environment.theme.chat.inputPanel.primaryTextColor)
                    }
                } else {
                    messageText = NSAttributedString(string: text, font: Font.regular(14.0), textColor: isMedia ? secondaryTextColor : environment.theme.chat.inputPanel.primaryTextColor)
                }
                textString = messageText
            } else {
                textString = NSAttributedString()
            }
            
            var titleText: [CompositeTextNode.Component] = []
            switch component.contents {
            case .edit:
                let canEditMedia: Bool
                //TODO:release
                /*if let message = self.message, !messageMediaEditingOptions(message: message).isEmpty {
                    canEditMedia = true
                } else {
                    canEditMedia = false
                }*/
                canEditMedia = !"".isEmpty
                
                let titleStringValue: String
                if let message = self.messages.first, message.id.namespace == Namespaces.Message.QuickReplyCloud {
                    titleStringValue = environment.strings.Conversation_EditingQuickReplyPanelTitle
                } else if canEditMedia {
                    titleStringValue = isPhoto ? environment.strings.Conversation_EditingPhotoPanelTitle : environment.strings.Conversation_EditingCaptionPanelTitle
                } else {
                    titleStringValue = environment.strings.Conversation_EditingMessagePanelTitle
                }
                titleText = [.text(NSAttributedString(string: titleStringValue, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                textString = renderInstantPagePreviewIcons(textString, font: Font.regular(14.0), textColor: environment.theme.chat.inputPanel.primaryTextColor)
            case let .reply(reply):
                if let peer = self.messages.first?.peers[reply.id.peerId] as? TelegramChannel, case .broadcast = peer.info {
                    let icon: UIImage?
                    icon = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Accessory Panels/PanelTextChannelIcon"), color: environment.theme.chat.inputPanel.panelControlAccentColor)
                    
                    if let icon {
                        let rawString: PresentationStrings.FormattedString
                        if reply.quote != nil {
                            rawString = environment.strings.Chat_ReplyPanel_ReplyToQuoteBy(peer.debugDisplayTitle)
                        } else {
                            rawString = environment.strings.Chat_ReplyPanel_ReplyTo(peer.debugDisplayTitle)
                        }
                        if let nameRange = rawString.ranges.first {
                            titleText = []
                            
                            let rawNsString = rawString.string as NSString
                            if nameRange.range.lowerBound != 0 {
                                titleText.append(.text(NSAttributedString(string: rawNsString.substring(with: NSRange(location: 0, length: nameRange.range.lowerBound)), font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                            }
                            titleText.append(.icon(icon, .zero))
                            titleText.append(.text(NSAttributedString(string: peer.debugDisplayTitle, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                            
                            if nameRange.range.upperBound != rawNsString.length {
                                titleText.append(.text(NSAttributedString(string: rawNsString.substring(with: NSRange(location: nameRange.range.upperBound, length: rawNsString.length - nameRange.range.upperBound)), font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                            }
                        } else {
                            titleText.append(.text(NSAttributedString(string: rawString.string, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                        }
                    }
                } else {
                    var authorName = ""
                    if let forwardInfo = self.messages.first?._asMessage().forwardInfo, forwardInfo.flags.contains(.isImported) {
                        if let author = forwardInfo.author {
                            authorName = EnginePeer(author).displayTitle(strings: environment.strings, displayOrder: environment.nameDisplayOrder)
                        } else if let authorSignature = forwardInfo.authorSignature {
                            authorName = authorSignature
                        }
                    } else if let author = self.messages.first?._asMessage().effectiveAuthor {
                        authorName = EnginePeer(author).displayTitle(strings: environment.strings, displayOrder: environment.nameDisplayOrder)
                    }
                    
                    if case .todoItem = reply.innerSubject {
                        let string = environment.strings.Chat_ReplyPanel_ReplyToTodoItem
                        titleText = [.text(NSAttributedString(string: string, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                    } else if case .pollOption = reply.innerSubject {
                        let string = environment.strings.Chat_ReplyPanel_ReplyToPollOption
                        titleText = [.text(NSAttributedString(string: string, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                    } else if let _ = reply.quote {
                        let string = environment.strings.Chat_ReplyPanel_ReplyToQuoteBy(authorName).string
                        titleText = [.text(NSAttributedString(string: string, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                    } else {
                        let string = environment.strings.Conversation_ReplyMessagePanelTitle(authorName).string
                        titleText = [.text(NSAttributedString(string: string, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                    }
                    
                    if reply.id.namespace == Namespaces.Message.EphemeralLocal {
                        let icon = UIImage(bundleImageName: "Chat/Message/Hidden")
                        if let iconImage = generateTintedImage(image: icon, color: environment.theme.chat.inputPanel.panelControlAccentColor) {
                            titleText.insert(.icon(iconImage, CGPoint(x: 0.0, y: -4.0 + UIScreenPixel)), at: 0)
                        }
                    } else if reply.id.peerId != component.chatPeerId {
                        if let peer = self.messages.first?.peers[reply.id.peerId], (peer is TelegramChannel || peer is TelegramGroup) {
                            let icon: UIImage?
                            if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
                                icon = UIImage(bundleImageName: "Chat/Input/Accessory Panels/PanelTextChannelIcon")
                            } else {
                                icon = UIImage(bundleImageName: "Chat/Input/Accessory Panels/PanelTextGroupIcon")
                            }
                            if let iconImage = generateTintedImage(image: icon, color: environment.theme.chat.inputPanel.panelControlAccentColor) {
                                titleText.append(.icon(iconImage, .zero))
                                titleText.append(.text(NSAttributedString(string: peer.debugDisplayTitle, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                            }
                        }
                    }
                    
                    if let message = self.messages.first {
                        let textFont = Font.regular(14.0)
                        if let quote = reply.quote {
                            let textColor = environment.theme.chat.inputPanel.primaryTextColor
                            textString = stringWithAppliedEntities(trimToLineCount(quote.text, lineCount: 1), entities: quote.entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: message._asMessage())
                        } else if case let .todoItem(todoItemId) = reply.innerSubject, let todo = message.media.first(where: { $0 is TelegramMediaTodo }) as? TelegramMediaTodo, let todoItem = todo.items.first(where: { $0.id == todoItemId }) {
                            let textColor = environment.theme.chat.inputPanel.primaryTextColor
                            textString = stringWithAppliedEntities(trimToLineCount(todoItem.text, lineCount: 1), entities: todoItem.entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: message._asMessage())
                        } else if case let .pollOption(pollOptionId) = reply.innerSubject, let poll = message.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll, let pollOption = poll.options.first(where: { $0.opaqueIdentifier == pollOptionId }) {
                            let textColor = environment.theme.chat.inputPanel.primaryTextColor
                            textString = stringWithAppliedEntities(trimToLineCount(pollOption.text, lineCount: 1), entities: pollOption.entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: message._asMessage())
                        }
                    }
                }
                textString = renderInstantPagePreviewIcons(textString, font: Font.regular(14.0), textColor: environment.theme.chat.inputPanel.primaryTextColor)
            case let .forward(forward):
                var title = ""
                var authors = ""
                var uniquePeerIds = Set<EnginePeer.Id>()
                var text = NSMutableAttributedString(string: "")
                
                for message in self.messages {
                    if let author = message.forwardInfo?.author ?? message._asMessage().effectiveAuthor, !uniquePeerIds.contains(author.id) {
                        uniquePeerIds.insert(author.id)
                        if !authors.isEmpty {
                            authors.append(", ")
                        }
                        if author.id == component.context.account.peerId {
                            authors.append(environment.strings.DialogList_You)
                        } else {
                            authors.append(EnginePeer(author).compactDisplayTitle)
                        }
                    }
                }
                
                if self.messages.count == 1 {
                    title = environment.strings.Conversation_ForwardOptions_ForwardTitleSingle
                    let (string, entities, _) = textStringForForwardedMessage(messages[0], strings: environment.strings, dateTimeFormat: environment.dateTimeFormat)
                    
                    text = NSMutableAttributedString(attributedString: NSAttributedString(string: "\(authors): ", font: Font.regular(14.0), textColor: secondaryTextColor))
                    
                    let additionalText = NSMutableAttributedString(attributedString: styleInstantPagePreview(string, font: Font.regular(14.0), italicFont: Font.italic(14.0), textColor: secondaryTextColor))
                    for entity in entities {
                        switch entity.type {
                        case let .CustomEmoji(_, fileId):
                            let range = NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound)
                            if range.lowerBound >= 0 && range.upperBound <= additionalText.length {
                                additionalText.addAttribute(ChatTextInputAttributes.customEmoji, value: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: fileId, file: messages[0].associatedMedia[EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile), range: range)
                            }
                        default:
                            break
                        }
                    }
                    
                    text.append(renderInstantPagePreviewIcons(additionalText, font: Font.regular(14.0), textColor: secondaryTextColor))
                } else {
                    title = environment.strings.Conversation_ForwardOptions_ForwardTitle(Int32(messages.count))
                    text = NSMutableAttributedString(attributedString: NSAttributedString(string: environment.strings.Conversation_ForwardFrom(authors).string, font: Font.regular(14.0), textColor: secondaryTextColor))
                }
                
                if forward.forwardOptionsState?.hideNames == true {
                    text = NSMutableAttributedString(attributedString: NSAttributedString(string: environment.strings.Conversation_ForwardOptions_SenderNamesRemoved, font: Font.regular(14.0), textColor: secondaryTextColor))
                }
                text = NSMutableAttributedString(attributedString: renderInstantPagePreviewIcons(text, font: Font.regular(14.0), textColor: secondaryTextColor))
                
                titleText = [.text(NSAttributedString(string: title, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                textString = text
            case let .linkPreview(linkPreview):
                var authorName = ""
                var text = ""
                switch linkPreview.webpage.content {
                case .Pending:
                    authorName = environment.strings.Channel_NotificationLoading
                    text = linkPreview.url
                case let .Loaded(content):
                    if let contentText = content.text {
                        text = contentText
                    } else {
                        if let file = content.file, let mediaKind = mediaContentKind(EngineMedia(file)) {
                            if content.type == "telegram_background" {
                                text = environment.strings.Message_Wallpaper
                            } else if content.type == "telegram_theme" {
                                text = environment.strings.Message_Theme
                            } else {
                                text = stringForMediaKind(mediaKind, strings: environment.strings).0.string
                            }
                        } else if content.type == "telegram_theme" {
                            text = environment.strings.Message_Theme
                        } else if content.type == "video" {
                            text = stringForMediaKind(.video, strings: environment.strings).0.string
                        } else if content.type == "telegram_story" {
                            text = stringForMediaKind(.story, strings: environment.strings).0.string
                        } else if let _ = content.image {
                            text = stringForMediaKind(.image, strings: environment.strings).0.string
                        }
                    }
                    
                    if let title = content.title {
                        authorName = title
                    } else if let websiteName = content.websiteName {
                        authorName = websiteName
                    } else {
                        authorName = content.displayUrl
                    }
                }
                
                titleText = [.text(NSAttributedString(string: authorName, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor))]
                textString = NSAttributedString(string: text, font: Font.regular(14.0), textColor: environment.theme.chat.inputPanel.primaryTextColor)
            case let .suggestPost(suggestPost):
                if suggestPost.state.editingOriginalMessageId != nil {
                    titleText.append(.text(NSAttributedString(string: environment.strings.Chat_PostSuggestion_Suggest_InputEditTitle, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                } else {
                    titleText.append(.text(NSAttributedString(string: environment.strings.Chat_PostSuggestion_Suggest_InputTitle, font: Font.medium(14.0), textColor: environment.theme.chat.inputPanel.panelControlAccentColor)))
                }
                
                let textFont = Font.regular(14.0)
                
                if let price = suggestPost.state.price, price.amount != .zero {
                    let currencySymbol: String
                    let amountString: String
                    switch price.currency {
                    case .stars:
                        currencySymbol = "#"
                        amountString = "\(price.amount)"
                    case .ton:
                        currencySymbol = "$"
                        amountString = formatTonAmountText(price.amount.value, dateTimeFormat: environment.dateTimeFormat)
                    }
                    if let timestamp = suggestPost.state.timestamp {
                        let timeString = humanReadableStringForTimestamp(strings: environment.strings, dateTimeFormat: environment.dateTimeFormat, timestamp: timestamp, alwaysShowTime: true, allowYesterday: false, format: HumanReadableStringFormat(
                            dateFormatString: { value in
                                return PresentationStrings.FormattedString(string: environment.strings.SuggestPost_SetTimeFormat_Date(value).string, ranges: [])
                            },
                            tomorrowFormatString: { value in
                                return PresentationStrings.FormattedString(string: environment.strings.SuggestPost_SetTimeFormat_TomorrowAt(value).string, ranges: [])
                            },
                            todayFormatString: { value in
                                return PresentationStrings.FormattedString(string: environment.strings.SuggestPost_SetTimeFormat_TodayAt(value).string, ranges: [])
                            },
                            yesterdayFormatString: { value in
                                return PresentationStrings.FormattedString(string: environment.strings.SuggestPost_SetTimeFormat_TodayAt(value).string, ranges: [])
                            }
                        )).string
                        textString = NSAttributedString(string: "\(currencySymbol)\(amountString)  📅 \(timeString)", font: textFont, textColor: environment.theme.chat.inputPanel.primaryTextColor)
                    } else {
                        textString = NSAttributedString(string: environment.strings.Chat_PostSuggestion_Suggest_InputSubtitleAnytime("\(currencySymbol)\(amountString)").string, font: textFont, textColor: environment.theme.chat.inputPanel.primaryTextColor)
                    }
                } else {
                    textString = NSAttributedString(string: environment.strings.Chat_PostSuggestion_Suggest_InputSubtitleEmpty, font: textFont, textColor: environment.theme.chat.inputPanel.primaryTextColor)
                }
                
                let mutableTextString = NSMutableAttributedString(attributedString: textString)
                for currency in [.stars, .ton] as [CurrencyAmount.Currency] {
                    var inlineTextStarImage: UIImage?
                    if let current = self.inlineTextStarImage {
                        inlineTextStarImage = current
                    } else {
                        if let image = UIImage(bundleImageName: "Premium/Stars/StarSmall") {
                            let starInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
                            inlineTextStarImage = generateImage(CGSize(width: starInsets.left + image.size.width + starInsets.right, height: image.size.height), rotatedContext: { size, context in
                                context.clear(CGRect(origin: CGPoint(), size: size))
                                UIGraphicsPushContext(context)
                                defer {
                                    UIGraphicsPopContext()
                                }
                                
                                image.draw(at: CGPoint(x: starInsets.left, y: starInsets.top))
                            })?.withRenderingMode(.alwaysOriginal)
                            self.inlineTextStarImage = inlineTextStarImage
                        }
                    }
                    
                    var inlineTextTonImage: UIImage?
                    if let current = self.inlineTextTonImage, current.1 == environment.theme.list.itemAccentColor {
                        inlineTextTonImage = current.0
                    } else {
                        if let image = UIImage(bundleImageName: "Ads/TonMedium") {
                            let tonInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
                            let inlineTextTonImageValue = generateTintedImage(image: generateImage(CGSize(width: tonInsets.left + image.size.width + tonInsets.right, height: image.size.height), rotatedContext: { size, context in
                                context.clear(CGRect(origin: CGPoint(), size: size))
                                UIGraphicsPushContext(context)
                                defer {
                                    UIGraphicsPopContext()
                                }
                                
                                image.draw(at: CGPoint(x: tonInsets.left, y: tonInsets.top))
                            }), color: environment.theme.list.itemAccentColor)!.withRenderingMode(.alwaysOriginal)
                            inlineTextTonImage = inlineTextTonImageValue
                            self.inlineTextTonImage = (inlineTextTonImageValue, environment.theme.list.itemAccentColor)
                        }
                    }
                    
                    let currencySymbol: String
                    let currencyImage: UIImage?
                    switch currency {
                    case .stars:
                        currencySymbol = "#"
                        currencyImage = inlineTextStarImage
                    case .ton:
                        currencySymbol = "$"
                        currencyImage = inlineTextTonImage
                    }
                    
                    if let range = mutableTextString.string.range(of: currencySymbol), let currencyImage {
                        final class RunDelegateData {
                            let ascent: CGFloat
                            let descent: CGFloat
                            let width: CGFloat
                            
                            init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
                                self.ascent = ascent
                                self.descent = descent
                                self.width = width
                            }
                        }
                        
                        let runDelegateData = RunDelegateData(
                            ascent: Font.regular(14.0).ascender,
                            descent: Font.regular(14.0).descender,
                            width: currencyImage.size.width + 2.0
                        )
                        var callbacks = CTRunDelegateCallbacks(
                            version: kCTRunDelegateCurrentVersion,
                            dealloc: { dataRef in
                                Unmanaged<RunDelegateData>.fromOpaque(dataRef).release()
                            },
                            getAscent: { dataRef in
                                let data = Unmanaged<RunDelegateData>.fromOpaque(dataRef)
                                return data.takeUnretainedValue().ascent
                            },
                            getDescent: { dataRef in
                                let data = Unmanaged<RunDelegateData>.fromOpaque(dataRef)
                                return data.takeUnretainedValue().descent
                            },
                            getWidth: { dataRef in
                                let data = Unmanaged<RunDelegateData>.fromOpaque(dataRef)
                                return data.takeUnretainedValue().width
                            }
                        )
                        if let runDelegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(runDelegateData).toOpaque()) {
                            mutableTextString.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: runDelegate, range: NSRange(range, in: mutableTextString.string))
                        }
                        mutableTextString.addAttribute(.attachment, value: currencyImage, range: NSRange(range, in: mutableTextString.string))
                        mutableTextString.addAttribute(.foregroundColor, value: UIColor(rgb: 0xffffff), range: NSRange(range, in: mutableTextString.string))
                        mutableTextString.addAttribute(.baselineOffset, value: 1.0, range: NSRange(range, in: mutableTextString.string))
                    }
                    
                    textString = mutableTextString
                }
            }
            
            var textInsets = UIEdgeInsets(top: 10.0, left: 8.0, bottom: 0.0, right: 44.0)
            
            let accentColor = environment.theme.chat.inputPanel.panelControlAccentColor
            if self.deckMessageIds.isEmpty {
                self.deckCounterButton.isHidden = true
                for edgeView in self.deckEdgeViews {
                    edgeView.removeFromSuperview()
                }
                self.deckEdgeViews.removeAll()
            } else {
                if self.deckCounterButton.isHidden {
                    self.deckCounterButton.isHidden = false
                    if !transition.animation.isImmediate {
                        self.deckCounterButton.layer.animateSpring(from: 0.4 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                        self.deckCounterButton.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    }
                }
                let counterFont = Font.with(size: 12.0, weight: .semibold, traits: .monospacedNumbers)
                let counterText = "\(self.deckActiveIndex + 1)/\(self.deckMessageIds.count)"
                self.deckCounterLabel.attributedText = NSAttributedString(string: counterText, attributes: [.font: counterFont, .foregroundColor: UIColor.white])
                self.deckCounterLabel.backgroundColor = accentColor
                let counterTextSize = self.deckCounterLabel.sizeThatFits(CGSize(width: 100.0, height: 20.0))
                let counterSize = CGSize(width: max(20.0, ceil(counterTextSize.width) + 12.0), height: 20.0)
                self.deckCounterLabel.layer.cornerRadius = counterSize.height * 0.5
                let counterFrame = CGRect(origin: CGPoint(x: closeButtonFrame.minX - counterSize.width, y: floor((cardHeight - counterSize.height) * 0.5)), size: counterSize)
                self.deckCounterButton.frame = counterFrame.insetBy(dx: -8.0, dy: -12.0)
                self.deckCounterLabel.frame = CGRect(origin: CGPoint(x: 8.0, y: 12.0), size: counterSize)
                textInsets.right += counterSize.width + 6.0
                
                // Edges of the cards behind peek out to the left of the reply line
                let edgeCount = min(self.deckMessageIds.count - 1, 2)
                while self.deckEdgeViews.count > edgeCount {
                    self.deckEdgeViews.removeLast().removeFromSuperview()
                }
                while self.deckEdgeViews.count < edgeCount {
                    let edgeView = UIView()
                    edgeView.isUserInteractionEnabled = false
                    edgeView.layer.cornerRadius = 1.0
                    edgeView.alpha = self.isCardHiddenByDeckList ? 0.0 : 1.0
                    self.insertSubview(edgeView, belowSubview: self.lineView)
                    self.deckEdgeViews.append(edgeView)
                    if !transition.animation.isImmediate {
                        edgeView.layer.animateAlpha(from: 0.0, to: edgeView.alpha, duration: 0.25)
                        edgeView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: CGFloat(self.deckEdgeViews.count) * 4.0, y: 0.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, additive: true)
                    }
                }
                for (i, edgeView) in self.deckEdgeViews.enumerated() {
                    let level = CGFloat(i + 1)
                    let verticalInset = level * 5.0
                    edgeView.backgroundColor = accentColor.withMultipliedAlpha(i == 0 ? 0.45 : 0.2)
                    edgeView.frame = CGRect(x: lineFrame.minX - level * 4.0, y: lineFrame.minY + verticalInset, width: 2.0, height: max(2.0, lineFrame.height - verticalInset * 2.0))
                }
            }
            
            self.titleNode.components = titleText
            let titleSize = self.titleNode.update(constrainedSize: CGSize(width: availableSize.width - lineFrame.maxX - textInsets.left - textInsets.right, height: 100.0))
            
            let textRenderInsets = UIEdgeInsets(top: 2.0, left: 2.0, bottom: 2.0, right: 2.0)
            let textSize = self.text.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextWithEntitiesComponent(
                    context: component.context,
                    animationCache: component.context.animationCache,
                    animationRenderer: component.context.animationRenderer,
                    placeholderColor: environment.theme.chat.inputPanel.primaryTextColor.withAlphaComponent(0.1),
                    text: .plain(textString),
                    insets: textRenderInsets,
                    spoilerColor: environment.theme.chat.inputPanel.primaryTextColor,
                    handleSpoilers: true
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - lineFrame.maxX - textInsets.left - textInsets.right, height: 100.0)
            )
            let tintTextString = NSMutableAttributedString(attributedString: textString)
            tintTextString.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: tintTextString.length))
            let _ = self.tintText.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextWithEntitiesComponent(
                    context: component.context,
                    animationCache: component.context.animationCache,
                    animationRenderer: component.context.animationRenderer,
                    placeholderColor: UIColor.black.withAlphaComponent(0.1),
                    text: .plain(tintTextString),
                    insets: textRenderInsets,
                    spoilerColor: .black,
                    handleSpoilers: true
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - lineFrame.maxX - textInsets.left - textInsets.right, height: 100.0)
            )
            
            let titleTextSpacing: CGFloat = 1.0
            
            let titleFrame = CGRect(origin: CGPoint(x: lineFrame.maxX + textInsets.left, y: textInsets.top), size: titleSize)
            let textFrame = CGRect(origin: CGPoint(x: lineFrame.maxX + textInsets.left - textRenderInsets.left, y: titleFrame.maxY + titleTextSpacing - textRenderInsets.top), size: textSize)
            
            transition.setFrame(view: self.titleNode.view, frame: titleFrame)
            
            if let textView = self.text.view, let tintTextView = self.tintText.view {
                if textView.superview == nil {
                    textView.layer.anchorPoint = CGPoint()
                    self.addSubview(textView)
                    
                    tintTextView.layer.anchorPoint = CGPoint()
                    self.contentTintView.addSubview(tintTextView)
                }
                transition.setPosition(view: textView, position: textFrame.origin)
                textView.bounds = CGRect(origin: CGPoint(), size: textFrame.size)
                
                transition.setPosition(view: tintTextView, position: textFrame.origin)
                tintTextView.bounds = CGRect(origin: CGPoint(), size: textFrame.size)
            }
            
            // Only on a change, so that a card switch animation keeps control of the text alpha
            if self.isCardHiddenByDeckList != (deckRowCount > 0) {
                self.isCardHiddenByDeckList = deckRowCount > 0
                let cardAlpha: CGFloat = deckRowCount > 0 ? 0.0 : 1.0
                let cardTransition: ComponentTransition = transition.animation.isImmediate ? .immediate : (deckRowCount > 0 ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.25))
                var cardViews: [UIView] = [self.lineView, self.titleNode.view, self.closeButton, self.closeButtonIcon, self.closeButtonIcon.tintMask, self.deckCounterButton]
                cardViews.append(contentsOf: [self.text.view, self.tintText.view].compactMap { $0 })
                cardViews.append(contentsOf: self.deckEdgeViews)
                for cardView in cardViews {
                    cardTransition.setAlpha(view: cardView, alpha: cardAlpha)
                }
            }
            self.closeButton.isUserInteractionEnabled = deckRowCount == 0
            self.deckCounterButton.isUserInteractionEnabled = deckRowCount == 0
            self.updateDeckDismissRecognizer(isActive: deckRowCount > 0)
            
            // The panel sits on top of the input field: when it gets shorter, its content moves down
            let panelHeightDecrease = max(0.0, (self.lastPanelHeight ?? size.height) - size.height)
            self.lastPanelHeight = size.height
            
            let deckThumbnailSide: CGFloat = 32.0
            for message in self.messages + Array(self.deckMessages.values) {
                // The panel updates on every keystroke: a load already running is left to finish, not restarted
                guard let thumbnail = deckPanelThumbnail(context: component.context, message: message), !self.deckThumbnailLoading.contains(thumbnail.mediaId) else {
                    continue
                }
                self.deckThumbnailLoading.insert(thumbnail.mediaId)
                self.loadDeckThumbnail(thumbnail, side: deckThumbnailSide, attempt: 0)
            }
            
            var validRowIds = Set<EngineMessage.Id>()
            if deckRowCount > 0 {
                let isListAppearing = self.deckRowViews.isEmpty
                for (index, messageId) in self.deckListMessageIds.enumerated() {
                    validRowIds.insert(messageId)
                    let rowFrame = CGRect(x: 0.0, y: deckRowsTop + CGFloat(index) * deckRowHeight, width: availableSize.width, height: deckRowHeight)
                    
                    let rowView: DeckPanelRowView
                    var isNewRow = false
                    if let current = self.deckRowViews[messageId] {
                        rowView = current
                        transition.setFrame(view: rowView, frame: rowFrame)
                    } else {
                        rowView = DeckPanelRowView()
                        rowView.removeAction = { [weak self, weak rowView] in
                            guard let self, let rowView, let messageId = rowView.messageId else {
                                return
                            }
                            self.component?.dismissDeckCard?(messageId)
                        }
                        self.addSubview(rowView)
                        self.deckRowViews[messageId] = rowView
                        rowView.frame = rowFrame
                        isNewRow = true
                    }
                    
                    let message = self.deckMessages[messageId] ?? self.messages.first(where: { $0.id == messageId })
                    rowView.messageId = messageId
                    let rowThumbnailMediaId = message.flatMap { deckPanelThumbnail(context: component.context, message: $0)?.mediaId }
                    rowView.thumbnailMediaId = rowThumbnailMediaId
                    rowView.update(
                        author: message?.author.flatMap { $0.displayTitle(strings: environment.strings, displayOrder: environment.nameDisplayOrder) } ?? " ",
                        text: message.flatMap { message -> String? in
                            let (description, _, _) = descriptionStringForMessage(
                                contentSettings: component.context.currentContentSettings.with { $0 },
                                message: message,
                                strings: environment.strings,
                                nameDisplayOrder: environment.nameDisplayOrder,
                                dateTimeFormat: environment.dateTimeFormat,
                                accountPeerId: component.context.account.peerId
                            )
                            let text = description.string.replacingOccurrences(of: "\n", with: " ")
                            return text.isEmpty ? nil : text
                        } ?? " ",
                        accentColor: accentColor,
                        textColor: environment.theme.chat.inputPanel.primaryTextColor,
                        removeIconColor: environment.theme.chat.inputPanel.inputControlColor,
                        canRemove: component.dismissDeckCard != nil,
                        removeButtonWidth: closeButtonSize.width,
                        lineX: lineFrame.minX,
                        textX: lineFrame.maxX + textInsets.left,
                        rowHeight: deckRowHeight,
                        thumbnailSide: rowThumbnailMediaId != nil ? deckThumbnailSide : nil
                    )
                    rowView.setThumbnail(rowThumbnailMediaId.flatMap { self.deckThumbnailImages[$0] })
                    
                    if isNewRow {
                        if isListAppearing && index == 0 {
                            rowView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
                        } else if isListAppearing {
                            let delay = 0.035 * Double(index - 1)
                            rowView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: deckRowsTop - rowFrame.minY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: delay, additive: true)
                            rowView.layer.animateSpring(from: 0.92 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5, delay: delay)
                            rowView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
                        } else {
                            rowView.layer.animateSpring(from: 0.85 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.45)
                            rowView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        }
                    }
                    rowView.setWobbling(true)
                }
            }
            for (messageId, rowView) in self.deckRowViews where !validRowIds.contains(messageId) {
                self.deckRowViews[messageId] = nil
                rowView.setWobbling(false)
                rowView.isUserInteractionEnabled = false
                if deckRowCount > 0 {
                    transition.setFrame(view: rowView, frame: rowView.frame.offsetBy(dx: 0.0, dy: -panelHeightDecrease))
                    rowView.layer.animateScale(from: 1.0, to: 0.85, duration: 0.2, removeOnCompletion: false)
                    rowView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak rowView] _ in
                        rowView?.removeFromSuperview()
                    })
                } else {
                    rowView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: deckRowsTop - rowView.frame.minY), duration: 0.25, timingFunction: CAMediaTimingFunctionName.easeIn.rawValue, removeOnCompletion: false, additive: true)
                    rowView.layer.animateScale(from: 1.0, to: 0.94, duration: 0.25, removeOnCompletion: false)
                    rowView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak rowView] _ in
                        rowView?.removeFromSuperview()
                    })
                }
            }
            
            return size
        }
    }
    
    public func makeView() -> View {
        return View(frame: CGRect())
    }
    
    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class DeckPanelRowView: UIView {
    private let lineView = UIView()
    private let authorLabel = UILabel()
    private let textLabel = UILabel()
    private let removeButton = HighlightTrackingButton()
    private let removeIconView = UIImageView()
    private let thumbnailView = UIImageView()
    
    var messageId: EngineMessage.Id?
    var thumbnailMediaId: EngineMedia.Id?
    var removeAction: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.lineView.layer.cornerRadius = 1.0
        self.removeIconView.image = generateCloseIcon().withRenderingMode(.alwaysTemplate)
        self.removeIconView.isUserInteractionEnabled = false
        self.removeButton.addSubview(self.removeIconView)
        self.removeButton.addTarget(self, action: #selector(self.removeButtonPressed), for: .touchUpInside)
        self.removeButton.highligthedChanged = { [weak self] highlighted in
            self?.removeIconView.alpha = highlighted ? 0.4 : 1.0
        }
        self.authorLabel.font = Font.medium(15.0)
        self.textLabel.font = Font.regular(15.0)
        self.addSubview(self.lineView)
        self.addSubview(self.authorLabel)
        self.addSubview(self.textLabel)
        self.addSubview(self.thumbnailView)
        self.addSubview(self.removeButton)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func removeButtonPressed() {
        self.removeAction?()
    }
    
    private var isWobbling = false
    
    func setWobbling(_ isWobbling: Bool) {
        if self.isWobbling == isWobbling {
            return
        }
        self.isWobbling = isWobbling
        if isWobbling {
            let angle: CGFloat = 0.004
            let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            rotation.values = [-angle, angle, -angle] as [NSNumber]
            rotation.duration = 0.34 + Double.random(in: 0.0 ..< 0.06)
            rotation.beginTime = CACurrentMediaTime() + Double.random(in: 0.0 ..< 0.2)
            rotation.repeatCount = .infinity
            rotation.isAdditive = true
            self.layer.add(rotation, forKey: "wobbleRotation")
            
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [-0.3, 0.3, -0.3] as [NSNumber]
            bounce.duration = 0.38 + Double.random(in: 0.0 ..< 0.06)
            bounce.beginTime = CACurrentMediaTime() + Double.random(in: 0.0 ..< 0.2)
            bounce.repeatCount = .infinity
            bounce.isAdditive = true
            self.layer.add(bounce, forKey: "wobbleBounce")
        } else {
            self.layer.removeAnimation(forKey: "wobbleRotation")
            self.layer.removeAnimation(forKey: "wobbleBounce")
        }
    }
    
    // Only the remove button takes touches, so a tap elsewhere on the row reaches the panel
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self.removeButton ? result : nil
    }
    
    func setThumbnail(_ image: UIImage?) {
        self.thumbnailView.image = image
    }
    
    func update(author: String, text: String, accentColor: UIColor, textColor: UIColor, removeIconColor: UIColor, canRemove: Bool, removeButtonWidth: CGFloat, lineX: CGFloat, textX: CGFloat, rowHeight: CGFloat, thumbnailSide: CGFloat?) {
        var textX = textX
        if let thumbnailSide {
            self.thumbnailView.isHidden = false
            self.thumbnailView.frame = CGRect(x: textX, y: floor((rowHeight - 3.0 - thumbnailSide) * 0.5), width: thumbnailSide, height: thumbnailSide)
            textX += thumbnailSide + 8.0
        } else {
            self.thumbnailView.isHidden = true
        }
        self.removeButton.isHidden = !canRemove
        self.removeButton.frame = CGRect(x: self.bounds.width - removeButtonWidth, y: 0.0, width: removeButtonWidth, height: rowHeight)
        self.removeIconView.tintColor = removeIconColor
        if let image = self.removeIconView.image {
            self.removeIconView.frame = image.size.centered(in: self.removeButton.bounds)
        }
        let width = self.bounds.width - removeButtonWidth
        self.lineView.backgroundColor = accentColor
        self.lineView.frame = CGRect(x: lineX, y: 2.0, width: 2.0, height: rowHeight - 6.0)
        self.authorLabel.textColor = accentColor
        self.authorLabel.text = author
        self.authorLabel.frame = CGRect(x: textX, y: 0.0, width: max(0.0, width - textX - 8.0), height: 19.0)
        self.textLabel.textColor = textColor
        self.textLabel.text = text
        self.textLabel.frame = CGRect(x: textX, y: 19.0, width: max(0.0, width - textX - 8.0), height: 18.0)
    }
}

private struct DeckPanelThumbnail {
    let mediaId: EngineMedia.Id
    let dimensions: CGSize
    let signal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>
    // A photo's file once it is on disk: drawn straight from it, which does not wait for the preview cache
    let localData: Signal<Data, NoError>?
}

// The preview a card in the list shows, as a regular reply does: a photo, or a video's frame
private func deckPanelThumbnail(context: AccountContext, message: EngineMessage) -> DeckPanelThumbnail? {
    let rawMessage = message._asMessage()
    if rawMessage.containsSecretMedia {
        return nil
    }
    let hasSpoiler = message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
    for media in message.media {
        if let image = media as? TelegramMediaImage, let imageId = image.id, let representation = largestRepresentationForPhoto(image) {
            return DeckPanelThumbnail(mediaId: imageId, dimensions: representation.dimensions.cgSize, signal: chatMessagePhotoThumbnail(account: context.account, userLocation: .peer(message.id.peerId), photoReference: .message(message: MessageReference(rawMessage), media: image), blurred: hasSpoiler), localData: hasSpoiler ? nil : deckPanelLocalData(context: context, resource: representation.resource))
        } else if let file = media as? TelegramMediaFile, file.isVideo, !file.isVideoSticker, !file.isInstantVideo, let fileId = file.id, let dimensions = file.dimensions {
            return DeckPanelThumbnail(mediaId: fileId, dimensions: dimensions.cgSize, signal: chatMessageVideoThumbnail(account: context.account, userLocation: .peer(message.id.peerId), fileReference: .message(message: MessageReference(rawMessage), media: file), blurred: hasSpoiler), localData: nil)
        }
    }
    return nil
}

private func deckPanelLocalData(context: AccountContext, resource: TelegramMediaResource) -> Signal<Data, NoError> {
    return context.account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: true)
    |> filter { $0.complete }
    |> take(1)
    |> mapToSignal { data -> Signal<Data, NoError> in
        if let loaded = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: .mappedIfSafe) {
            return .single(loaded)
        }
        return .complete()
    }
}

// Recognizes the moment a touch lands outside the panel and takes that touch for itself, so whatever lies under it
// (a message, a button, the input field) does not react; a touch inside the panel fails it at once and goes on as usual
private final class DeckDismissGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var panelView: UIView?
    var dismiss: (() -> Void)?
    
    init() {
        super.init(target: nil, action: nil)
        self.delegate = self
        self.cancelsTouchesInView = true
        self.delaysTouchesEnded = false
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let panelView = self.panelView, let touch = touches.first else {
            self.state = .failed
            return
        }
        if panelView.bounds.contains(touch.location(in: panelView)) {
            self.state = .failed
        } else {
            self.state = .recognized
            DispatchQueue.main.async { [weak self] in
                self?.dismiss?()
            }
        }
    }
    
    // Every other recognizer under the touch waits for this one, so the closing tap is not also a tap on the chat
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
