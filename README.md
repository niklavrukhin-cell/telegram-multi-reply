# Multi-Reply — reply to several messages at once (iOS)

Select 2–5 messages, tap **Reply**, and they become one quote: a deck.
Answers [bugs.telegram.org/c/1216](https://bugs.telegram.org/c/1216), open since January 2021.

▶︎ [Media/multi-reply.mp4](Media/multi-reply.mp4) — the feature on a real iPhone (1:1).

Pure UIKit, no new dependencies. Built and tested on a real iPhone (debug and release).
12 files, +1591 −34, one new file: `MultiReplyStore.swift`.

## How it works

- **Selection bar.** With 2–5 messages selected, a Reply button appears next to Share.
- **Composer.** One quote stacks the messages as a deck with a `1/3` counter. Tap to flip through
  the cards, long press to list all of them and remove any. The close button removes only the
  visible card. Regular Reply is unchanged and replaces the deck.
- **Sent message.** The cards peek out from behind the quote and the counter flips them. A tap
  expands the list, a tap on a card opens that message. Cards that reply to a photo or video show
  a small preview.

## Repository

| Path | What |
|---|---|
| `submodules/` | The changed files, at their paths in Telegram-iOS. Copy over the repository. |
| `multi-reply.patch` | The same change as one patch. |
| `Media/multi-reply.mp4` | Demo. |

Where the code lives:

| File | What |
|---|---|
| `AccountContext/Sources/MultiReplyStore.swift` | **New.** The deck of a message: stored locally, active card, expanded state. |
| `ChatInputMessageAccessoryPanel.swift` | The deck in the composer: counter, flip, the list with remove buttons. |
| `ChatMessageReplyInfoNode.swift` | The deck in a sent message: stacked cards, flip, expanded list. |
| `ChatMessageBubbleItemNode.swift` | Taps on a sent deck. |
| `ChatMessageSelectionInputPanelNode.swift` | The Reply button in the selection bar. |
| `ChatInterfaceState.swift`, `ChatPanelInterfaceInteraction.swift`, `ChatController*.swift`, … | Wiring: `ReplyMessageSubject.extraMessageIds`, sending, drafts. |

## Apply

Applies cleanly to [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS)
`master` (f1dd7a2d):

```sh
git apply multi-reply.patch
```

or copy `submodules/` over the repository. No changes to any `BUILD` file are needed.

## What it needs from the server

The API keeps a single reply target. So the first message is sent as the regular `reply_to_msg_id`
(every existing client shows an ordinary reply), and for now the deck is stored on the sender's
device. Only the sender sees the deck until the API carries it.

The same way `todo_item_id` and `poll_option` were added to both reply constructors, one optional
vector would be enough:

```
inputReplyToMessage ... extra_reply_to_msg_ids:flags.N?Vector<int>
messageReplyHeader  ... extra_reply_to_msg_ids:flags.M?Vector<int>
```

- `reply_to_msg_id` stays the first (oldest) message, so old clients keep working;
  `extra_reply_to_msg_ids` holds the rest, oldest first.
- No new methods: `sendMessage`, `sendMedia`, `sendMultiMedia` and `saveDraft` already take
  `InputReplyTo`, so cloud drafts sync the deck too.
- Suggested rules: 2–5 messages in total, all in the same chat and topic; duplicates removed;
  inaccessible ids fail as today.

On the client the deck is already a list of message ids end to end, so switching is small: map the
field both ways, give `ReplyMessageAttribute` the extra ids, and drop the local deck storage.

## License

Changes to [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), published openly so that they can be used under the terms of the original project.
