import Foundation
import JavaScriptCore

final class JSEvaluator: @unchecked Sendable {
    static let shared = JSEvaluator()
    private let context = JSContext()!
    private let lock = NSLock()
    private var buffer = ""

    private init() {
        let logger: @convention(block) (String) -> Void = { [weak self] value in self?.buffer += value + "\n" }
        context.setObject(logger, forKeyedSubscript: "__vi_log" as NSString)
        context.evaluateScript("var self=this; var window=this; var globalThis=this; var console={log:function(){__vi_log(Array.prototype.slice.call(arguments).join(' '));}};")
        let atob: @convention(block) (String) -> String = { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .isoLatin1) } ?? "" }
        let btoa: @convention(block) (String) -> String = { ($0.data(using: .isoLatin1) ?? Data()).base64EncodedString() }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        let timeout: @convention(block) (JSValue, Double) -> Void = { callback, _ in callback.call(withArguments: []) }
        context.setObject(timeout, forKeyedSubscript: "setTimeout" as NSString)
    }

    func evaluate(_ source: String) -> String {
        lock.lock(); defer { lock.unlock() }
        buffer = ""; context.exception = nil; context.evaluateScript(source)
        if let exception = context.exception { return "__KERAUNOS_JS_ERROR__\(exception.toString() ?? "unknown")" }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@_cdecl("keraunos_js_eval")
func keraunos_js_eval(_ script: UnsafePointer<CChar>?, _ timeoutMilliseconds: Double) -> UnsafeMutablePointer<CChar>? {
    let source = script.map { String(cString: $0) } ?? ""
    return strdup(JSEvaluator.shared.evaluate(source))
}
