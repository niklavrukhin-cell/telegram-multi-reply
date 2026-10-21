import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import LocalizedPeerData
import PhotoResources
import TelegramStringFormatting
import TextFormat
import InvisibleInkDustNode
import TextNodeWithEntities
import AnimationCache
import MultiAnimationRenderer
import ChatMessageItemCommon
import MessageInlineBlockBackgroundView
import CheckNode
import EmojiTextAttachmentView

public enum ChatMessageReplyInfoType {
    case bubble(incoming: Bool)
    case standalone
}

private let quoteIcon: UIImage = {
    return UIImage(bundleImageName: "Chat/Message/ReplyQuoteIcon")!.precomposed().withRenderingMode(.alwaysTemplate)
}()

private let channelIcon: UIImage = {
    let sourceImage = UIImage(bundleImageName: "Chat/Input/Accessory Panels/PanelTextChannelIcon")!
    return generateImage(CGSize(width: sourceImage.size.width + 4.0, height: sourceImage.size.height + 4.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        UIGraphicsPushContext(context)
        sourceImage.draw(at: CGPoint(x: 2.0, y: 1.0 + UIScreenPixel))
        UIGraphicsPopContext()
    })!.precomposed().withRenderingMode(.alwaysTemplate)
}()

private func generateGroupIcon() -> UIImage {
    let sourceImage = UIImage(bundleImageName: "Chat/Input/Accessory Panels/PanelTextGroupIcon")!
    return generateImage(CGSize(width: sourceImage.size.width, height: sourceImage.size.height + 4.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        UIGraphicsPushContext(context)
        sourceImage.draw(at: CGPoint(x: 0.0, y: 1.0 - UIScreenPixel))
        UIGraphicsPopContext()
        
        //context.setFillColor(UIColor.white.cgColor)
        //context.fill(CGRect(origin: CGPoint(), size: size))
    })!.precomposed().withRenderingMode(.alwaysTemplate)
}

private let groupIcon: UIImage = {
    return generateGroupIcon()
}()

public class ChatMessageReplyInfoNode: ASDisplayNode {
    public final class TransitionReplyPanel {
        public let titleView: UIView
        public let textView: UIView
        public let lineView: UIView
        public let imageView: UIView?
        public let relativeSourceRect: CGRect
        public let relativeTargetRect: CGRect
        
        public init(titleView: UIView, textView: UIView, lineView: UIView, imageView: UIView?, relativeSourceRect: CGRect, relativeTargetRect: CGRect) {
            self.titleView = titleView
            self.textView = textView
            self.lineView = lineView
            self.imageView = imageView
            self.relativeSourceRect = relativeSourceRect
            self.relativeTargetRect = relativeTargetRect
        }
    }
    
    public class Arguments {
        public let presentationData: ChatPresentationData
        public let strings: PresentationStrings
        public let context: AccountContext
        public let type: ChatMessageReplyInfoType
        public let message: EngineRawMessage?
        public let replyForward: QuotedReplyMessageAttribute?
        public let quote: (quote: EngineMessageReplyQuote, isQuote: Bool)?
        public let innerSubject: EngineMessageReplyInnerSubject?
        public let story: EngineStoryId?
        public let isSummarized: Bool
        public let parentMessage: EngineRawMessage
        public let constrainedSize: CGSize
        public let animationCache: AnimationCache?
        public let animationRenderer: MultiAnimationRenderer?
        public let associatedData: ChatMessageItemAssociatedData
        
        public init(
            presentationData: ChatPresentationData,
            strings: PresentationStrings,
            context: AccountContext,
            type: ChatMessageReplyInfoType,
            message: EngineRawMessage?,
            replyForward: QuotedReplyMessageAttribute?,
            quote: (quote: EngineMessageReplyQuote, isQuote: Bool)?,
            innerSubject: EngineMessageReplyInnerSubject?,
            story: EngineStoryId?,
            isSummarized: Bool,
            parentMessage: EngineRawMessage,
            constrainedSize: CGSize,
            animationCache: AnimationCache?,
            animationRenderer: MultiAnimationRenderer?,
            associatedData: ChatMessageItemAssociatedData
        ) {
            self.presentationData = presentationData
            self.strings = strings
            self.context = context
            self.type = type
            self.message = message
            self.replyForward = replyForward
            self.quote = quote
            self.innerSubject = innerSubject
            self.story = story
            self.isSummarized = isSummarized
            self.parentMessage = parentMessage
            self.constrainedSize = constrainedSize
            self.animationCache = animationCache
            self.animationRenderer = animationRenderer
            self.associatedData = associatedData
        }
    }
    
    public var visibility: Bool = false {
        didSet {
            if self.visibility != oldValue {
                self.textNode?.visibilityRect = self.visibility ? CGRect.infinite : nil
            }
        }
    }
    
    private let backgroundView: MessageInlineBlockBackgroundView
    private var starsView: StarsView?
    private var quoteIconView: UIImageView?
    private let contentNode: ASDisplayNode
    private var titleNode: TextNode?
    private var textNode: TextNodeWithEntities?
    private var dustNode: InvisibleInkDustNode?
    private var imageNode: TransformImageNode?
    private var previousMediaReference: AnyMediaReference?
    private var expiredStoryIconView: UIImageView?
    private var checkLayer: CheckLayer?
    private var giftEmojiLayer: InlineStickerItemLayer?
    
    private var currentProgressDisposable: Disposable?
    
    private var deckCounterLabel: UILabel?
    private var deckStackView: UIImageView?
    private var deckStackImageKey: DeckStackImageKey?
    public private(set) var deckCounterFrame: CGRect?
    private var appliedDeckActiveIndex: Int?
    private var appliedDeckIsExpanded: Bool?
    private var appliedDeckParentStableId: UInt32?
    private var deckRowItems: [DeckRowItem] = []
    public private(set) var deckCardTargets: [(messageId: EngineMessage.Id, frame: CGRect)] = []
    
    public var isQuoteExpanded: Bool = false
    
    override public init() {
        self.backgroundView = MessageInlineBlockBackgroundView(frame: CGRect())
        
        self.contentNode = ASDisplayNode()
        self.contentNode.isUserInteractionEnabled = false
        self.contentNode.displaysAsynchronously = false
        self.contentNode.contentMode = .left
        self.contentNode.contentsScale = UIScreenScale
        
        super.init()
        
        self.addSubnode(self.contentNode)
    }
    
    deinit {
        self.currentProgressDisposable?.dispose()
    }
    
