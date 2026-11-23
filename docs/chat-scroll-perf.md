# Chat message list: scrolling performance

Goal: dragging or flinging through a chat's history stays smooth at 120 Hz (8.3 ms per frame), including image-heavy
chats. Before this work, users reported the message list as "giật cục" (janky) when dragging continuously.

## How it is measured

`Olaz --scroll-bench <outdir> [label]` (`Sources/Olaz/ZaloRuntime/ScrollBench.swift`) is an offline benchmark of the real
`ChatView`:

- It needs no live session. It never starts the engine and opens no store, Keychain item or socket. It never reads
  `~/Library/Application Support/Olaz`, so it can run beside the real app.
- A side-effect-free `ZaloEngine` gets a synthetic group chat of 1200 messages. The mix covers:
  - text of every length, links, @mentions, quotes and reactions;
  - 18% photos (camera-sized JPEGs generated into `<outdir>`, a distinct URL per message, so each one is decoded);
  - stickers, files, link cards, voice, video, calls and notices.
- Media goes through the real `MediaLoader`, whose caches are redirected into `<outdir>`.
- The window shows the real chat: rows, pinned bar and composer. The list is scrolled programmatically, one step per
  display frame, at a steady speed. This is a held drag; a fling is the same at 3× the speed.

Passes:

| pass | what |
|---|---|
| DRAG-UP-COLD | 2400 pt/s from the newest message up for 12 s: rows and photos never shown before |
| DRAG-DOWN-WARM | back down over the same rows |
| FLING-UP / FLING-DOWN | 7200 pt/s each way |
| DRAG-UP-LIVE | a drag up while the chat is live: a reaction changes every 200 ms, a message arrives every second |
| PREPEND-PAGES | at the top of a 200-message chat, five older pages of 50 land while the reader keeps pulling |

Per pass the bench records:

- every display-link frame interval: dropped frames, hitch time in ms/s, p99;
- main-thread CPU time per frame (`thread_info`);
- instructions the process retired (`proc_pid_rusage` v4), reported per 1000 pt scrolled;
- RSS.

`scripts/scroll-bench/compare.sh <outdir> <rounds> <dirA> <dirB>` runs builds interleaved and prints the medians.

### Pitfalls found while measuring

- **The machine was shared.** Other sessions were building, and the load average swung between 3 and 25. Wall-clock frame
  times and even CPU time moved 2–4× between identical runs. The comparison below therefore leads with instructions per
  1000 pt scrolled, which depends neither on load nor on the core type. Frame and drop figures are kept for reference
  only. Builds always ran interleaved.
- **The pointer changes everything.** Rows passing under a resting pointer show and hide their hover bar. That made the
  same base binary cost 279 or 1047 M instructions per 1000 pt depending on where the user's mouse happened to be. The
  bench never moves the pointer. Instead, `OLAZ_BENCH_POINTER=over` puts the window under it, which is what trackpad
  scrolling looks like. `away` (the default) puts the window on the other half of the screen.
- **No 120 Hz panel was available.** The MacBook was in clamshell mode on a 60 Hz Dell U2422HE, so frame pacing was
  measured at 60 Hz. The figure that carries over to 120 Hz is the work per frame against the 8.3 ms budget. At the same
  speed, a 120 Hz frame moves half the distance.

## What the time went into (base)

Time Profiler on the base build, main thread, 35 s of the bench:

- ~72% was SwiftUI's `LazyVStack` laying itself out again on every scroll step. The main frames were:
  - `LazySubviewPlacements.placeSubviews`
  - `LazyHVStack.lengthAndSpacing`
  - `sizeThatFits` of the realized rows
  - `DynamicContainerInfo.updateItems`
- Olaz's own code was ~0%.

So per-frame cost scaled with the rows on screen, not with what changed. No tweak to row views could get that to 8 ms.
On top of that, when the pointer rests over the list, every row passing under it animated its glass hover bar in and out.

## Telegram for macOS, and what applies here

TelegramSwift (`TableView` on `NSTableView`, `ChatController`, `TableRowItem`) keeps scrolling cheap like this:

1. **Row heights are computed once, from a layout model, off the main thread.** `TableRowItem.makeSize(width)` runs
   CoreText layouts and caches the size. The table only reads cached heights.
2. **Views are recycled** by identifier, and a recycled view only draws its cached layout.
3. **Images are decoded at display size, asynchronously,** and drawn into layers.
4. **Updates are transitions with a scroll-state policy** (`saveVisible`, top or bottom anchors), so inserting older
   history never moves the row being read.
5. **Nothing reacts to scrolling** except the table's own tiling.

How each maps onto Olaz:

