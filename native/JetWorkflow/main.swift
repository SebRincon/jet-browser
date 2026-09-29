import Foundation
import JavaScriptCore

// Isolated JavaScript API for one workflow run (fresh JSContext; no OS, file, network, or browser globals).
// This is not an OS sandbox and not a JIT exploit boundary. The parent enforces the wall timeout and kills the process.

final class Gate { var n = 0; var id = 0; var err: String? }

func clip(_ s: String, _ n: Int) -> String {
    let u = s.utf8
    if u.count <= n { return s }
    return String(decoding: u.prefix(n), as: UTF8.self)
}

func out(_ o: Any) {
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write(Data([10]))
    fflush(stdout)
}

func fail(_ m: String) -> Never {
    out(["type": "error", "error": clip(m, 500)])
    exit(1)
}

func stdinLine(_ cap: Int) -> String? {
    var d = Data()
    while true {
        let c = FileHandle.standardInput.readData(ofLength: 1)
        if c.isEmpty { return nil }
        if c[0] == 10 { break }
        if d.count >= cap { return nil }
        d.append(c)
    }
    return String(data: d, encoding: .utf8)
}

func box(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), d.count <= 200_000,
          let s = String(data: d, encoding: .utf8) else { return "{\"error\":\"bad rpc\"}" }
    return s
}

let gate = Gate()
let rpc: @convention(block) (String, String) -> String = { method, args in
    if gate.n >= 1000 { return "{\"error\":\"call limit\"}" }
    gate.n += 1
    guard method.range(of: "^[a-z_.]{1,60}$", options: .regularExpression) != nil,
          args.utf8.count <= 32_000, let raw = args.data(using: .utf8),
          let argsJSON = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) else {
        return "{\"error\":\"bad call\"}"
    }
    gate.id += 1
    let id = gate.id
    out(["type": "call", "id": id, "method": method, "args": argsJSON])
    guard let line = stdinLine(200_000), let ld = line.data(using: .utf8),
          let resp = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
          let num = resp["id"] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
          num.intValue == id, Double(num.intValue) == num.doubleValue else {
        return "{\"error\":\"bad response\"}"
    }
    if resp.keys.contains("error") {
        guard let es = resp["error"] as? String else { return "{\"error\":\"bad response\"}" }
        return box(["error": clip(es, 500)])
    }
    guard resp.keys.contains("result") else { return "{\"error\":\"bad response\"}" }
    return box(["result": resp["result"] ?? NSNull()])
}

// --check compiles the source the way a run wraps it, without executing any of it, so a
// reviewer can fix syntax before spending a run. Reports the source line of the error.
var checkProblem: (String, Int)? = nil
if CommandLine.arguments.dropFirst().first == "--check" {
    guard let line = stdinLine(200_000), let ld = line.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any],
          let source = root["source"] as? String, source.utf8.count <= 32_000 else { fail("bad input") }
    let check = JSContext()!
    check.exceptionHandler = { _, e in
        let message = e?.objectForKeyedSubscript("message")?.toString() ?? "syntax error"
        let line = Int(e?.objectForKeyedSubscript("line")?.toInt32() ?? 0)
        checkProblem = (clip(message, 500), line)
    }
    check.setObject(source, forKeyedSubscript: "__jetSource" as NSString)
    _ = check.evaluateScript("new Function('jet', '\"use strict\";\\n' + __jetSource)")
    if let (message, line) = checkProblem {
        // new Function adds "function anonymous(jet" and ") {" lines; the strict line adds one.
        out(["type": "check", "ok": false, "error": message, "line": max(1, line - 3)])
    } else {
        out(["type": "check", "ok": true])
    }
    exit(0)
}

guard let line = stdinLine(200_000), let ld = line.data(using: .utf8),
      let root = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any],
      let source = root["source"] as? String, source.utf8.count <= 32_000,
      root.keys.contains("input"),
      let packed = try? JSONSerialization.data(withJSONObject: ["v": root["input"] ?? NSNull()]),
      let inputPack = String(data: packed, encoding: .utf8) else { fail("bad input") }

let ctx = JSContext()!
ctx.exceptionHandler = { c, e in
    gate.err = clip(e?.objectForKeyedSubscript("message")?.toString() ?? "script error", 500)
    c?.exception = nil
}
_ = ctx.evaluateScript("""
["console","require","process","document","fetch","XMLHttpRequest","WebSocket","Deno","Bun"]
.forEach(function(k){try{delete globalThis[k]}catch(e){}});
""")
ctx.setObject(rpc, forKeyedSubscript: "__jetHost" as NSString)
ctx.setObject(inputPack, forKeyedSubscript: "__jetIn" as NSString)
_ = ctx.evaluateScript("""
(function(host,packed){
var input=JSON.parse(packed).v;
var jet=Object.freeze({input:input,call:function(method,args){
var raw=host(String(method),JSON.stringify(args===undefined?null:args));
var msg=JSON.parse(raw);
if(Object.prototype.hasOwnProperty.call(msg,"error"))throw new Error(String(msg.error).slice(0,500));
return msg.result;}});
Object.defineProperty(globalThis,"jet",{value:jet,writable:false,configurable:false});
})(__jetHost,__jetIn);
delete globalThis.__jetHost;delete globalThis.__jetIn;
""")
if let e = gate.err { fail(e) }
let body = "(function(jet){\"use strict\";\n" + source + "\n})(jet)\n//# sourceURL=jet-workflow.js\n"
let value = ctx.evaluateScript(body, withSourceURL: URL(string: "file://jet-workflow.js")!)
if let e = gate.err { fail(e) }
if value == nil { fail("script error") }
ctx.setObject(value, forKeyedSubscript: "__jetRet" as NSString)
let encoded = ctx.evaluateScript("""
(function(v){if(v===undefined)return "null";var s=JSON.stringify(v);return typeof s==="string"?s:"null";})(__jetRet)
""")
_ = ctx.evaluateScript("delete globalThis.__jetRet")
if let e = gate.err { fail(e) }
guard let text = encoded?.toString(), text.utf8.count <= 200_000, let td = text.data(using: .utf8),
      let result = try? JSONSerialization.jsonObject(with: td, options: [.fragmentsAllowed]) else {
    fail("bad result")
}
out(["type": "done", "result": result])