    public func makeProgress() -> Promise<Bool> {
        let progress = Promise<Bool>()
        self.currentProgressDisposable?.dispose()
        self.currentProgressDisposable = (progress.get()
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] hasProgress in
            guard let self else {
                return
            }
            self.backgroundView.displayProgress = hasProgress
        })
        return progress
    }
    
    public static func asyncLayout(_ maybeNode: ChatMessageReplyInfoNode?) -> (_ arguments: Arguments) -> (CGSize, (CGSize, Bool, ListViewItemUpdateAnimation) -> ChatMessageReplyInfoNode) {
        let titleNodeLayout = TextNode.asyncLayout(maybeNode?.titleNode)
        let textNodeLayout = TextNodeWithEntities.asyncLayout(maybeNode?.textNode)
        let imageNodeLayout = TransformImageNode.asyncLayout(maybeNode?.imageNode)
        let previousMediaReference = maybeNode?.previousMediaReference
        
        let isQuoteExpanded = maybeNode?.isQuoteExpanded ?? false
        let previousDeckRowTextNodes: [(title: TextNode?, text: TextNode?)] = maybeNode?.deckRowItems.map { ($0.titleNode, $0.textNode) } ?? []
        
        return { originalArguments in
            var arguments = originalArguments
            var deck = MultiReplyStore.shared.deck(parentStableId: originalArguments.parentMessage.stableId)
            // A reply being sent is drawn as a deck from its first layout, so its size does not jump
            if deck == nil, originalArguments.parentMessage.id.namespace == Namespaces.Message.Local, let firstMessageId = originalArguments.message?.id, let deckMessageIds = MultiReplyStore.shared.inFlightDeck(firstMessageId: firstMessageId) {
                deck = MultiReplyStore.Deck(messageIds: deckMessageIds, activeIndex: 0, isExpanded: false)
            }
            if let deck {
                if !deck.isExpanded, deck.activeIndex != 0, let activeMessage = MultiReplyStore.shared.cachedMessage(id: deck.activeMessageId) {
                    arguments = Arguments(
                        presentationData: originalArguments.presentationData,
                        strings: originalArguments.strings,
                        context: originalArguments.context,
                        type: originalArguments.type,
                        message: activeMessage,
                        replyForward: nil,
                        quote: nil,
                        innerSubject: nil,
                        story: nil,
                        isSummarized: originalArguments.isSummarized,
                        parentMessage: originalArguments.parentMessage,
                        constrainedSize: originalArguments.constrainedSize,
                        animationCache: originalArguments.animationCache,
                        animationRenderer: originalArguments.animationRenderer,
                        associatedData: originalArguments.associatedData
                    )
                }
            }
            let deckCounterText = deck.flatMap { $0.isExpanded ? "\($0.messageIds.count)" : "\($0.activeIndex + 1)/\($0.messageIds.count)" }
            let deckCounterFont = Font.with(size: 11.0, weight: .semibold, traits: .monospacedNumbers)
            let deckChevronWidth: CGFloat = 10.0
            let deckCounterSize: CGSize = deckCounterText.flatMap { text in
                let textSize = (text as NSString).size(withAttributes: [.font: deckCounterFont])
                return CGSize(width: ceil(textSize.width) + 10.0 + (deck?.isExpanded == true ? deckChevronWidth : 0.0), height: 16.0)
            } ?? CGSize()
            let deckEdgeSpace: CGFloat = (deck == nil || deck!.isExpanded) ? 0.0 : CGFloat(min(deck!.messageIds.count - 1, 2)) * deckCardShift
            
            let fontSize = floor(arguments.presentationData.fontSize.baseDisplaySize * 14.0 / 17.0)
            let titleFont = Font.semibold(fontSize)
            let textFont = Font.regular(fontSize)
            
            var titleString: NSAttributedString
            var textString: NSAttributedString
            let isMedia: Bool
            let isText: Bool
            var isExpiredStory: Bool = false
            var isStory: Bool = false
            var isPoll: Bool = false
            
            let titleColor: UIColor
            let mainColor: UIColor
            let dustColor: UIColor
            var secondaryColor: UIColor?
            var tertiaryColor: UIColor?
            
            var authorNameColor: UIColor?
            var dashSecondaryColor: UIColor?
            var dashTertiaryColor: UIColor?
            let placeholderColor: UIColor
            
            var author = arguments.message?.effectiveAuthor
            
            if let forwardInfo = arguments.message?.forwardInfo {
                if let peer = forwardInfo.author {
                    author = peer
                } else if let authorSignature = forwardInfo.authorSignature {
                    author = TelegramUser(id: EnginePeer.Id(namespace: Namespaces.Peer.Empty, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(authorSignature.persistentHashValue % 32))), accessHash: nil, firstName: authorSignature, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
                }
            }
            
            var giftEmojiFileId: Int64?
            switch author?.nameColor {
            case let .preset(nameColor):
                let colors = arguments.context.peerNameColors.get(nameColor, dark: arguments.presentationData.theme.theme.overallDarkAppearance)
                authorNameColor = colors.main
                dashSecondaryColor = colors.secondary
                dashTertiaryColor = colors.tertiary
            case let .collectible(collectibleColor):
                let colors = collectibleColor.peerNameColors(dark: arguments.presentationData.theme.theme.overallDarkAppearance)
                authorNameColor = colors.main
                dashSecondaryColor = colors.secondary
                dashTertiaryColor = colors.tertiary
                giftEmojiFileId = collectibleColor.giftEmojiFileId
            default:
                break
            }
            
            if arguments.isSummarized {
                authorNameColor = nil
            }
            
            switch arguments.type {
            case let .bubble(incoming):
                titleColor = incoming ? (authorNameColor ?? arguments.presentationData.theme.theme.chat.message.incoming.accentTextColor) : arguments.presentationData.theme.theme.chat.message.outgoing.accentTextColor
                if incoming {
                    if let authorNameColor {
                        mainColor = authorNameColor
                        secondaryColor = dashSecondaryColor
                        tertiaryColor = dashTertiaryColor
                    } else {
                        mainColor = arguments.presentationData.theme.theme.chat.message.incoming.accentTextColor
                    }
                } else {
                    mainColor = arguments.presentationData.theme.theme.chat.message.outgoing.accentTextColor
                    if dashSecondaryColor != nil {
                        secondaryColor = .clear
                    }
                    if dashTertiaryColor != nil {
                        tertiaryColor = .clear
                    }
                }
                dustColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.secondaryTextColor : arguments.presentationData.theme.theme.chat.message.outgoing.secondaryTextColor
                placeholderColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.mediaPlaceholderColor : arguments.presentationData.theme.theme.chat.message.outgoing.mediaPlaceholderColor
            case .standalone:
                let serviceColor = serviceMessageColorComponents(theme: arguments.presentationData.theme.theme, wallpaper: arguments.presentationData.theme.wallpaper)
                titleColor = serviceColor.primaryText
                if dashSecondaryColor != nil {
                    secondaryColor = .clear
                }
                if dashTertiaryColor != nil {
                    tertiaryColor = .clear
                }
                
                mainColor = serviceMessageColorComponents(chatTheme: arguments.presentationData.theme.theme.chat, wallpaper: arguments.presentationData.theme.wallpaper).primaryText
                dustColor = titleColor
                placeholderColor = serviceColor.primaryText.withAlphaComponent(0.2)
            }
            
            if let message = arguments.message {
                let author = message.effectiveAuthor
                let rawTitleString = author.flatMap(EnginePeer.init)?.displayTitle(strings: arguments.strings, displayOrder: arguments.presentationData.nameDisplayOrder) ?? arguments.strings.User_DeletedAccount
                titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                
                if let forwardInfo = message.forwardInfo {
                    if let author = forwardInfo.author {
                        let rawTitleString = EnginePeer(author).displayTitle(strings: arguments.strings, displayOrder: arguments.presentationData.nameDisplayOrder)
                        titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                    } else if let authorSignature = forwardInfo.authorSignature {
                        let rawTitleString = authorSignature
                        titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                    }
                }
                
                if message.id.peerId != arguments.parentMessage.id.peerId, let peer = message.peers[message.id.peerId], (peer is TelegramChannel || peer is TelegramGroup) {
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
                    let font = titleFont
                    let runDelegateData = RunDelegateData(
                        ascent: font.ascender,
                        descent: font.descender,
                        width: channelIcon.size.width
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
                        if let peer = peer as? TelegramChannel, case .broadcast = peer.info {
                            let rawTitleString = NSMutableAttributedString(attributedString: titleString)
                            rawTitleString.insert(NSAttributedString(string: ">", attributes: [
                                .attachment: channelIcon,
                                .foregroundColor: titleColor,
                                NSAttributedString.Key(rawValue: kCTRunDelegateAttributeName as String): runDelegate
                            ]), at: 0)
                            titleString = rawTitleString
                        } else {
                            let rawTitleString = NSMutableAttributedString(attributedString: titleString)
                            rawTitleString.append(NSAttributedString(string: "\u{200B}", font: titleFont, textColor: titleColor))
                            rawTitleString.append(NSAttributedString(string: ">", attributes: [
                                .attachment: groupIcon,
                                .foregroundColor: titleColor,
                                NSAttributedString.Key(rawValue: kCTRunDelegateAttributeName as String): runDelegate
                            ]))
                            rawTitleString.append(NSAttributedString(string: peer.debugDisplayTitle, font: titleFont, textColor: titleColor))
                            titleString = rawTitleString
                        }
                    }
                }
                
                let (textStringValue, isMediaValue, isTextValue) = descriptionStringForMessage(contentSettings: arguments.context.currentContentSettings.with { $0 }, message: EngineMessage(message), strings: arguments.strings, nameDisplayOrder: arguments.presentationData.nameDisplayOrder, dateTimeFormat: arguments.presentationData.dateTimeFormat, accountPeerId: arguments.context.account.peerId)
                textString = textStringValue
                isMedia = isMediaValue
                isText = isTextValue
            } else if let replyForward = arguments.replyForward {
                if let replyAuthorId = replyForward.peerId, let replyAuthor = arguments.parentMessage.peers[replyAuthorId] {
                    let rawTitleString = EnginePeer(replyAuthor).displayTitle(strings: arguments.strings, displayOrder: arguments.presentationData.nameDisplayOrder)
                    titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                } else {
                    let rawTitleString = replyForward.authorName ?? " "
                    titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                }

                textString = NSAttributedString(string: replyForward.quote?.text ?? arguments.presentationData.strings.VoiceOver_ChatList_Message)
                if let media = replyForward.quote?.media {
                    if let text = replyForward.quote?.text, !text.isEmpty {
                        isMedia = false
                    } else {
                        if let contentKind = mediaContentKind(EngineMedia(media), message: nil, strings: arguments.strings, nameDisplayOrder: arguments.presentationData.nameDisplayOrder, dateTimeFormat: arguments.presentationData.dateTimeFormat, accountPeerId: arguments.context.account.peerId) {
                            let (string, _) = stringForMediaKind(contentKind, strings: arguments.strings)
                            textString = string
                        } else {
                            textString = NSAttributedString(string: arguments.presentationData.strings.VoiceOver_ChatList_Message)
                        }
                        isMedia = true
                    }
                } else {
                    isMedia = false
                }
                isText = replyForward.quote?.text != nil && replyForward.quote?.text != ""
            } else if let story = arguments.story {
                if let authorPeer = arguments.parentMessage.peers[story.peerId] {
                    let rawTitleString = EnginePeer(authorPeer).displayTitle(strings: arguments.strings, displayOrder: arguments.presentationData.nameDisplayOrder)
                    titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                } else {
                    let rawTitleString = arguments.strings.User_DeletedAccount
                    titleString = NSAttributedString(string: rawTitleString, font: titleFont, textColor: titleColor)
                }
                isText = false
                
                var hideStory = false
                if let peer = arguments.parentMessage.peers[story.peerId] as? TelegramChannel, peer.username == nil, peer.usernames.isEmpty {
                    switch peer.participationStatus {
                    case .member:
                        break
                    case .kicked, .left:
                        hideStory = true
                    }
                }
                
                if let storyItem = arguments.parentMessage.associatedStories[story], storyItem.data.isEmpty {
                    isExpiredStory = true
                    textString = NSAttributedString(string: arguments.strings.Chat_ReplyExpiredStory)
                    isMedia = false
                } else if hideStory {
                    isExpiredStory = true
                    textString = NSAttributedString(string: arguments.strings.Chat_ReplyStoryPrivateChannel)
                    isMedia = false
                } else {
                    isStory = true
                    textString = NSAttributedString(string: arguments.strings.Chat_ReplyStory)
                    isMedia = true
                }
            } else {
                titleString = NSAttributedString(string: " ", font: titleFont, textColor: titleColor)
                textString = NSAttributedString(string: " ")
                isMedia = true
                isText = false
            }
            
            let textColor: UIColor
            switch arguments.type {
                case let .bubble(incoming):
                    if isExpiredStory || isStory {
                        textColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.accentTextColor : arguments.presentationData.theme.theme.chat.message.outgoing.accentTextColor
                    } else if isMedia {
                        textColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.secondaryTextColor : arguments.presentationData.theme.theme.chat.message.outgoing.secondaryTextColor
                    } else {
                        textColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.primaryTextColor : arguments.presentationData.theme.theme.chat.message.outgoing.primaryTextColor
                    }
                case .standalone:
                    textColor = titleColor
            }
            
            var textLeftInset: CGFloat = 0.0
            var messageText: NSAttributedString
            var todoItemCompleted: Bool?
            var checkIsRectangle = false
            
            if case let .pollOption(optionId) = arguments.innerSubject, let poll = arguments.message?.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll, let pollOption = poll.options.first(where: { $0.opaqueIdentifier == optionId }) {
                messageText = stringWithAppliedEntities(pollOption.text, entities: pollOption.entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: nil)
                textLeftInset += 16.0
                
                todoItemCompleted = true
                checkIsRectangle = poll.kind.multipleAnswers
            } else if case let .todoItem(todoItemId) = arguments.innerSubject, let todo = arguments.message?.media.first(where: { $0 is TelegramMediaTodo }) as? TelegramMediaTodo, let todoItem = todo.items.first(where: { $0.id == todoItemId }) {
                messageText = stringWithAppliedEntities(todoItem.text, entities: todoItem.entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: nil)
                textLeftInset += 16.0
                
                todoItemCompleted = todo.completions.contains(where: { $0.id == todoItemId })
            } else if isText, let message = arguments.message {
                var text: String
                var messageEntities: [MessageTextEntity]
                
                if let quote = arguments.quote?.quote, !quote.text.isEmpty {
                    text = quote.text
                    messageEntities = quote.entities
                } else {
                    text = foldLineBreaks(message.text)
                    messageEntities = message.textEntitiesAttribute?.entities ?? []
                }
                
                if let translateToLanguage = arguments.associatedData.translateToLanguage, !text.isEmpty {
                    for attribute in message.attributes {
                        if let attribute = attribute as? TranslationMessageAttribute, !attribute.text.isEmpty, attribute.toLang == translateToLanguage {
                            text = attribute.text
                            messageEntities = attribute.entities
                            break
                        }
                    }
                }
                    
                let entities = messageEntities.filter { entity in
                    if case .Strikethrough = entity.type {
                        return true
                    } else if case .Spoiler = entity.type {
                        return true
                    } else if case .CustomEmoji = entity.type {
                        return true
                    } else {
                        return false
                    }
                }
                if entities.count > 0 {
                    messageText = stringWithAppliedEntities(text, entities: entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: message)
                } else {
                    messageText = NSAttributedString(string: text, font: textFont, textColor: textColor)
                }
            } else if isText, let replyForward = arguments.replyForward, let quote = replyForward.quote {
                let entities = quote.entities.filter { entity in
                    if case .Strikethrough = entity.type {
                        return true
                    } else if case .Spoiler = entity.type {
                        return true
                    } else if case .CustomEmoji = entity.type {
                        return true
                    } else {
                        return false
                    }
                }
                if entities.count > 0 {
                    messageText = stringWithAppliedEntities(quote.text, entities: entities, baseColor: textColor, linkColor: textColor, baseFont: textFont, linkFont: textFont, boldFont: textFont, italicFont: textFont, boldItalicFont: textFont, fixedFont: textFont, blockQuoteFont: textFont, underlineLinks: false, message: nil)
                } else {
                    messageText = NSAttributedString(string: quote.text, font: textFont, textColor: textColor)
                }
            } else {
                let mutableTextString = styleInstantPagePreview(foldLineBreaks(textString), font: textFont, italicFont: Font.italic(textFont.pointSize), textColor: textColor)
                messageText = renderInstantPagePreviewIcons(mutableTextString, font: textFont, textColor: textColor)
                
                if let _ = arguments.message?.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll {
                    isPoll = true
                }
            }
            
            var leftInset: CGFloat = 11.0
            let spacing: CGFloat = 2.0
            
            var updatedMediaReference: AnyMediaReference?
            var imageDimensions: CGSize?
            var hasRoundImage = false
            if case let .pollOption(optionId) = arguments.innerSubject, let poll = arguments.message?.media.first(where: { $0 is TelegramMediaPoll }) as? TelegramMediaPoll, let pollOption = poll.options.first(where: { $0.opaqueIdentifier == optionId }), let media = pollOption.media {
                if let image = media as? TelegramMediaImage {
                    updatedMediaReference = .message(message: MessageReference(arguments.parentMessage), media: image)
                    if let representation = largestRepresentationForPhoto(image) {
                        imageDimensions = representation.dimensions.cgSize
                    }
                } else if let file = media as? TelegramMediaFile, file.isVideo && !file.isVideoSticker {
                    updatedMediaReference = .message(message: MessageReference(arguments.parentMessage), media: file)
                    
                    if let dimensions = file.dimensions {
                        imageDimensions = dimensions.cgSize
                    } else if let representation = largestImageRepresentation(file.previewRepresentations), !file.isSticker {
                        imageDimensions = representation.dimensions.cgSize
                    }
                    if file.isInstantVideo {
                        hasRoundImage = true
                    }
                }
            } else if let message = arguments.message, !message.containsSecretMedia {
                for media in message.media {
                    if let image = media as? TelegramMediaImage {
                        updatedMediaReference = .message(message: MessageReference(message), media: image)
                        if let representation = largestRepresentationForPhoto(image) {
                            imageDimensions = representation.dimensions.cgSize
                        }
                        break
                    } else if let file = media as? TelegramMediaFile, !file.isVideoSticker {
                        updatedMediaReference = .message(message: MessageReference(message), media: file)
                        
                        if let dimensions = file.dimensions {
                            imageDimensions = dimensions.cgSize
                        } else if let representation = largestImageRepresentation(file.previewRepresentations), !file.isSticker {
                            imageDimensions = representation.dimensions.cgSize
                        }
                        if file.isInstantVideo {
                            hasRoundImage = true
                        }
                        break
                    } else if let poll = media as? TelegramMediaPoll, let media = poll.attachedMedia {
                        if let image = media as? TelegramMediaImage {
                            updatedMediaReference = .message(message: MessageReference(message), media: image)
                            if let representation = largestRepresentationForPhoto(image) {
                                imageDimensions = representation.dimensions.cgSize
                            }
                            break
                        } else if let file = media as? TelegramMediaFile, !file.isVideoSticker {
                            updatedMediaReference = .message(message: MessageReference(message), media: file)
                            
                            if let dimensions = file.dimensions {
                                imageDimensions = dimensions.cgSize
                            } else if let representation = largestImageRepresentation(file.previewRepresentations), !file.isSticker {
                                imageDimensions = representation.dimensions.cgSize
                            }
                            if file.isInstantVideo {
                                hasRoundImage = true
                            }
                            break
                        }
                    }
                }
            } else if let story = arguments.story, let storyPeer = arguments.parentMessage.peers[story.peerId], let storyItem = arguments.parentMessage.associatedStories[story] {
                if let itemValue = storyItem.get(Stories.StoredItem.self), case let .item(item) = itemValue, let peerReference = PeerReference(storyPeer) {
                    if let image = item.media as? TelegramMediaImage {
                        updatedMediaReference = .story(peer: peerReference, id: story.id, media: image)
                        if let representation = largestRepresentationForPhoto(image) {
                            imageDimensions = representation.dimensions.cgSize
                        }
                    } else if let file = item.media as? TelegramMediaFile, file.isVideo && !file.isVideoSticker {
                        updatedMediaReference = .story(peer: peerReference, id: story.id, media: file)
                        
                        if let dimensions = file.dimensions {
                            imageDimensions = dimensions.cgSize
                        } else if let representation = largestImageRepresentation(file.previewRepresentations), !file.isSticker {
                            imageDimensions = representation.dimensions.cgSize
                        }
                    }
                }
            } else if let replyForward = arguments.replyForward, let media = replyForward.quote?.media {
                if let image = media as? TelegramMediaImage {
                    updatedMediaReference = .message(message: MessageReference(arguments.parentMessage), media: image)
                    if let representation = largestRepresentationForPhoto(image) {
                        imageDimensions = representation.dimensions.cgSize
                    }
                } else if let file = media as? TelegramMediaFile, file.isVideo && !file.isVideoSticker {
                    updatedMediaReference = .message(message: MessageReference(arguments.parentMessage), media: file)
                    
                    if let dimensions = file.dimensions {
                        imageDimensions = dimensions.cgSize
                    } else if let representation = largestImageRepresentation(file.previewRepresentations), !file.isSticker {
                        imageDimensions = representation.dimensions.cgSize
                    }
                    if file.isInstantVideo {
                        hasRoundImage = true
                    }
                }
            }
            
            var imageTextInset: CGFloat = 0.0
            if let _ = imageDimensions {
                imageTextInset += floor(arguments.presentationData.fontSize.baseDisplaySize * 32.0 / 17.0)
            }
            
            let maximumTextWidth = max(0.0, arguments.constrainedSize.width - 8.0 - imageTextInset)
            
            var contrainedTextSize = CGSize(width: maximumTextWidth, height: arguments.constrainedSize.height)
            
            let textInsets = UIEdgeInsets(top: 3.0, left: 0.0, bottom: 3.0, right: 0.0)
            
            var additionalTitleWidth: CGFloat = 0.0
            var maxTitleNumberOfLines = 1
            var maxTextNumberOfLines = 1
            var adjustedConstrainedTextSize = contrainedTextSize
            var textCutout: TextNodeCutout?
            var textCutoutWidth: CGFloat = 0.0
            
            var isQuote = false
            if let quote = arguments.quote, quote.isQuote {
                isQuote = true
            } else if let replyForward = arguments.replyForward, replyForward.quote != nil, replyForward.isQuote {
                isQuote = true
            }
            
            if isQuote {
                additionalTitleWidth += 10.0
                maxTitleNumberOfLines = 2
                maxTextNumberOfLines = isQuoteExpanded ? 50 : 5
                if imageTextInset != 0.0 {
                    adjustedConstrainedTextSize.width += imageTextInset
                    textCutout = TextNodeCutout(topLeft: CGSize(width: imageTextInset + 6.0, height: 10.0))
                    textCutoutWidth = imageTextInset + 6.0
                }
            } else if let _ = giftEmojiFileId {
                additionalTitleWidth += 16.0
            }
            adjustedConstrainedTextSize.width -= textLeftInset
            
            if arguments.isSummarized {
                titleString = NSAttributedString(string: arguments.presentationData.strings.Conversation_Summary_Title, font: titleFont, textColor: titleColor)
                messageText = NSAttributedString(string: arguments.presentationData.strings.Conversation_Summary_Text, font: textFont, textColor: titleColor)
            }
            
            let (titleLayout, titleApply) = titleNodeLayout(TextNodeLayoutArguments(attributedString: titleString, backgroundColor: nil, maximumNumberOfLines: maxTitleNumberOfLines, truncationType: .end, constrainedSize: CGSize(width: contrainedTextSize.width - additionalTitleWidth, height: contrainedTextSize.height), alignment: .natural, cutout: nil, insets: textInsets))
            if isExpiredStory || isStory || isPoll {
                contrainedTextSize.width -= 26.0
            }
            
            if titleLayout.numberOfLines > 1 {
                textCutout = nil
            }
            
            let (textLayout, textApply) = textNodeLayout(TextNodeLayoutArguments(attributedString: messageText, backgroundColor: nil, maximumNumberOfLines: maxTextNumberOfLines, truncationType: .end, constrainedSize: adjustedConstrainedTextSize, alignment: .natural, lineSpacing: 0.07, cutout: textCutout, insets: textInsets))
            
            let imageSide: CGFloat
            let titleLineHeight: CGFloat = titleLayout.linesRects().first?.height ?? 12.0
            imageSide = titleLineHeight * 2.0
            
            var applyImage: (() -> TransformImageNode)?
            if let imageDimensions = imageDimensions {
                let boundingSize = CGSize(width: imageSide, height: imageSide)
                leftInset += imageSide + 6.0
                var radius: CGFloat = 4.0
                var imageSize = imageDimensions.aspectFilled(boundingSize)
                if hasRoundImage {
                    radius = boundingSize.width / 2.0
                    imageSize.width += 2.0
                    imageSize.height += 2.0
                }
                if !isExpiredStory {
                    applyImage = imageNodeLayout(TransformImageArguments(corners: ImageCorners(radius: radius), imageSize: imageSize, boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets(), emptyColor: placeholderColor))
                }
            }
            
            var mediaUpdated = false
            if let updatedMediaReference = updatedMediaReference, let previousMediaReference = previousMediaReference {
                mediaUpdated = !updatedMediaReference.media.isEqual(to: previousMediaReference.media)
            } else if (updatedMediaReference != nil) != (previousMediaReference != nil) {
                mediaUpdated = true
            }
            
            let hasSpoiler: Bool
            if let message = arguments.message {
                hasSpoiler = message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
            } else {
                hasSpoiler = false
            }
            
            var updateImageSignal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>?
            
            var mediaUserLocation: MediaResourceUserLocation = .other
            if let message = arguments.message {
                mediaUserLocation = .peer(message.id.peerId)
            }
            
            if let updatedMediaReference = updatedMediaReference, mediaUpdated && imageDimensions != nil {
                if let imageReference = updatedMediaReference.concrete(TelegramMediaImage.self) {
                    updateImageSignal = chatMessagePhotoThumbnail(account: arguments.context.account, userLocation: mediaUserLocation, photoReference: imageReference, blurred: hasSpoiler)
                } else if let fileReference = updatedMediaReference.concrete(TelegramMediaFile.self) {
                    if fileReference.media.isVideo {
                        updateImageSignal = chatMessageVideoThumbnail(account: arguments.context.account, userLocation: mediaUserLocation, fileReference: fileReference, blurred: hasSpoiler)
                    } else if let iconImageRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
                        updateImageSignal = chatWebpageSnippetFile(account: arguments.context.account, userLocation: mediaUserLocation, mediaReference: fileReference.abstract, representation: iconImageRepresentation)
                    }
                }
            }
            
            var size = CGSize()
            size.width = max(titleLayout.size.width + additionalTitleWidth - textInsets.left - textInsets.right, textLeftInset + textLayout.size.width - textInsets.left - textInsets.right - textCutoutWidth) + leftInset + 6.0
            size.height = titleLayout.size.height + textLayout.size.height - 2 * (textInsets.top + textInsets.bottom) + 2 * spacing
            size.height += 2.0
            if isExpiredStory || isStory || isPoll {
                size.width += 16.0
            }
            if deck != nil {
                size.width += deckCounterSize.width + 4.0
            }
            size.width += deckEdgeSpace
            let mainCardHeight = size.height
            size.height += deckEdgeSpace
            
            let deckRowSpacing: CGFloat = 4.0
            let deckRowLeftInset: CGFloat = 11.0
            var deckRows: [(messageId: EngineMessage.Id, color: UIColor, secondaryColor: UIColor?, tertiaryColor: UIColor?, height: CGFloat, thumbnailMediaId: EngineMedia.Id?, titleLayout: TextNodeLayout, titleApply: () -> TextNode, textLayout: TextNodeLayout, textApply: () -> TextNode)] = []
            var deckThumbnails: [DeckCardThumbnail] = []
            let deckThumbnailBoundingSize = CGSize(width: imageSide, height: imageSide)
            // Every card is measured, so the block keeps its width while cards are switched
            if let deck {
                for (deckIndex, messageId) in deck.messageIds.enumerated() {
                    guard let rowMessage = (deckIndex == 0 ? originalArguments.message : nil) ?? MultiReplyStore.shared.cachedMessage(id: messageId) else {
                        continue
                    }
                    let isDisplayedRow = deck.isExpanded && deckIndex != 0
                    var rowColor: UIColor
                    var rowSecondaryColor: UIColor?
                    var rowTertiaryColor: UIColor?
                    var rowAuthorColors: (main: UIColor, secondary: UIColor?, tertiary: UIColor?)?
                    switch rowMessage.effectiveAuthor?.nameColor {
                    case let .preset(nameColor):
                        let colors = arguments.context.peerNameColors.get(nameColor, dark: arguments.presentationData.theme.theme.overallDarkAppearance)
                        rowAuthorColors = (colors.main, colors.secondary, colors.tertiary)
                    case let .collectible(collectibleColor):
                        let colors = collectibleColor.peerNameColors(dark: arguments.presentationData.theme.theme.overallDarkAppearance)
                        rowAuthorColors = (colors.main, colors.secondary, colors.tertiary)
                    default:
                        break
                    }
                    switch arguments.type {
                    case let .bubble(incoming):
                        if incoming, let rowAuthorColors {
                            rowColor = rowAuthorColors.main
                            rowSecondaryColor = rowAuthorColors.secondary
                            rowTertiaryColor = rowAuthorColors.tertiary
                        } else {
                            rowColor = incoming ? arguments.presentationData.theme.theme.chat.message.incoming.accentTextColor : arguments.presentationData.theme.theme.chat.message.outgoing.accentTextColor
                        }
                    case .standalone:
                        rowColor = mainColor
                    }
                    
                    let authorTitle = rowMessage.effectiveAuthor.flatMap { EnginePeer($0).displayTitle(strings: arguments.strings, displayOrder: arguments.presentationData.nameDisplayOrder) } ?? ""
                    let (rowTextString, rowIsMedia, _) = descriptionStringForMessage(contentSettings: arguments.context.currentContentSettings.with { $0 }, message: EngineMessage(rowMessage), strings: arguments.strings, nameDisplayOrder: arguments.presentationData.nameDisplayOrder, dateTimeFormat: arguments.presentationData.dateTimeFormat, accountPeerId: arguments.context.account.peerId)
                    
                    let rowTextColor: UIColor
                    switch arguments.type {
                    case let .bubble(incoming):
                        let messageTheme = incoming ? arguments.presentationData.theme.theme.chat.message.incoming : arguments.presentationData.theme.theme.chat.message.outgoing
                        rowTextColor = rowIsMedia ? messageTheme.secondaryTextColor : messageTheme.primaryTextColor
                    case .standalone:
                        rowTextColor = titleColor
                    }
                    
                    let rowThumbnail = deckCardThumbnail(context: arguments.context, message: rowMessage)
                    if let rowThumbnail {
                        deckThumbnails.append(rowThumbnail)
                    }
                    let rowThumbnailInset: CGFloat = rowThumbnail != nil ? imageSide + 6.0 : 0.0
                    
                    let rowConstrainedSize = CGSize(width: max(0.0, arguments.constrainedSize.width - 8.0 - rowThumbnailInset), height: arguments.constrainedSize.height)
                    let previousTextNodes: (title: TextNode?, text: TextNode?) = isDisplayedRow && deckRows.count < previousDeckRowTextNodes.count ? previousDeckRowTextNodes[deckRows.count] : (nil, nil)
                    let (rowTitleLayout, rowTitleApply) = TextNode.asyncLayout(previousTextNodes.title)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: authorTitle, font: titleFont, textColor: rowColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: rowConstrainedSize, alignment: .natural, cutout: nil, insets: textInsets))
                    let (rowTextLayout, rowTextApply) = TextNode.asyncLayout(previousTextNodes.text)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: rowTextString.string, font: textFont, textColor: rowTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: rowConstrainedSize, alignment: .natural, cutout: nil, insets: textInsets))
                    
                    let rowHeight = rowTitleLayout.size.height + rowTextLayout.size.height - 2 * (textInsets.top + textInsets.bottom) + 2 * spacing + 2.0
                    let rowWidth = max(rowTitleLayout.size.width, rowTextLayout.size.width) - textInsets.left - textInsets.right + deckRowLeftInset + rowThumbnailInset + 6.0
                    size.width = max(size.width, rowWidth + deckCounterSize.width + 4.0)
                    if isDisplayedRow {
                        size.height += deckRowSpacing + rowHeight
                        deckRows.append((messageId, rowColor, rowSecondaryColor, rowTertiaryColor, rowHeight, rowThumbnail?.mediaId, rowTitleLayout, rowTitleApply, rowTextLayout, rowTextApply))
                    }
                }
            }
            
            return (size, { realSize, attemptSynchronous, animation in
                let node: ChatMessageReplyInfoNode
                if let maybeNode = maybeNode {
                    node = maybeNode
                } else {
                    node = ChatMessageReplyInfoNode()
                }
                
                var animation = animation
                if node.titleNode == nil {
                    animation = .None
                }
                
                node.previousMediaReference = updatedMediaReference
                
                var deckSnapshotView: UIView?
                let isSameDeck = deck != nil && node.appliedDeckParentStableId == arguments.parentMessage.stableId
                node.appliedDeckParentStableId = deck != nil ? arguments.parentMessage.stableId : nil
                let isExpanding = isSameDeck && deck?.isExpanded == true && node.appliedDeckIsExpanded == false
                node.appliedDeckIsExpanded = deck?.isExpanded
                if isSameDeck, let deck, !deck.isExpanded, let appliedDeckActiveIndex = node.appliedDeckActiveIndex, appliedDeckActiveIndex != deck.activeIndex {
                    deckSnapshotView = node.view.snapshotView(afterScreenUpdates: false)
                }
                node.appliedDeckActiveIndex = deck?.activeIndex
                
                //node.textNode?.textNode.displaysAsynchronously = !arguments.presentationData.isPreview
                
                let titleNode = titleApply()
                titleNode.displaysAsynchronously = !arguments.presentationData.isPreview
                
                var textArguments: TextNodeWithEntities.Arguments?
                if let cache = arguments.animationCache, let renderer = arguments.animationRenderer {
                    textArguments = TextNodeWithEntities.Arguments(context: arguments.context, cache: cache, renderer: renderer, placeholderColor: placeholderColor, attemptSynchronous: attemptSynchronous)
                }
                let previousTextContents = node.textNode?.textNode.layer.contents
                let textNode = textApply(textArguments)
                textNode.textNode.displaysAsynchronously = !arguments.presentationData.isPreview
                
                textNode.visibilityRect = node.visibility ? CGRect.infinite : nil
                
                if node.titleNode == nil {
                    titleNode.isUserInteractionEnabled = false
                    node.titleNode = titleNode
                    node.contentNode.addSubnode(titleNode)
                }
                
                if node.textNode == nil {
                    textNode.textNode.isUserInteractionEnabled = false
                    textNode.textNode.contentMode = .topLeft
                    textNode.textNode.clipsToBounds = true
                    textNode.textNode.contentsScale = UIScreenScale
                    textNode.textNode.displaysAsynchronously = false
                    node.textNode = textNode
                    node.contentNode.addSubnode(textNode.textNode)
                }
                
                if let applyImage = applyImage {
                    let imageNode = applyImage()
                    if node.imageNode == nil {
                        imageNode.isLayerBacked = false
                        node.addSubnode(imageNode)
                        node.imageNode = imageNode
                    }
                    imageNode.frame = CGRect(origin: CGPoint(x: 9.0, y: 4.0), size: CGSize(width: imageSide, height: imageSide))
                    
                    if let updateImageSignal = updateImageSignal {
                        imageNode.setSignal(updateImageSignal)
                    }
                    if deck != nil, imageNode.contents == nil, let mediaId = updatedMediaReference?.media.id, let image = DeckThumbnailStore.shared.image(mediaId: mediaId, side: imageSide) {
                        imageNode.contents = image.cgImage
                    }
                } else if let imageNode = node.imageNode {
                    imageNode.removeFromSupernode()
                    node.imageNode = nil
                }
                if let message = arguments.message {
                    node.imageNode?.captureProtected = arguments.associatedData.isCopyProtectionEnabled || message.isCopyProtected()
                }
                
                titleNode.frame = CGRect(origin: CGPoint(x: leftInset - textInsets.left - 2.0, y: spacing - textInsets.top + 1.0), size: titleLayout.size)
                
                let textFrame = CGRect(origin: CGPoint(x: textLeftInset + leftInset - textInsets.left - 2.0 - textCutoutWidth, y: titleNode.frame.maxY - textInsets.bottom + spacing - textInsets.top - 2.0), size: textLayout.size)
                let effectiveTextFrame = textFrame.offsetBy(dx: (isExpiredStory || isStory || isPoll) ? 18.0 : 0.0, dy: 0.0)
                
                if textNode.textNode.bounds.isEmpty || !animation.isAnimated || textNode.textNode.bounds.height == effectiveTextFrame.height {
                    textNode.textNode.frame = effectiveTextFrame
                } else {
                    if textNode.textNode.bounds.height != effectiveTextFrame.height {
                        animation.animator.updateFrame(layer: textNode.textNode.layer, frame: effectiveTextFrame, completion: nil)
                        
                        textNode.textNode.layer.setNeedsDisplay()
                        textNode.textNode.layer.display()
                    } else {
                        animation.animator.updateFrame(layer: textNode.textNode.layer, frame: effectiveTextFrame, completion: nil)
                    }
                    
                    if let previousTextContents, let updatedContents = textNode.textNode.contents {
                        let previousTextContents = previousTextContents as AnyObject
                        let updatedContents = updatedContents as AnyObject
                        if previousTextContents !== updatedContents {
                            textNode.textNode.layer.animate(from: previousTextContents, to: updatedContents, keyPath: "contents", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.2)
                        }
                    }
                }
                
                if isExpiredStory || isStory || isPoll {
                    let expiredStoryIconView: UIImageView
                    if let current = node.expiredStoryIconView {
                        expiredStoryIconView = current
                    } else {
                        expiredStoryIconView = UIImageView()
                        node.expiredStoryIconView = expiredStoryIconView
                        node.view.addSubview(expiredStoryIconView)
                    }
                    
                    let imageType: ChatExpiredStoryIndicatorType
                    switch arguments.type {
                    case .standalone:
                        imageType = .free
                    case let .bubble(incoming):
                        imageType = incoming ? .incoming : .outgoing
                    }
                    
                    if isPoll {
                        expiredStoryIconView.image = PresentationResourcesChat.chatReplyPollIndicatorIcon(arguments.presentationData.theme.theme, type: imageType)
                    } else if isExpiredStory {
                        expiredStoryIconView.image = PresentationResourcesChat.chatExpiredStoryIndicatorIcon(arguments.presentationData.theme.theme, type: imageType)
                    } else {
                        expiredStoryIconView.image = PresentationResourcesChat.chatReplyStoryIndicatorIcon(arguments.presentationData.theme.theme, type: imageType)
                    }
                    if let image = expiredStoryIconView.image {
                        let imageSize: CGSize
                        if isExpiredStory {
                            imageSize = CGSize(width: floor(image.size.width * 1.22), height: floor(image.size.height * 1.22))
                            expiredStoryIconView.frame = CGRect(origin: CGPoint(x: textFrame.minX - 2.0, y: textFrame.minY + 2.0), size: imageSize)
                        } else {
                            imageSize = image.size
                            expiredStoryIconView.frame = CGRect(origin: CGPoint(x: textFrame.minX - 1.0, y: textFrame.minY + 3.0 + UIScreenPixel), size: imageSize)
                        }
                    }
                    expiredStoryIconView.tintColor = titleColor
                } else if let expiredStoryIconView = node.expiredStoryIconView {
                    expiredStoryIconView.removeFromSuperview()
                }
                
                if !textLayout.spoilers.isEmpty {
                    let dustNode: InvisibleInkDustNode
                    if let current = node.dustNode {
                        dustNode = current
                    } else {
                        dustNode = InvisibleInkDustNode(textNode: nil, enableAnimations: arguments.context.sharedContext.energyUsageSettings.fullTranslucency && !arguments.presentationData.isPreview)
                        dustNode.isUserInteractionEnabled = false
                        node.dustNode = dustNode
                        node.contentNode.insertSubnode(dustNode, aboveSubnode: textNode.textNode)
                    }
                    dustNode.frame = textFrame.insetBy(dx: -3.0, dy: -3.0).offsetBy(dx: 0.0, dy: 3.0)
                    dustNode.update(size: dustNode.frame.size, color: dustColor, textColor: dustColor, rects: textLayout.spoilers.map { $0.1.offsetBy(dx: 3.0, dy: 3.0).insetBy(dx: 1.0, dy: 1.0) }, wordRects: textLayout.spoilerWords.map { $0.1.offsetBy(dx: 3.0, dy: 3.0).insetBy(dx: 1.0, dy: 1.0) })
                } else if let dustNode = node.dustNode {
                    dustNode.removeFromSupernode()
                    node.dustNode = nil
                }
                
                if node.backgroundView.superview == nil {
                    node.contentNode.view.insertSubview(node.backgroundView, at: 0)
                }
                
                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: realSize.width - deckEdgeSpace, height: deck == nil ? realSize.height : mainCardHeight))
                
                node.backgroundView.frame = backgroundFrame
                
                var pattern: MessageInlineBlockBackgroundView.Pattern?
                if let backgroundEmojiId = author?.backgroundEmojiId {
                    pattern = MessageInlineBlockBackgroundView.Pattern(
                        context: arguments.context,
                        fileId: backgroundEmojiId,
                        file: arguments.parentMessage.associatedMedia[EngineMedia.Id(
                            namespace: Namespaces.Media.CloudFile,
                            id: backgroundEmojiId
                        )] as? TelegramMediaFile,
                        emptyCorner: giftEmojiFileId != nil
                    )
                }
                var isTransparent: Bool = false
                if case .standalone = arguments.type {
                    isTransparent = true
                }
                node.backgroundView.update(
                    size: backgroundFrame.size,
                    isTransparent: isTransparent,
                    primaryColor: mainColor,
                    secondaryColor: secondaryColor,
                    thirdColor: tertiaryColor,
                    backgroundColor: nil,
                    pattern: pattern,
                    animation: animation
                )
                
                if isQuote {
                    let quoteIconFrame = CGRect(origin: CGPoint(x: backgroundFrame.maxX - 4.0 - quoteIcon.size.width, y: backgroundFrame.minY + 4.0), size: quoteIcon.size)
                    
                    let quoteIconView: UIImageView
                    if let current = node.quoteIconView {
                        quoteIconView = current
                        
                        animation.animator.updateFrame(layer: quoteIconView.layer, frame: quoteIconFrame, completion: nil)
                    } else {
                        quoteIconView = UIImageView(image: quoteIcon)
                        node.quoteIconView = quoteIconView
                        node.contentNode.view.addSubview(quoteIconView)
                            
                        quoteIconView.frame = quoteIconFrame
                    }
                    quoteIconView.tintColor = mainColor
                } else if let quoteIconView = node.quoteIconView {
                    node.quoteIconView = nil
                    quoteIconView.removeFromSuperview()
                }
                
                if let todoItemCompleted {
                    let checkLayerFrame = CGRect(origin: CGPoint(x: textFrame.minX - 16.0, y: textFrame.minY + 5.0), size: CGSize(width: 12.0, height: 12.0))
                    let checkTheme = CheckNodeTheme(backgroundColor: titleColor, strokeColor: .clear, borderColor: titleColor, overlayBorder: false, hasInset: true, hasShadow: false, borderWidth: 1.0)
                    
                    let checkLayer: CheckLayer
                    if let current = node.checkLayer {
                        checkLayer = current
                        
                        checkLayer.setSelected(todoItemCompleted, animated: true)
                        animation.animator.updateFrame(layer: checkLayer, frame: checkLayerFrame, completion: nil)
                    } else {
                        checkLayer = CheckLayer(theme: checkTheme, content: .check(isRectangle: checkIsRectangle))
                        node.checkLayer = checkLayer
                        node.contentNode.layer.addSublayer(checkLayer)
                        
                        checkLayer.setSelected(todoItemCompleted, animated: false)
                        checkLayer.frame = checkLayerFrame
                    }
                    checkLayer.theme = checkTheme
                } else if let checkLayer = node.checkLayer {
                    node.checkLayer = nil
                    checkLayer.removeFromSuperlayer()
                }
                
                if let giftEmojiFileId {
                    let giftLayerSize = CGSize(width: 18.0, height: 18.0)
                    let giftLayerFrame = CGRect(origin: CGPoint(x: realSize.width - giftLayerSize.width - 4.0, y: 3.0), size: giftLayerSize)
                    
                    let giftEmojiLayer: InlineStickerItemLayer
                    if let current = node.giftEmojiLayer, current.file?.fileId.id == giftEmojiFileId {
                        giftEmojiLayer = current
                        animation.animator.updateFrame(layer: giftEmojiLayer, frame: giftLayerFrame, completion: nil)
                    } else {
                        if let giftEmojiLayer = node.giftEmojiLayer {
                            node.giftEmojiLayer = nil
                            giftEmojiLayer.removeFromSuperlayer()
                        }
                        giftEmojiLayer = InlineStickerItemLayer(context: arguments.context, userLocation: .other, attemptSynchronousLoad: true, emoji: ChatTextInputTextCustomEmojiAttribute(interactivelySelectedFromPackId: nil, fileId: giftEmojiFileId, file: nil, custom: nil, enableAnimation: true), file: nil, cache: arguments.context.animationCache, renderer: arguments.context.animationRenderer, unique: false, placeholderColor: placeholderColor, pointSize: CGSize(width: giftLayerSize.width * 2.0, height: giftLayerSize.height * 2.0), dynamicColor: nil, loopCount: 2)
                        node.giftEmojiLayer = giftEmojiLayer
                        node.contentNode.layer.addSublayer(giftEmojiLayer)
                        
                        giftEmojiLayer.frame = giftLayerFrame
                    }
                    
                } else if let giftEmojiLayer = node.giftEmojiLayer {
                    node.giftEmojiLayer = nil
                    giftEmojiLayer.removeFromSuperlayer()
                }
                
                if arguments.isSummarized {
                    let starsView: StarsView
                    if let current = node.starsView {
                        starsView = current
                    } else {
                        starsView = StarsView()
                        node.starsView = starsView
                        node.contentNode.view.insertSubview(starsView, at: 1)
                    }
                    starsView.frame = CGRect(origin: CGPoint(), size: backgroundFrame.size)
                    starsView.update(size: backgroundFrame.size, color: mainColor)
                } else if let starsView = node.starsView {
                    node.starsView = nil
                    starsView.removeFromSuperview()
                }
                
                if let deck, let deckCounterText {
                    let deckCounterLabel: UILabel
                    if let current = node.deckCounterLabel {
                        deckCounterLabel = current
                    } else {
                        deckCounterLabel = UILabel()
                        deckCounterLabel.textAlignment = .center
                        deckCounterLabel.clipsToBounds = true
                        deckCounterLabel.layer.cornerRadius = 8.0
                        node.deckCounterLabel = deckCounterLabel
                        node.contentNode.view.addSubview(deckCounterLabel)
                    }
                    deckCounterLabel.font = deckCounterFont
                    deckCounterLabel.textColor = mainColor
                    deckCounterLabel.backgroundColor = mainColor.withMultipliedAlpha(0.2)
                    if deckCounterLabel.text != nil && deckCounterLabel.attributedText?.string.hasPrefix(deckCounterText) != true {
                        deckCounterLabel.layer.animateScale(from: 0.8, to: 1.0, duration: 0.2)
                    }
                    deckCounterLabel.attributedText = deckCounterString(text: deckCounterText, font: deckCounterFont, color: mainColor, withCollapseChevron: deck.isExpanded)
                    let deckCounterFrame = CGRect(origin: CGPoint(x: backgroundFrame.maxX - deckCounterSize.width - 4.0, y: backgroundFrame.minY + 4.0), size: deckCounterSize)
                    deckCounterLabel.frame = deckCounterFrame
                    node.deckCounterFrame = deckCounterFrame
                    
                    // The quote background is translucent, so the cards behind it are drawn as one image cut out under the cards in front
                    let stackCount = deck.isExpanded ? 0 : min(deck.messageIds.count - 1, 2)
                    let deckStackView: UIImageView
                    if let current = node.deckStackView {
                        deckStackView = current
                    } else {
                        deckStackView = UIImageView()
                        node.contentNode.view.insertSubview(deckStackView, at: 0)
                        node.deckStackView = deckStackView
                    }
                    deckStackView.isHidden = stackCount == 0
                    if stackCount != 0 {
                        let stackSize = CGSize(width: backgroundFrame.width + CGFloat(stackCount) * deckCardShift, height: backgroundFrame.height + CGFloat(stackCount) * deckCardShift)
                        deckStackView.frame = CGRect(origin: backgroundFrame.origin, size: stackSize)
                        let imageKey = DeckStackImageKey(size: stackSize, cardSize: backgroundFrame.size, count: stackCount, color: mainColor.argb)
                        if node.deckStackImageKey != imageKey {
                            node.deckStackImageKey = imageKey
                            deckStackView.image = generateDeckStackImage(size: stackSize, cardSize: backgroundFrame.size, count: stackCount, color: mainColor)
                        }
                    }
                } else {
                    node.deckCounterLabel?.removeFromSuperview()
                    node.deckCounterLabel = nil
                    node.deckCounterFrame = nil
                    node.deckStackView?.removeFromSuperview()
                    node.deckStackView = nil
                    node.deckStackImageKey = nil
                }
                
                node.contentNode.frame = CGRect(origin: CGPoint(), size: size)
                
                for thumbnail in deckThumbnails {
                    let mediaId = thumbnail.mediaId
                    DeckThumbnailStore.shared.load(thumbnail, side: imageSide, emptyColor: placeholderColor, observer: node, update: { [weak node] image in
                        guard let node else {
                            return
                        }
                        for rowItem in node.deckRowItems where rowItem.thumbnailMediaId == mediaId {
                            rowItem.imageView.image = image
                        }
                        if let imageNode = node.imageNode, imageNode.contents == nil, node.previousMediaReference?.media.id == mediaId {
                            imageNode.contents = image.cgImage
                        }
                    })
                }
                
                node.deckCardTargets = deck.flatMap { [(messageId: $0.messageIds[0], frame: backgroundFrame)] } ?? []
                var rowY = backgroundFrame.maxY
                for (index, row) in deckRows.enumerated() {
                    rowY += deckRowSpacing
                    let rowFrame = CGRect(x: 0.0, y: rowY, width: backgroundFrame.width, height: row.height)
                    rowY += row.height
                    
                    let rowItem: DeckRowItem
                    var isNewRow = false
                    if index < node.deckRowItems.count {
                        rowItem = node.deckRowItems[index]
                    } else {
                        rowItem = DeckRowItem()
                        node.contentNode.view.addSubview(rowItem.containerView)
                        node.deckRowItems.append(rowItem)
                        isNewRow = true
                    }
                    if isNewRow {
                        rowItem.containerView.frame = rowFrame
                    } else {
                        animation.animator.updateFrame(layer: rowItem.containerView.layer, frame: rowFrame, completion: nil)
                    }
                    rowItem.backgroundView.frame = CGRect(origin: CGPoint(), size: rowFrame.size)
                    rowItem.backgroundView.update(size: rowFrame.size, isTransparent: false, primaryColor: row.color, secondaryColor: row.secondaryColor, thirdColor: row.tertiaryColor, backgroundColor: nil, pattern: nil, animation: isNewRow ? .None : animation)
                    
                    var rowTextLeftInset = deckRowLeftInset
                    rowItem.thumbnailMediaId = row.thumbnailMediaId
                    if let thumbnailMediaId = row.thumbnailMediaId {
                        rowItem.imageView.isHidden = false
                        rowItem.imageView.image = DeckThumbnailStore.shared.image(mediaId: thumbnailMediaId, side: imageSide)
                        rowItem.imageView.frame = CGRect(origin: CGPoint(x: 9.0, y: 4.0), size: deckThumbnailBoundingSize)
                        rowTextLeftInset += imageSide + 6.0
                    } else {
                        rowItem.imageView.isHidden = true
                        rowItem.imageView.image = nil
                    }
                    
                    let rowTitleNode = row.titleApply()
                    rowTitleNode.displaysAsynchronously = false
                    rowTitleNode.frame = CGRect(origin: CGPoint(x: rowTextLeftInset - textInsets.left - 2.0, y: spacing - textInsets.top + 1.0), size: row.titleLayout.size)
                    if rowItem.titleNode !== rowTitleNode {
                        rowItem.titleNode?.view.removeFromSuperview()
                        rowItem.titleNode = rowTitleNode
                        rowItem.containerView.addSubview(rowTitleNode.view)
                    }
                    let rowTextNode = row.textApply()
                    rowTextNode.displaysAsynchronously = false
                    rowTextNode.frame = CGRect(origin: CGPoint(x: rowTextLeftInset - textInsets.left - 2.0, y: rowTitleNode.frame.maxY - textInsets.bottom + spacing - textInsets.top - 2.0), size: row.textLayout.size)
                    if rowItem.textNode !== rowTextNode {
                        rowItem.textNode?.view.removeFromSuperview()
                        rowItem.textNode = rowTextNode
                        rowItem.containerView.addSubview(rowTextNode.view)
                    }
                    
                    node.deckCardTargets.append((messageId: row.messageId, frame: rowFrame))
                    
                    if isExpanding {
                        // Cards fan out from underneath the main card
                        let delay = 0.04 * Double(index)
                        rowItem.containerView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: (backgroundFrame.maxY - rowFrame.minY) * 0.6)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: delay, additive: true)
                        rowItem.containerView.layer.animateSpring(from: 0.9 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5, delay: delay)
                        rowItem.containerView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
                    }
                }
                if node.deckRowItems.count > deckRows.count {
                    let removedItems = node.deckRowItems[deckRows.count...]
                    node.deckRowItems.removeLast(node.deckRowItems.count - deckRows.count)
                    for rowItem in removedItems {
                        if isSameDeck {
                            // Cards slide back underneath the main card
                            let containerView = rowItem.containerView
                            containerView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: backgroundFrame.maxY - containerView.frame.maxY), duration: 0.25, removeOnCompletion: false, additive: true)
                            containerView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak containerView] _ in
                                containerView?.removeFromSuperview()
                            })
                        } else {
                            rowItem.containerView.removeFromSuperview()
                        }
                    }
                }
                
                if let deckSnapshotView {
                    animateDeckCardSwitch(containerView: node.view, contentView: node.contentNode.view, snapshotView: deckSnapshotView)
                }
                
                return node
            })
        }
    }
    
    public func updateTouchesAtPoint(_ point: CGPoint?) {
        var isHighlighted = false
        if point != nil {
            isHighlighted = true
        }
        
        let transition: ContainedViewLayoutTransition = .animated(duration: isHighlighted ? 0.3 : 0.2, curve: .easeInOut)
        let scale: CGFloat = isHighlighted ? ((self.bounds.width - 5.0) / self.bounds.width) : 1.0
        transition.updateSublayerTransformScale(node: self, scale: scale, beginWithCurrentState: true)
    }

    public func animateFromInputPanel(sourceReplyPanel: TransitionReplyPanel, unclippedTransitionNode: ASDisplayNode? = nil, localRect: CGRect, transition: CombinedTransition) -> CGPoint {
        let sourceParentNode = ASDisplayNode()

        let sourceParentOffset: CGPoint

        if let unclippedTransitionNode = unclippedTransitionNode {
            unclippedTransitionNode.addSubnode(sourceParentNode)
            sourceParentNode.frame = sourceReplyPanel.relativeSourceRect
            sourceParentOffset = self.view.convert(CGPoint(), to: sourceParentNode.view)
            sourceParentNode.clipsToBounds = true

            let panelOffset = sourceReplyPanel.relativeTargetRect.minY - sourceReplyPanel.relativeSourceRect.minY

            sourceParentNode.frame = sourceParentNode.frame.offsetBy(dx: 0.0, dy: panelOffset)
            sourceParentNode.bounds = sourceParentNode.bounds.offsetBy(dx: 0.0, dy: panelOffset)
            transition.vertical.animatePositionAdditive(layer: sourceParentNode.layer, offset: CGPoint(x: 0.0, y: -panelOffset))
            transition.vertical.animateOffsetAdditive(layer: sourceParentNode.layer, offset: -panelOffset)
        } else {
            self.addSubnode(sourceParentNode)
            sourceParentOffset = CGPoint()
        }

        sourceParentNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { [weak sourceParentNode] _ in
            sourceParentNode?.removeFromSupernode()
        })

        if let titleNode = self.titleNode {
            let offset = CGPoint(
                x: localRect.minX + sourceReplyPanel.titleView.frame.minX - titleNode.frame.minX,
                y: localRect.minY + sourceReplyPanel.titleView.frame.midY - titleNode.frame.midY
            )

            transition.horizontal.animatePositionAdditive(node: titleNode, offset: CGPoint(x: offset.x, y: 0.0))
            transition.vertical.animatePositionAdditive(node: titleNode, offset: CGPoint(x: 0.0, y: offset.y))

            sourceParentNode.view.addSubview(sourceReplyPanel.titleView)

            titleNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)

            sourceReplyPanel.titleView.frame = sourceReplyPanel.titleView.frame
                .offsetBy(dx: sourceParentOffset.x, dy: sourceParentOffset.y)
                .offsetBy(dx: localRect.minX - offset.x, dy: localRect.minY - offset.y)
            transition.horizontal.animatePositionAdditive(layer: sourceReplyPanel.titleView.layer, offset: CGPoint(x: offset.x, y: 0.0), removeOnCompletion: false)
            transition.vertical.animatePositionAdditive(layer: sourceReplyPanel.titleView.layer, offset: CGPoint(x: 0.0, y: offset.y), removeOnCompletion: false)
        }

        if let textNode = self.textNode {
            let offset = CGPoint(
                x: localRect.minX + sourceReplyPanel.textView.frame.minX - textNode.textNode.frame.minX,
                y: localRect.minY + sourceReplyPanel.textView.frame.midY - textNode.textNode.frame.midY
            )

            transition.horizontal.animatePositionAdditive(node: textNode.textNode, offset: CGPoint(x: offset.x, y: 0.0))
            transition.vertical.animatePositionAdditive(node: textNode.textNode, offset: CGPoint(x: 0.0, y: offset.y))

            sourceParentNode.view.addSubview(sourceReplyPanel.textView)

            textNode.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)

            sourceReplyPanel.textView.frame = sourceReplyPanel.textView.frame
                .offsetBy(dx: sourceParentOffset.x, dy: sourceParentOffset.y)
                .offsetBy(dx: localRect.minX - offset.x, dy: localRect.minY - offset.y)
            transition.horizontal.animatePositionAdditive(layer: sourceReplyPanel.textView.layer, offset: CGPoint(x: offset.x, y: 0.0), removeOnCompletion: false)
            transition.vertical.animatePositionAdditive(layer: sourceReplyPanel.textView.layer, offset: CGPoint(x: 0.0, y: offset.y), removeOnCompletion: false)
        }

        if let imageNode = self.imageNode {
            if let sourceImageView = sourceReplyPanel.imageView {
                let offset = CGPoint(
                    x: localRect.minX + sourceImageView.frame.midX - imageNode.frame.midX,
                    y: localRect.minY + sourceImageView.frame.midY - imageNode.frame.midY
                )
                
                transition.horizontal.animatePositionAdditive(node: imageNode, offset: CGPoint(x: offset.x, y: 0.0))
                transition.vertical.animatePositionAdditive(node: imageNode, offset: CGPoint(x: 0.0, y: offset.y))
                
                sourceParentNode.view.addSubview(sourceImageView)
                
                imageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                
                sourceImageView.frame = sourceImageView.frame
                    .offsetBy(dx: sourceParentOffset.x, dy: sourceParentOffset.y)
                    .offsetBy(dx: localRect.minX - offset.x, dy: localRect.minY - offset.y)
                transition.horizontal.animatePositionAdditive(layer: sourceImageView.layer, offset: CGPoint(x: offset.x, y: 0.0), removeOnCompletion: false)
                transition.vertical.animatePositionAdditive(layer: sourceImageView.layer, offset: CGPoint(x: 0.0, y: offset.y), removeOnCompletion: false)
            } else {
                imageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
            }
        }

        do {
            let backgroundView = self.backgroundView

            let offset = CGPoint(
                x: localRect.minX + sourceReplyPanel.lineView.frame.minX - backgroundView.frame.minX,
                y: localRect.minY + sourceReplyPanel.lineView.frame.minY - backgroundView.frame.minY
            )

            transition.horizontal.animatePositionAdditive(layer: backgroundView.layer, offset: CGPoint(x: offset.x, y: 0.0))
            transition.vertical.animatePositionAdditive(layer: backgroundView.layer, offset: CGPoint(x: 0.0, y: offset.y))

            sourceParentNode.view.addSubview(sourceReplyPanel.lineView)

            backgroundView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)

            sourceReplyPanel.lineView.frame = sourceReplyPanel.lineView.frame
                .offsetBy(dx: sourceParentOffset.x, dy: sourceParentOffset.y)
                .offsetBy(dx: localRect.minX - offset.x, dy: localRect.minY - offset.y)
            transition.horizontal.animatePositionAdditive(layer: sourceReplyPanel.lineView.layer, offset: CGPoint(x: offset.x, y: 0.0), removeOnCompletion: false)
            transition.vertical.animatePositionAdditive(layer: sourceReplyPanel.lineView.layer, offset: CGPoint(x: 0.0, y: offset.y), removeOnCompletion: false)

            return offset
        }
    }
    
    public func mediaTransitionView() -> UIView? {
        if let imageNode = self.imageNode {
            return imageNode.view
        }
        return nil
    }
}

