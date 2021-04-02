//
/*
Copyright 2021 Splunk Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Foundation
import UIKit
import OpenTelemetryApi
import OpenTelemetrySdk

extension UIApplication {
    // FIXME will probably need to grow a config feature to silence chatty actions
    // FIXME really only a reasonable solution for storyboard apps/components and not swiftui ones
    @objc open func swizzled_sendAction(_ action: Selector,
                                        to target: Any?,
                                        from sender: Any?,
                                        for event: UIEvent?) -> Bool {
        updateUIFields()
        let tracer = buildTracer()
        let span = tracer.spanBuilder(spanName: action.description).startSpan()
        var scope = tracer.setActive(span)
        defer {
            scope.close()
            span.end()
        }
        if target != nil {
            span.setAttribute(key: "target.type", value: String(describing: type(of: target!)))
        }
        if sender != nil {
            span.setAttribute(key: "sender.type", value: String(describing: type(of: sender!)))
        }
        if event != nil {
            span.setAttribute(key: "event.type", value: String(describing: type(of: event!)))
        }
        return swizzled_sendAction(action, to: target, from: sender, for: event)
    }
}

// FIXME dredge out all these debug logging
extension UIViewController {
    @objc open func swizzled_loadView() {
        print("SWIZZLED LOADVIEW "+String(describing: type(of: self)))
        self.swizzled_loadView()
    }
    @objc open func swizzled_viewDidLoad() {
        updateUIFields()
        print("SWIZZLED VIEWDIDLOAD "+String(describing: type(of: self)))
        self.swizzled_viewDidLoad()
    }
    @objc open func swizzled_viewWillAppear(_ animated: Bool) {
        print("SWIZZLED VIEWWILLAPPEAR "+String(describing: type(of: self)))
        self.swizzled_viewWillAppear(animated)
    }
    @objc open func swizzled_viewDidAppear(_ animated: Bool) {
        updateUIFields()
        print("SWIZZLED VIEWDIDAPPEAR "+String(describing: type(of: self)))
        self.swizzled_viewDidAppear(animated)
    }
    @objc open func swizzled_viewWillDisappear(_ animated: Bool) {
        print("SWIZZLED VIEWWILLDISAPPEAR "+String(describing: type(of: self)))
        self.swizzled_viewWillDisappear(animated)
    }
    @objc open func swizzled_viewDidDisappear(_ animated: Bool) {
        updateUIFields()
        print("SWIZZLED VIEWDIDDISAPPEAR "+String(describing: type(of: self)))
        self.swizzled_viewDidDisappear(animated)
    }

}

let Presentation2Span = NSMapTable<NSObject, SpanHolder>(keyOptions: NSPointerFunctions.Options.weakMemory, valueOptions: NSPointerFunctions.Options.strongMemory)

class SpanHolder: NSObject {
    let span: Span
    init(_ span: Span) {
        self.span = span
    }
}

func initializePresentationTransitionInstrumentation() {
    let begin = Notification.Name(rawValue: "UIPresentationControllerPresentationTransitionWillBeginNotification")
    let end = Notification.Name(rawValue: "UIPresentationControllerPresentationTransitionDidEndNotification")

    _ = NotificationCenter.default.addObserver(forName: begin, object: nil, queue: nil) { (notif) in
        let notifObj = notif.object as? NSObject
        if notifObj != nil {
            let span = buildTracer().spanBuilder(spanName: "PresentationTransition").startSpan()
            // FIXME better naming
            span.setAttribute(key: "object.type", value: String(describing: type(of: notif.object!)))
            Presentation2Span.setObject(SpanHolder(span), forKey: notifObj)
        }

    }
    _ = NotificationCenter.default.addObserver(forName: end, object: nil, queue: nil) { (notif) in
        updateUIFields()
        let notifObj = notif.object as? NSObject
        if notifObj != nil {
            let spanHolder = Presentation2Span.object(forKey: notifObj)
            if spanHolder != nil {
                // screenName may have changed now that the view has appeared; update new screen name
                spanHolder?.span.setAttribute(key: "screen.name", value: screenName)
                spanHolder?.span.end()
            }
        }
    }
}

func addUIFields(span: ReadableSpan) {
    updateUIFields()
    // Note that this may be called from threads other than main (e.g., background thread
    // creating span); hence trying to update cached values whenever we can and simply using
    // them here
    span.setAttribute(key: "screen.name", value: screenName)
}

private var screenName: String = "unknown"

private func pickVC(_ vc: UIViewController?) -> UIViewController? {
    if vc == nil {
        return nil
    }
    if vc!.presentedViewController != nil {
        return pickVC(vc!.presentedViewController)
    }
    if let tabVC = vc as? UITabBarController {
        if tabVC.selectedViewController != nil {
            return pickVC(tabVC.selectedViewController)
        }
    }
    return vc
}

private func updateUIFields() {
    if !Thread.current.isMainThread {
        return
    }
    let wins = UIApplication.shared.windows
    print(wins)
    if !wins.isEmpty {
        // windows are arranged in z-order, with topmost (e.g. popover) being the last in array
        let vc = pickVC(wins[wins.count-1].rootViewController)
        if vc != nil {
            // FIXME SwiftUI UIHostingController vc when cast has a "rootView" var which does
            // not appear to be accessible generically
            screenName = String(describing: type(of: vc!))
        }
    }
    // FIXME others?
}

func initalizeUIInstrumentation() {
    initializePresentationTransitionInstrumentation()
    _ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { (_: Notification) in
        // print("NC "+using.debugDescription)
    }
    swizzle(clazz: UIApplication.self, orig: #selector(UIApplication.sendAction(_:to:from:for:)), swizzled: #selector(UIApplication.swizzled_sendAction(_:to:from:for:)))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.loadView), swizzled: #selector(UIViewController.swizzled_loadView))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.viewDidLoad), swizzled: #selector(UIViewController.swizzled_viewDidLoad))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.viewWillAppear(_:)), swizzled: #selector(UIViewController.swizzled_viewWillAppear(_:)))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.viewDidAppear(_:)), swizzled: #selector(UIViewController.swizzled_viewDidAppear(_:)))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.viewWillDisappear(_:)), swizzled: #selector(UIViewController.swizzled_viewWillDisappear(_:)))
    swizzle(clazz: UIViewController.self, orig: #selector(UIViewController.viewDidDisappear(_:)), swizzled: #selector(UIViewController.swizzled_viewDidDisappear(_:)))

}
