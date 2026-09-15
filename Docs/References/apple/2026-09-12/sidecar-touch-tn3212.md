<!--
{
  "documentType" : "article",
  "framework" : "Technotes",
  "identifier" : "/documentation/Technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support",
  "metadataVersion" : "0.1.0",
  "role" : "article",
  "title" : "TN3212: Adopting gesture recognizers for Sidecar touch support"
}
-->

# TN3212: Adopting gesture recognizers for Sidecar touch support

Use gesture recognizers to handle Sidecar touch input and update your event-handling code for macOS 27.

## Overview

In macOS 27, AppKit continues to standardize on gesture recognizers as the primary mechanism for input handling. This change directly affects Sidecar because gesture recognizers are the only way to respond to touch input from a Sidecar-connected iPad running iPadOS 27. If your app relies on tracking loops for mouse event handling, migrate to gesture recognizers to support Sidecar touch input.

This article explains how the gesture recognizer model works, how to implement gesture recognizers correctly for Sidecar touch input, how to update your existing event-handling code, and which APIs macOS 27 adds. Codebases that implement <doc://com.apple.documentation/documentation/AppKit/NSWindow/nextEvent(matching:)> or <doc://com.apple.documentation/documentation/AppKit/NSResponder/mouseDown(with:)>, <doc://com.apple.documentation/documentation/AppKit/NSResponder/mouseDragged(with:)>, and <doc://com.apple.documentation/documentation/AppKit/NSResponder/mouseUp(with:)> events are most affected by the updates discussed.

## Understand how gesture recognizers gather events

In the traditional AppKit responder-based model, mouse event handling was relatively insensitive to the z-ordering of sibling views. As long as a view called through to the superclass’s `mouseDown(with:)` implementation, the event passed through to any hit-testable underlapped sibling. This conveyance through the responder chain effectively bypassed normal hit testing, which wouldn’t consider the underlapped sibling or its descendants.

Gesture recognizers work differently. They don’t follow the responder event chain. Instead, AppKit gathers all possible gesture recognizers at mouse-down or touch-began, using a strict walk of the view hierarchy from the hit-tested top-most view among siblings up to the window. From that point, the gathered set of recognizers all receive the stream of events until the end of the event sequence. This has a few important implications:

- If your view is covered by another, often transparent, view, your gesture recognizer won’t be triggered. This is a common source of confusion when first working with gesture recognizers.
- You can’t place views on top of standard framework controls, because those controls now use gesture recognizers internally. The overlapping view prevents those recognizers from activating. If necessary, rearrange the siblings, or override the occluding view’s <doc://com.apple.documentation/documentation/AppKit/NSView/hitTest(_:)> method and return `nil` to ensure it doesn’t block events going to underlying controls.
- Gesture recognizers can only be added to views. If you want your view controller to handle touch events, add a gesture recognizer to its view and make the view controller the target and delegate.

## Handle Sidecar touch input

Unlike Touch Bar on Mac and touch events in UIKit, gesture recognizers are the only mechanism for receiving direct Sidecar touches. AppKit doesn’t deliver Sidecar touch events through the responder chain or through event monitors.

> Local and global event monitors don’t receive touch events. Touch events don’t go through <doc://com.apple.documentation/documentation/AppKit/NSApp> or <doc://com.apple.documentation/documentation/AppKit/NSWindow/sendEvent(_:)>.

For touch recognizers that need to yield to scrolling, set the <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/isCancellableByScrollGesture> property to `true`.

## Update your event-handling code

The transition to gesture recognizers on <doc://com.apple.documentation/documentation/AppKit/NSControl> objects changes the timing of when AppKit delivers control action messages with respect to event processing. As a result, <doc://com.apple.documentation/documentation/AppKit/NSApplication/currentEvent> no longer returns the event that triggered an action. Use the <doc://com.apple.documentation/documentation/AppKit/NSEvent/modifierFlags-swift.type.property> and <doc://com.apple.documentation/documentation/AppKit/NSEvent/pressedMouseButtons> class properties on <doc://com.apple.documentation/documentation/AppKit/NSEvent> instead. Note that a touch is not part of `pressedMouseButtons`.

AppKit still handles keyboard and scroll-wheel events through the responder chain. Hovering via <doc://com.apple.documentation/documentation/AppKit/NSResponder/mouseMoved(with:)> is still managed with <doc://com.apple.documentation/documentation/AppKit/NSTrackingArea>.

## Implement custom gesture recognizers