private final class StarsView: UIView {
    private let staticEmitterLayer = CAEmitterLayer()
    
    private var currentColor: UIColor?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.clipsToBounds = true
    
        self.layer.addSublayer(self.staticEmitterLayer)
    }
    
    required init(coder: NSCoder) {
        preconditionFailure()
    }
        
    private func setupEmitter(size: CGSize) {
        guard let currentColor = self.currentColor else {
            return
        }
        let color = currentColor
        
        self.staticEmitterLayer.emitterShape = .rectangle
        self.staticEmitterLayer.emitterSize = size
        self.staticEmitterLayer.emitterMode = .surface
        self.layer.addSublayer(self.staticEmitterLayer)
        
        let staticEmitter = CAEmitterCell()
        staticEmitter.name = "emitter"
        staticEmitter.contents = UIImage(bundleImageName: "Premium/Stars/Particle")?.cgImage
        staticEmitter.birthRate = 20.0
        staticEmitter.lifetime = 3.2
        staticEmitter.velocity = 18.0
        staticEmitter.velocityRange = 3
        staticEmitter.scale = 0.1
        staticEmitter.scaleRange = 0.08
        staticEmitter.emissionRange = .pi * 2.0
        staticEmitter.setValue(3.0, forKey: "mass")
        staticEmitter.setValue(2.0, forKey: "massRange")
        
        let staticColors: [Any] = [
            color.withAlphaComponent(0.0).cgColor,
            color.cgColor,
            color.withAlphaComponent(0.0).cgColor,
            color.withAlphaComponent(0.0).cgColor,
            color.cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        let staticColorBehavior = CAEmitterCell.createEmitterBehavior(type: "colorOverLife")
        staticColorBehavior.setValue(staticColors, forKey: "colors")
        staticEmitter.setValue([staticColorBehavior], forKey: "emitterBehaviors")
        
        let attractor = CAEmitterCell.createEmitterBehavior(type: "simpleAttractor")
        attractor.setValue("attractor", forKey: "name")
        attractor.setValue(20, forKey: "falloff")
        attractor.setValue(35, forKey: "radius")
        self.staticEmitterLayer.setValue([attractor], forKey: "emitterBehaviors")
        self.staticEmitterLayer.setValue(4.0, forKeyPath: "emitterBehaviors.attractor.stiffness")
        self.staticEmitterLayer.setValue(false, forKeyPath: "emitterBehaviors.attractor.enabled")
        
        self.staticEmitterLayer.emitterCells = [staticEmitter]
    }
    
    func update(size: CGSize, color: UIColor) {
        if self.staticEmitterLayer.emitterCells == nil {
            self.currentColor = color
            self.setupEmitter(size: size)
        } else if self.currentColor != color {
            self.currentColor = color
            
            let staticColors: [Any] = [
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.35).cgColor,
                color.cgColor,
                color.cgColor,
                color.withAlphaComponent(0.0).cgColor
            ]
            let staticColorBehavior = CAEmitterCell.createEmitterBehavior(type: "colorOverLife")
            staticColorBehavior.setValue(staticColors, forKey: "colors")
            
            for cell in self.staticEmitterLayer.emitterCells ?? [] {
                cell.setValue([staticColorBehavior], forKey: "emitterBehaviors")
            }
        }
        
        let emitterPosition = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        self.staticEmitterLayer.frame = CGRect(origin: .zero, size: size)
        self.staticEmitterLayer.emitterPosition = emitterPosition
        self.staticEmitterLayer.setValue(emitterPosition, forKeyPath: "emitterBehaviors.attractor.position")
    }
}

