//
//  SafariWebExtensionHandler.swift
//  Viaduct Install Extension
//
//  Created by Yehonatan Cohen on 23/6/26.
//

import SafariServices

@objc(SafariWebExtensionHandler)
public class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    // Mirrors InstallProgressBridge in the main app. The appex is sandboxed and
    // request-scoped, so a distributed-notification round-trip is the channel:
    // post a request, wait briefly for the app's JSON state reply.
    private static let requestNote = Notification.Name("com.magicelk235.viaduct.progress.request")
    private static let stateNote = Notification.Name("com.magicelk235.viaduct.progress.state")

    public func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard message?["type"] as? String == "progress" else {
            respond(context, ["state": "unknown"])
            return
        }

        let center = DistributedNotificationCenter.default()
        let lock = NSLock()
        var finished = false
        var observer: NSObjectProtocol?
        let finish: ([String: Any]) -> Void = { [weak self] payload in
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            guard first else { return }
            if let observer { center.removeObserver(observer) }
            self?.respond(context, payload)
        }

        observer = center.addObserver(forName: Self.stateNote, object: nil, queue: nil) { note in
            guard let json = note.object as? String,
                  let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            finish(dict)
        }
        center.postNotificationName(Self.requestNote, object: nil, userInfo: nil,
                                    deliverImmediately: true)
        // App not running / not listening → tell the page instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            finish(["state": "unreachable"])
        }
    }

    private func respond(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
