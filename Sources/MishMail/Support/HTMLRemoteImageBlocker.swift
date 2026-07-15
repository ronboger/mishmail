import Foundation
import WebKit

/// Network-level privacy guard for HTML mail.
///
/// CSP remains useful defense in depth, but full-document email markup is
/// untrusted and intentionally tolerant/malformed HTML is difficult to rewrite
/// perfectly. Under Ask policy, this WebKit content rule is installed *before*
/// loading the message so HTTPS images stay blocked even if CSP head injection
/// lands somewhere the HTML parser treats as inert.
enum HTMLRemoteImageBlocker {
    static let identifier = "dev.ronboger.MishMail.block-remote-html-images.v1"

    /// Gmail remote content is HTTPS-only in MishMail's CSP. Restrict the rule
    /// to image resources so links and the synthetic about:blank document are
    /// unaffected; data:/cid: images remain available.
    static let encodedRules = """
    [{"trigger":{"url-filter":"^https://","resource-type":["image"]},"action":{"type":"block"}}]
    """

    private static var cachedRuleList: WKContentRuleList?
    private static var compiling = false
    private static var waiters: [(WKContentRuleList?) -> Void] = []

    /// Resolve the compiled rule list, coalescing concurrent message loads.
    /// Completion is always delivered on the main queue.
    static func ruleList(completion: @escaping (WKContentRuleList?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let cachedRuleList {
            completion(cachedRuleList)
            return
        }
        waiters.append(completion)
        guard !compiling else { return }
        compiling = true

        guard let store = WKContentRuleListStore.default() else {
            finish(with: nil)
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            DispatchQueue.main.async {
                if let list {
                    finish(with: list)
                    return
                }
                store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encodedRules
                ) { compiled, _ in
                    DispatchQueue.main.async { finish(with: compiled) }
                }
            }
        }
    }

    private static func finish(with list: WKContentRuleList?) {
        dispatchPrecondition(condition: .onQueue(.main))
        cachedRuleList = list
        compiling = false
        let callbacks = waiters
        waiters.removeAll()
        callbacks.forEach { $0(list) }
    }
}