// The outgoing card is swiped away while the next one rises from underneath it
private func animateDeckCardSwitch(containerView: UIView, contentView: UIView, snapshotView: UIView) {
    snapshotView.frame = CGRect(origin: CGPoint(), size: snapshotView.bounds.size)
    containerView.addSubview(snapshotView)
    snapshotView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -14.0), duration: 0.25, timingFunction: CAMediaTimingFunctionName.easeIn.rawValue, removeOnCompletion: false, additive: true)
    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false, completion: { [weak snapshotView] _ in
        snapshotView?.removeFromSuperview()
    })
    
    contentView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: 10.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.45, additive: true)
    contentView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
}

private func deckCounterString(text: String, font: UIFont, color: UIColor, withCollapseChevron: Bool) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    if withCollapseChevron, let chevron = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize - 2.0, weight: .bold))?.withTintColor(color, renderingMode: .alwaysOriginal) {
        let attachment = NSTextAttachment()
        attachment.image = chevron
        attachment.bounds = CGRect(origin: CGPoint(x: 0.0, y: floor((font.capHeight - chevron.size.height) * 0.5)), size: chevron.size)
        result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        result.append(NSAttributedString(attachment: attachment))
    }
    return result
}

private final class DeckRowItem {
    let containerView: UIView
    let backgroundView: MessageInlineBlockBackgroundView
    let imageView: UIImageView
    var titleNode: TextNode?
    var textNode: TextNode?
    var thumbnailMediaId: EngineMedia.Id?
    