AppKit provides a number of existing gesture recognizers: <doc://com.apple.documentation/documentation/AppKit/NSClickGestureRecognizer>, <doc://com.apple.documentation/documentation/AppKit/NSPressGestureRecognizer>, <doc://com.apple.documentation/documentation/AppKit/NSPanGestureRecognizer>, <doc://com.apple.documentation/documentation/AppKit/NSMagnificationGestureRecognizer>, and <doc://com.apple.documentation/documentation/AppKit/NSRotationGestureRecognizer>. If these recognizers don’t provide the functionality you need, subclass them or create your own custom <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer> subclass. Prefer the built in recognizers when possible.

When you implement a custom `NSGestureRecognizer` subclass, keep the following guidelines in mind:

- Handle cancellation. Implement <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/mouseCancelled(with:)> and <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/touchesCancelled(with:)>, and set your state to either <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/State-swift.enum/failed> or <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/State-swift.enum/cancelled>.
- Use event processing methods only to update internal properties and state, and set your state to <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/State-swift.enum/began>, <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/State-swift.enum/changed>, or <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/State-swift.enum/ended>.
- Respond to the input from custom recognizers in action method messages.
- If you need the originating `NSEvent` or <doc://com.apple.documentation/documentation/AppKit/NSTouch> objects, cache them during event processing method callbacks and retrieve the cached objects during the action message.
- End your active gesture recognizer by transitioning to `ended`, `failed`, or `cancelled`. If you don’t, recognizers are blocked from activating.

## Filter gesture recognizer candidates

Remove inapplicable gesture recognizers during gesture gathering. Gesture recognizers handle this themselves in certain situations, but in many cases only your app knows whether a recognizer applies at the moment of mouse-down or touch-began. Use the following delegate methods, which provide the initiating event when the recognizer itself normally doesn’t:

```swift
// Only called for mouse events.
func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
    shouldAttemptToRecognizeWith event: NSEvent) -> Bool

// Only called for touch events.
func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
    shouldReceive touch: NSTouch) -> Bool
```

## Maintain compatibility with existing code

### Handle tracking loop compatibility

If you subclass an AppKit control and override any of the left-mouse responder methods, that control falls back to a tracking loop path for compatibility. For use cases that require overriding defaults in AppKit, use <doc://com.apple.documentation/documentation/AppKit/NSControl> events to make your app compatible with gesture recognizers.

For container views such as <doc://com.apple.documentation/documentation/AppKit/NSTableView> and <doc://com.apple.documentation/documentation/AppKit/NSCollectionView>, similar tracking loop fallback paths exist. For `NSTableView`, use table view delegate methods such as <doc://com.apple.documentation/documentation/AppKit/NSTableViewDelegate/tableView(_:shouldSelectRow:)>. For `NSCollectionView`, use collection view delegate methods instead of overriding responder methods.

### Update to gesture recognizer behavior

If your app depends on sequential, modal interactions that tracking loops provide, AppKit preserves that behavior and provides a way to opt out when you’re ready.

For maximum compatibility, AppKit restricts gesture activations to a single view hierarchy at a time. Unlike in iOS, the person can’t perform multiple interactions simultaneously, though scrolling is a notable exception. This more closely simulates the implicit modality of tracking loops.

You can change this behavior on a per-view basis (child views inherit the setting from their ancestors) via the <doc://com.apple.documentation/documentation/AppKit/NSView/exclusiveGestureBehavior-swift.property> property on <doc://com.apple.documentation/documentation/AppKit/NSView>. Alternatively, set the default exclusive behavior for your app via the <doc://com.apple.documentation/documentation/BundleResources/Information-Property-List/NSViewGestureRecognizerIsExclusive> application information property list entry.

## Support third-party UI frameworks

If your app embeds a third-party UI framework that doesn’t yet support native touch input, AppKit provides automatic mouse emulation to help bridge the gap.

- A tap emulates a mouse-down followed immediately by a mouse-up.
- A touch and immediate pan emulates trackpad scroll events, even if the UI doesn’t respond to them.
- A long press without movement emulates a <doc://com.apple.documentation/documentation/AppKit/NSResponder/rightMouseDown(with:)> (optionally followed by <doc://com.apple.documentation/documentation/AppKit/NSResponder/rightMouseDragged(with:)>) with a <doc://com.apple.documentation/documentation/AppKit/NSResponder/rightMouseUp(with:)> on touch lift.
- A two-finger pinch or rotation simultaneously emulates both the trackpad magnify and rotate gestures.

As you adopt a touch-native version of the framework, add  <doc://com.apple.documentation/documentation/BundleResources/Information-Property-List/NSIsTouchNative> to your application information property list to disable the extra mouse emulation.

## Explore updated APIs in macOS 27