| Telegram technique | Status in Olaz | Notes |
|---|---|---|
| 1. Off-main row heights | Partly applied | Rows stay SwiftUI views, so they must be measured on the main thread. Each is measured once and memoized per message and width. Rows near the screen are measured first, the rest in 4 ms idle slices, and only when there are spare cycles ahead of the viewport. They are never measured per frame. A CoreText layout model for every message kind would allow true off-main measuring, but it is a rewrite of every bubble. |
| 2. View recycling | Applied | One `NSHostingController` per row, kept per message (LRU of 120). Spare hosts are recycled per row kind, so a new row usually re-roots an existing SwiftUI graph of the same shape. |
| 3. Images decoded at display size, async | Already there | `MediaLoader` / Rust `CoreMedia` decode off-main with ImageIO thumbnails at 2× display size and cache them. Not a bottleneck in the profiles. |
| 4. Updates keep the reader's row in place | Applied | Every change (page above, new message, row height change, resize, bars appearing) keeps the anchor row at its screen position, or keeps the list at the bottom when it was there. Prepending needs no restore hacks any more. |
| 5. Nothing else reacts to scrolling | Applied | Hover is ignored while the list moves (`ChatScrollActivity`). Rows no longer carry a geometry observer. |

## Changes

1. **`ChatListView` / `ChatListController`** (`Sources/Olaz/Views/ChatListView.swift`) replace the SwiftUI
   `ScrollView` + `LazyVStack`.
   - **Layout.** An `NSScrollView` with a flipped document view places one `NSHostingController` per row by plain
     frames. There is no Auto Layout and no lazy-stack diffing. The rows are still the same SwiftUI `MessageRow` /
     `DaySeparator` views, so features and visuals are unchanged.
   - **Heights.** Each row is measured with `sizeThatFits` at the column width, memoized per message, and
     re-measured only when its data, the width or the text size changes. A row whose content changes size by itself (a
     GIF arrives, a file card's note) is noticed through its controller's `preferredContentSize`. A per-row
     `onGeometryChange` cost ~25% of a scroll frame because it re-evaluated on every step.
   - **What sits in the window.** Only rows on screen ±160 pt are in the window: each hosting view in the window is laid
     out again on every scroll step. Rows further out keep their host but are detached.
   - **Spreading the work.** Rows about to appear are measured with the host that will show them; off-screen ones get a
     3 ms per-frame budget.
   - **Fixes found while building it:**
     - The representable declares `sizeThatFits`. Without it, SwiftUI asked the scroll view for its Auto Layout fitting
       size on every frame, which walked every row host.
     - The bars' room is padding inside the document. `NSClipView` clamped the origin with insets of its own and left the
       newest row under the composer.
     - The list keeps a sticky "at bottom" flag, so a resize keeps it at the bottom.
2. **`MessageList`** (`ChatView.swift`) drives the new list.
   - It keeps the same behaviors: open at the newest message, follow new messages near the bottom, jump to a pin or
     search match, "scroll to newest" button, the tour step.
   - Older history is now requested one screen before the top (it was 120 pt). Paging is still one page per pull.
   - Removed: the scroll-position restore and the 2 s bottom pin, which existed only to work around `LazyVStack`.
3. **Hover suppressed while scrolling** (`MessageRow.onHover` + `ChatScrollActivity`). This matches Messages and
   Telegram: the hover bar appears again on the next mouse move after the list stops.
4. **`ScrollBench`** and `MediaLoader.sharedCacheDirectory` (benchmark only), plus the compare scripts.
5. **Tests.** `ChatListLayoutTests` cover:
   - opening at the newest row;
   - a prepended page keeping the reader's row in place;
   - a conversation switch starting at the bottom;
   - rows above the screen changing height without moving what is shown;
   - bars arriving after opening.

   `ChatScrollRestoreTests` and `ChatRow.restoreTarget` are gone, since the anchor replaces them.

## Results

Same bench: 1200 messages, 760×860 window, 60 Hz display. Base is HEAD `d16c230` with only the bench added. Builds ran
interleaved, 3 rounds per scenario, and the tables show the median. "M instr/kpt" is millions of instructions retired
per 1000 pt scrolled. The frame columns are wall-clock at 60 Hz on a loaded machine: read them as a trend.

### Pointer resting over the list (trackpad scrolling)

| pass | base: M instr/kpt | new: M instr/kpt | base: main CPU ms/frame | new: main CPU ms/frame | base: dropped | new: dropped | base: p99 ms | new: p99 ms |
|---|---|---|---|---|---|---|---|---|
| drag up, cold | 1397 | **696** | 6.65 | **3.00** | 28.5% | **3.9%** | 29.4 | **16.7** |
| drag down, warm | 1066 | **396** | 6.19 | **2.98** | 27.0% | **1.8%** | 32.6 | **16.7** |
| fling up | 659 | **390** | 12.81 | **4.01** | 51.0% | **6.1%** | 30.8 | **16.7** |
| fling down | 521 | **219** | 11.85 | **3.54** | 49.2% | **4.5%** | 33.0 | **16.7** |
| all four | — | — | 8.85 | **3.34** | 39.2% | **3.7%** | 32.7 | **16.7** |
| live chat, drag up | 1123 | **550** | 6.16 | **2.79** | 26.4% | **7.9%** | 29.1 | **24.9** |
| older pages landing | — | — | 4.46 | **1.15** | 7.8% | **2.9%** | 22.5 | **16.6** |

### Pointer elsewhere

| pass | base: M instr/kpt | new: M instr/kpt | base: main CPU ms/frame | new: main CPU ms/frame | base: dropped | new: dropped | base: p99 ms | new: p99 ms |
|---|---|---|---|---|---|---|---|---|
| drag up, cold | 754 | **648** | 2.92 | 2.74 | 3.4% | 2.2% | 21.0 | 16.7 |
| drag down, warm | 379 | **336** | 2.86 | 2.98 | 0.3% | 1.0% | 10.3 | 16.6 |
| fling up | 421 | **368** | 4.38 | 3.85 | 7.1% | 2.6% | 21.8 | 16.7 |
| fling down | 237 | **198** | 3.46 | 3.39 | 0.5% | 2.2% | 9.0 | 16.7 |
| all four | — | — | 3.40 | 3.24 | 2.7% | 2.0% | 20.5 | 16.7 |
| live chat, drag up | 437 | 492 | 2.86 | 2.98 | 3.9% | 6.1% | 16.7 | 25.0 |
| older pages landing | — | — | 2.63 | **1.35** | 0.3% | 2.4% | 10.7 | 15.0 |

Memory (RSS at the end of a run): base ~110 MB, new ~170–260 MB. The cost is per-row hosts and their decoded images; a
smaller host cache (80 hosts, 4 spares per kind) saved nothing measurable and was slower.

### Reading the numbers

- **Pointer over the list.** This is how people scroll with a trackpad, and here the old list did the work of 2–3 frames
  in every frame. It dropped 40–50% of frames when flinging, which is the "giật cục". The new list does a third to half
  the work, and its p99 frame stays at one 60 Hz frame.
- **Pointer elsewhere.** The old list was already fine at 60 Hz. The new one does 10–15% less work and has fewer
  long frames (p99 16.7 ms).
- **At 120 Hz.** Main-thread work is 3–4 ms per frame at 60 Hz speeds, against an 8.3 ms budget. A 120 Hz frame covers
  half the distance, so there is headroom. The base, with the pointer over the list, was at 6–13 ms per 60 Hz frame and
  could not hold 120 Hz.
- **Regressions, both small:**
  - The live-chat pass costs ~12% more instructions when the pointer is elsewhere: each update still compares every row
    once.
  - When a page of older history lands, the frame that measures the rows now on screen can be one frame long (p99
    15–17 ms against 11 ms), although the total work halves.

Earlier wall-clock-only runs during this work (for example base 8.5 vs new 4.5 ms per frame) were skewed by the
machine's load and by where the pointer was. They are superseded by the tables above.

## Not done / follow-ups

- **Cold rows still cost one SwiftUI render each** (~1–3 ms for a photo or link card) the first time they appear. The next
  step is a CoreText / CALayer layout model per message kind (Telegram's approach). It would make cold scrolling as
  cheap as warm scrolling, but it means rewriting every bubble outside SwiftUI.
- **Memory.** RSS is ~60–150 MB higher in the bench (per-row hosts and their images). `hostLimit` and the spare pools
  were not where it goes; it is worth an Allocations trace.
- **Flaky test.** `MediaRecoveryTests.queueIsLIFOAndDropsCancelledWork` failed once in an `OLAZ_RUST_CORE=0` run under load
  (it uses 20 ms sleeps) and passed 3/3 alone. It is not touched by this change.
- **Top scroll edge effect.** The bottom soft edge effect under the composer still applies; SwiftUI's `safeAreaBar`
  applies it to the AppKit scroll view. The top `.hard` edge effect under the toolbar was a SwiftUI `ScrollView`
  modifier, so the top now shows AppKit's default titlebar treatment. Check it in the real window.
- **Conversation list (done after this change).** The sidebar `List` re-diffed all ~700 rows on every
  `engine.conversations` change: ~134 ms of main thread and 1.5 G instructions per arriving message, 48% of frames
  dropped while messages arrived. `ConversationTableView` (an `NSTableView` hosting the same SwiftUI rows, diffing ids
  and re-rooting only visible changed rows) brings that to ~19 ms and 51 M instructions per message, 3.4% dropped
  (`OLAZ_BENCH_MODE=convlist Olaz --scroll-bench`, 700 chats, 120 Hz).
- **Rows held by the conversation.** `MessageRow` still observes the engine (`profile`, `canCall`). That is fine with
  per-row hosts, because only rows that read a changed value update.