    init() {
        self.containerView = UIView()
        self.containerView.isUserInteractionEnabled = false
        self.backgroundView = MessageInlineBlockBackgroundView()
        self.containerView.addSubview(self.backgroundView)
        self.imageView = UIImageView()
        self.containerView.addSubview(self.imageView)
    }
}

private struct DeckCardThumbnail {
    let mediaId: EngineMedia.Id
    let dimensions: CGSize
    let signal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>
    // A photo's file once it is on disk: drawn straight from it, which does not wait for the preview cache
    let localData: Signal<Data, NoError>?
}

// Previews of deck cards, rendered as soon as a deck is shown so that a card flipped to or listed has its preview
// at once. Kept outside the node: a bubble may lay its header out into a fresh node, and a load restarted on
// every layout pass would never finish. Main thread only.
private final class DeckThumbnailStore {
    static let shared = DeckThumbnailStore()
    
    private struct Key: Hashable {
        let mediaId: EngineMedia.Id
        let side: CGFloat
    }
    
    private var images: [Key: UIImage] = [:]
    private var loads: [Key: Disposable] = [:]
    private var localLoads: [Key: Disposable] = [:]
    private var observers: [Key: [ObjectIdentifier: (UIImage) -> Void]] = [:]
    
    func image(mediaId: EngineMedia.Id, side: CGFloat) -> UIImage? {
        return self.images[Key(mediaId: mediaId, side: side)]
    }
    