macOS 27 adds and updates APIs for touch capabilities, handling control events, configuring scroll behavior, and working with text and dragging that you can use when migrating from tracking loops to gesture recognizers or when polishing your app’s Sidecar behavior.

### Detect touch capability

To determine whether a screen has touch capability, check the <doc://com.apple.documentation/documentation/AppKit/NSScreen/TouchCapabilities-swift.struct/multiTouch> property on <doc://com.apple.documentation/documentation/AppKit/NSScreen/TouchCapabilities-swift.struct>.

In macOS 27, this call returns `true` for all displays when a touch-capable Sidecar display is connected, not just for the Sidecar display. In most cases, instead of checking it directly, it’s better to handle events regardless of input source and decide on an alternate presentation based on the interaction type, if needed.

### Handle control events

Several new event types are available in <doc://com.apple.documentation/documentation/AppKit/NSControl/Events>:

- <doc://com.apple.documentation/documentation/AppKit/NSControl/Events/trackingRepeated>: An event when multiple `mouseDown(with:)` events with a click count greater than 1 occur.
- <doc://com.apple.documentation/documentation/AppKit/NSControl/Events/valueChanged>: An event when the value changes on continuous controls, such as sliders.
- <doc://com.apple.documentation/documentation/AppKit/NSControl/Events/primaryActionTriggered>: An event when a semantic primary action is triggered.
- <doc://com.apple.documentation/documentation/AppKit/NSControl/Events/menuActionTriggered>: An event that triggers when a menu gesture occurs, but before the menu presents.
- <doc://com.apple.documentation/documentation/AppKit/NSControl/Events/applicationReserved>: An event with a range of values, allowing your app to define custom control events.

### Configure scroll behavior

<doc://com.apple.documentation/documentation/AppKit/NSScrollView> now supports pull-to-refresh functionality. See <doc://com.apple.documentation/documentation/AppKit/NSRefreshController> for details.

The following new properties let you fine-tune scrolling behavior:

**NSScrollView**

- <doc://com.apple.documentation/documentation/AppKit/NSScrollView/isTouchScrollingEnabled>
- <doc://com.apple.documentation/documentation/AppKit/NSScrollView/minimumNumberOfTouchesForScrolling>
- <doc://com.apple.documentation/documentation/AppKit/NSScrollView/maximumNumberOfTouchesForScrolling>
- <doc://com.apple.documentation/documentation/AppKit/NSScrollView/scrollGestureForRelationships>

**NSPanGestureRecognizer**

- <doc://com.apple.documentation/documentation/AppKit/NSPanGestureRecognizer/minimumNumberOfTouches> and <doc://com.apple.documentation/documentation/AppKit/NSPanGestureRecognizer/maximumNumberOfTouches>: These two properties replace <doc://com.apple.documentation/documentation/AppKit/NSPanGestureRecognizer/numberOfTouchesRequired>. Set `maximumNumberOfTouches` to `0` to require exactly `minimumNumberOfTouches` touches; the default value for `maximumNumberOfTouches` is <doc://com.apple.documentation/documentation/ObjectiveC/NSIntegerMax>.

**NSGestureRecognizer**

- `isCancellableByScrollGesture`

### Work with text and dragging

<doc://com.apple.documentation/documentation/AppKit/NSTextSelectionManager> allows custom text engines to support standard text gestures.

<doc://com.apple.documentation/documentation/AppKit/NSDraggingSession> gains new APIs for better interoperation with gesture recognizers. Use <doc://com.apple.documentation/documentation/AppKit/NSView/beginDraggingSession(items:gesture:source:)> to start a drag from a gesture recognizer.

macOS 27 also adds gesture-based dragging support for <doc://com.apple.documentation/documentation/AppKit/NSColor> and improved dragging support in <doc://com.apple.documentation/documentation/AppKit/NSBrowser>.

### Handle deprecations and behavior changes

In apps built with the macOS 27 SDK and Xcode 27, <doc://com.apple.documentation/documentation/AppKit/NSGestureRecognizer/location(in:)> on `NSGestureRecognizer` returns <doc://com.apple.documentation/documentation/Foundation/NSZeroPoint> and logs an error if the receiver’s class doesn’t override the method. Subclasses of `NSGestureRecognizer` must implement `location(in:)` to report a meaningful location. For support with Xcode 27, see [Xcode support](https://developer.apple.com/support/xcode/).

Use <doc://com.apple.documentation/documentation/SwiftUI/GestureInputKinds> to limit gestures to specific types of input in SwiftUI.

## Related

- [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289)

## Revision history

- **2026-06-08** First published.

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)