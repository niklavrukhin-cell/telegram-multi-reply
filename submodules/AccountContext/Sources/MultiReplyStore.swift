import Foundation
import TelegramCore

// A reply to several messages at once. The server keeps a single reply target, so the whole
// deck is kept locally, keyed by the stable id of the sent message
public final class MultiReplyStore {
    public struct Deck: Equatable {
        public let messageIds: [EngineMessage.Id]
        public let activeIndex: Int
        public let isExpanded: Bool
        
        public init(messageIds: [EngineMessage.Id], activeIndex: Int, isExpanded: Bool) {
            self.messageIds = messageIds
            self.activeIndex = activeIndex
            self.isExpanded = isExpanded
        }
        
        public var activeMessageId: EngineMessage.Id {
            return self.messageIds[self.activeIndex]
        }
    }
    
    public static let shared = MultiReplyStore()
    
    public static let maxMessageCount = 5
    
    private static let defaultsKey = "MultiReplyStore.decks"
    
    private let lock = NSLock()
    private var decks: [UInt32: [EngineMessage.Id]] = [:]
    private var activeIndices: [UInt32: Int] = [:]
    private var expandedStableIds = Set<UInt32>()
    private var pendingDecks: [EnginePeer.Id: [EngineMessage.Id]] = [:]
    // A message being sent has no stable id yet, so its deck is keyed by the first target
    private var inFlightDecks: [EngineMessage.Id: [EngineMessage.Id]] = [:]
    private var cachedMessages: [EngineMessage.Id: EngineRawMessage] = [:]
    
    private init() {
        self.load()
    }
    
    public func setPendingDeck(messageIds: [EngineMessage.Id], messages: [EngineRawMessage]) {
        guard let firstMessageId = messageIds.first else {
            return
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pendingDecks[firstMessageId.peerId] = messageIds
        for message in messages {
            self.cachedMessages[message.id] = message
        }
    }
    
    public func clearPendingDeck(peerId: EnginePeer.Id) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pendingDecks[peerId] = nil
    }
    
    public func takePendingDeck(firstMessageId: EngineMessage.Id) -> [EngineMessage.Id]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let messageIds = self.pendingDecks[firstMessageId.peerId], messageIds.first == firstMessageId else {
            return nil
        }
        self.pendingDecks[firstMessageId.peerId] = nil
        self.inFlightDecks[firstMessageId] = messageIds
        return messageIds
    }
    
    public func inFlightDeck(firstMessageId: EngineMessage.Id) -> [EngineMessage.Id]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.inFlightDecks[firstMessageId]
    }
    
    public func register(stableId: UInt32, messageIds: [EngineMessage.Id]) {
        guard let firstMessageId = messageIds.first else {
            return
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.decks[stableId] = messageIds
        self.inFlightDecks[firstMessageId] = nil
        self.save()
    }
    
    public func deck(parentStableId: UInt32) -> Deck? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let messageIds = self.decks[parentStableId] else {
            return nil
        }
        return Deck(messageIds: messageIds, activeIndex: self.activeIndices[parentStableId] ?? 0, isExpanded: self.expandedStableIds.contains(parentStableId))
    }
    
    public func advance(parentStableId: UInt32) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let messageIds = self.decks[parentStableId] else {
            return
        }
        self.activeIndices[parentStableId] = ((self.activeIndices[parentStableId] ?? 0) + 1) % messageIds.count
    }
    
    public func setExpanded(parentStableId: UInt32, isExpanded: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if isExpanded {
            self.expandedStableIds.insert(parentStableId)
        } else {
            self.expandedStableIds.remove(parentStableId)
        }
    }
    
    public func cachedMessage(id: EngineMessage.Id) -> EngineRawMessage? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cachedMessages[id]
    }
    
    public func cacheMessage(_ message: EngineRawMessage) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.cachedMessages[message.id] = message
    }
    
    private func save() {
        var encoded: [String: [Int64]] = [:]
        for (stableId, messageIds) in self.decks {
            encoded[String(stableId)] = messageIds.flatMap { [$0.peerId.toInt64(), Int64($0.namespace), Int64($0.id)] }
        }
        UserDefaults.standard.set(encoded, forKey: MultiReplyStore.defaultsKey)
    }
    
    private func load() {
        guard let encoded = UserDefaults.standard.dictionary(forKey: MultiReplyStore.defaultsKey) as? [String: [Int64]] else {
            return
        }
        for (key, values) in encoded {
            guard let stableId = UInt32(key), values.count % 3 == 0 else {
                continue
            }
            self.decks[stableId] = stride(from: 0, to: values.count, by: 3).map { i in
                EngineMessage.Id(peerId: EnginePeer.Id(values[i]), namespace: Int32(values[i + 1]), id: Int32(values[i + 2]))
            }
        }
    }
}