    func load(_ thumbnail: DeckCardThumbnail, side: CGFloat, emptyColor: UIColor, observer: AnyObject, update: @escaping (UIImage) -> Void) {
        let key = Key(mediaId: thumbnail.mediaId, side: side)
        self.observers[key, default: [:]][ObjectIdentifier(observer)] = update
        if self.loads[key] != nil {
            return
        }
        if self.loads.count >= 64 {
            for (_, disposable) in self.loads {
                disposable.dispose()
            }
            self.loads.removeAll()
            for (_, disposable) in self.localLoads {
                disposable.dispose()
            }
            self.localLoads.removeAll()
            self.images.removeAll()
            self.observers = [key: self.observers[key] ?? [:]]
        }
        self.start(key: key, thumbnail: thumbnail, emptyColor: emptyColor, attempt: 0)
    }
    
    private func start(key: Key, thumbnail: DeckCardThumbnail, emptyColor: UIColor, attempt: Int) {
        let boundingSize = CGSize(width: key.side, height: key.side)
        let arguments = TransformImageArguments(corners: ImageCorners(radius: 4.0), imageSize: thumbnail.dimensions.aspectFilled(boundingSize), boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets(), emptyColor: emptyColor)
        // A load now and then never reports back; one that has produced nothing after a moment is started again
        if attempt < 10 {
            Queue.mainQueue().after(0.4, { [weak self] in
                guard let self, self.images[key] == nil, let disposable = self.loads[key] else {
                    return
                }
                disposable.dispose()
                self.start(key: key, thumbnail: thumbnail, emptyColor: emptyColor, attempt: attempt + 1)
            })
        }
        if let localData = thumbnail.localData, self.localLoads[key] == nil {
            self.localLoads[key] = (localData
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
                guard let self, let image, self.images[key] == nil else {
                    return
                }
                self.images[key] = image
                for (_, update) in self.observers[key] ?? [:] {
                    update(image)
                }
            })
        }
        // Kept running: a sharper version replaces the first one when the full-size photo arrives
        self.loads[key] = (thumbnail.signal
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { transform -> UIImage? in
            let result = transform(arguments)?.generateImage()
            return result
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self] image in
            guard let self, let image else {
                return
            }
            self.images[key] = image
            for (_, update) in self.observers[key] ?? [:] {
                update(image)
            }
        })
    }
}

