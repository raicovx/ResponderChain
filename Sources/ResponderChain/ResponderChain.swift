//
//  ResponderChain.swift
//
//  Created by Casper Zandbergen on 30/11/2020.
//  https://twitter.com/amzdme
//

import Foundation
import Combine
import SwiftUI
import AmzdIntrospect

// MARK: Platform specifics

@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
typealias ResponderPublisher = AnyPublisher<PlatformResponder?, Never>

#if os(macOS)
import Cocoa
public typealias PlatformWindow = NSWindow
@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
public typealias PlatformIntrospectionView = AppKitIntrospectionView
typealias PlatformResponder = NSResponder
var canBecomeFirstResponder = \PlatformView.canBecomeKeyView

extension NSWindow {
    @available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
    var firstResponderPublisher: ResponderPublisher {
        publisher(for: \.firstResponder).eraseToAnyPublisher()
    }
}

#elseif os(iOS) || os(tvOS)
public typealias PlatformWindow = UIWindow
@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
public typealias PlatformIntrospectionView = UIKitIntrospectionView
typealias PlatformResponder = UIResponder
var canBecomeFirstResponder = \PlatformView.canBecomeFirstResponder

extension UIView {
    @available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
    var firstResponderPublisher: ResponderPublisher {
        Self._firstResponderPublisher.eraseToAnyPublisher()
    }
    
    // I assume that resignFirstResponder is always called before an object is meant to be released.
    // If that is not the case then having a CurrentValueSubject instead of PassthroughSubject will
    // cause the firstResponder to be retained until a new firstResponder is set.
    @available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
    private static let _firstResponderPublisher = CurrentValueSubject<PlatformResponder?, Never>(nil)
    
    open override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if #available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *) {
            Self._firstResponderPublisher.send(self)
        }
        return result
    }
    
    open override func resignFirstResponder() -> Bool {
        if #available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *) {
            Self._firstResponderPublisher.send(nil)
        }
        return super.resignFirstResponder()
    }
}
#endif

// MARK: View Extension

@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
extension View {
    /// Tag the closest sibling view that can become first responder
    public func responderTag<Tag: Hashable>(_ tag: Tag) -> some View {
        inject(FindResponderSibling(tag: tag))
    }
    
    /// This attaches the ResponderChain for the current window as environmentObject
    ///
    /// Will not show anything for the first frame as it introspects the closest view to get the window
    ///
    /// Use `.environmentObject(ResponderChain(forWindow: window))` if possible.
    public func withResponderChainForCurrentWindow() -> some View {
        self.modifier(ResponderChainWindowFinder())
    }
}

// MARK: ResponderChain

@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
public class ResponderChain: ObservableObject {
    @Published public var firstResponder: AnyHashable? {
        didSet {
            if shouldUpdateUI { updateUIForNewFirstResponder(oldValue: oldValue) }
        }
    }
    
    public var availableResponders: [AnyHashable] {
        taggedResponders.filter { $0.value[keyPath: canBecomeFirstResponder] } .map(\.key)
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var window: PlatformWindow
    private var shouldUpdateUI: Bool = true
    internal var taggedResponders: [AnyHashable: PlatformView] = [:]
    
    public init(forWindow window: PlatformWindow) {
        self.window = window
        window.firstResponderPublisher.sink(receiveValue: { [self] responder in
            let tag = responderTag(for: responder)
            setFirstResponderWithoutUpdatingUI(tag)
        }).store(in: &cancellables)
    }
    
    internal func responderTag(for responder: PlatformResponder?) -> AnyHashable? {
        guard let view = responder as? PlatformView else {
            return nil
        }
        
        let possibleResponders = taggedResponders.filter {
            $0.value == view || view.isDescendant(of: $0.value)
        }

        let respondersByDistance: [AnyHashable: Int] = possibleResponders.mapValues {
            var distance = 0
            var responder: PlatformView? = $0
            while let step = responder, view.isDescendant(of: step) {
                responder = step.subviews.first(where: view.isDescendant(of:))
                distance += 1
            }
            return distance
        }
        
        return respondersByDistance.min(by: { $0.value < $1.value })?.key
    }
    
    internal func setFirstResponderWithoutUpdatingUI(_ newFirstResponder: AnyHashable?) {
        shouldUpdateUI = false
        firstResponder = newFirstResponder
        shouldUpdateUI = true
    }
    
    internal func updateUIForNewFirstResponder(oldValue: AnyHashable?) {
        assert(Thread.isMainThread && shouldUpdateUI)
        if let tag = firstResponder, tag != oldValue {
            if let responder = taggedResponders[tag] {
                print("Making first responder:", tag, responder)
                #if os(macOS)
                    let succeeded = window.makeFirstResponder(responder)
                #elseif os(iOS) || os(tvOS)
                    let succeeded = responder.becomeFirstResponder()
                #endif
                if !succeeded {
                    firstResponder = nil
                    print("Failed to make \(tag) first responder")
                }
                return distance
            } else {
                print("Can't find responder for tag \(tag), make sure to set a tag using `.responderTag(_:)`")
                firstResponder = nil
            }

            firstResponder = respondersByDistance.min(by: { $0.value < $1.value })?.key
        }).store(in: &cancellables)
        } else if firstResponder == nil {
            #if os(macOS)
                let previousResponder = oldValue.flatMap { taggedResponders[$0] }
                window.endEditing(for: previousResponder)
            #elseif os(iOS) || os(tvOS)
                window.endEditing(true)
            #endif
        }
    }
}

@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
private struct ResponderChainWindowFinder: ViewModifier {
    @State private var window: PlatformWindow? = nil

    func body(content: Content) -> some View {
        Group {
            if let window = window {
                content.environmentObject(ResponderChain(forWindow: window))
            } else {
                EmptyView()
            }
        }.introspect(selector: { $0.self }) {
            self.window = $0.window
        }
    }
}

// MARK: - Tag

@available(iOS 13.0, OSX 10.15, tvOS 13.0, watchOS 6.0, *)
private struct FindResponderSibling<Tag: Hashable>: View {
    @EnvironmentObject var responderChain: ResponderChain
    
    var tag: Tag
    
    var body: some View {
        PlatformIntrospectionView(
            selector: { introspectionView in
                guard
                    let viewHost = Introspect.findViewHost(from: introspectionView),
                    let superview = viewHost.superview,
                    let entryIndex = superview.subviews.firstIndex(of: viewHost),
                    entryIndex > 0
                else {
                    return nil
                }
                
                func findResponder(in root: PlatformView) -> PlatformView? {
                    for subview in root.subviews {
                        if subview[keyPath: canBecomeFirstResponder] {
                            return subview
                        } else if let responder = findResponder(in: subview) {
                            return responder
                        }
                    }
                    return nil
                }
                
                for subview in superview.subviews[0..<entryIndex].reversed() {
                    if subview[keyPath: canBecomeFirstResponder] {
                        return subview
                    } else if let responder = findResponder(in: subview) {
                        return responder
                    }
                }
                
                return nil
            },
            customize: { responder in
                responderChain.taggedResponders[tag] = responder
            }
        )
    }
}