// The preview a deck card shows, as a regular reply does: a photo, or a video's frame
private func deckCardThumbnail(context: AccountContext, message: EngineRawMessage) -> DeckCardThumbnail? {
    if message.containsSecretMedia {
        return nil
    }
    let hasSpoiler = message.attributes.contains(where: { $0 is MediaSpoilerMessageAttribute })
    for media in message.media {
        if let image = media as? TelegramMediaImage, let imageId = image.id, let representation = largestRepresentationForPhoto(image) {
            return DeckCardThumbnail(mediaId: imageId, dimensions: representation.dimensions.cgSize, signal: chatMessagePhotoThumbnail(account: context.account, userLocation: .peer(message.id.peerId), photoReference: .message(message: MessageReference(message), media: image), blurred: hasSpoiler), localData: hasSpoiler ? nil : deckLocalData(context: context, resource: representation.resource))
        } else if let file = media as? TelegramMediaFile, file.isVideo, !file.isVideoSticker, !file.isInstantVideo, let fileId = file.id, let dimensions = file.dimensions {
            return DeckCardThumbnail(mediaId: fileId, dimensions: dimensions.cgSize, signal: chatMessageVideoThumbnail(account: context.account, userLocation: .peer(message.id.peerId), fileReference: .message(message: MessageReference(message), media: file), blurred: hasSpoiler), localData: nil)
        }
    }
    return nil
}

private func deckLocalData(context: AccountContext, resource: TelegramMediaResource) -> Signal<Data, NoError> {
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

private let deckCardShift: CGFloat = 4.0

private struct DeckStackImageKey: Equatable {
    let size: CGSize
    let cardSize: CGSize
    let count: Int
    let color: UInt32
}

// Each card is shifted right and down by `deckCardShift` from the one in front of it
private func generateDeckStackImage(size: CGSize, cardSize: CGSize, count: Int, color: UIColor) -> UIImage? {
    return generateImage(size, rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        let cornerRadius: CGFloat = 4.0
        for index in stride(from: count, through: 0, by: -1) {
            let cardRect = CGRect(origin: CGPoint(x: CGFloat(index) * deckCardShift, y: CGFloat(index) * deckCardShift), size: cardSize)
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cornerRadius).cgPath
            
            context.setBlendMode(.clear)
            context.addPath(cardPath)
            context.fillPath()
            context.setBlendMode(.normal)
            
            if index == 0 {
                break
            }
            context.saveGState()
            context.addPath(cardPath)
            context.clip()
            context.setFillColor(color.withMultipliedAlpha(index == 1 ? 0.16 : 0.1).cgColor)
            context.fill(cardRect)
            context.setFillColor(color.withMultipliedAlpha(index == 1 ? 0.6 : 0.35).cgColor)
            context.fill(CGRect(x: cardRect.minX, y: cardRect.minY, width: 3.0, height: cardRect.height))
            context.restoreGState()
        }
    })
}
