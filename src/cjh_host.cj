// cjh web 托管：只管**生命周期**（发现 → 健康检查 → 按需 spawn → 退出收尾），
// 数据面零参与——聊天走 ws 插件（ws://127.0.0.1:8765/ws），其余 REST 走 http 插件。
//
// 真实屏「迟早整页冻结」曾误判为 fork 所致（做过零 fork + run.sh 守护的改造）；后经
// gdb 全线程栈 + /proc 信号掩码取证定案：根因是 WebKit 的 JSC 覆盖 SIGUSR1 处理器
// （仓颉运行时线程挂起/恢复所用的信号），已在 cj-tauri 框架层修复（issue #4，桥里
// 保存/恢复信号处理器）。进程模型回归 **SubProcess 直管**：两平台同一实现，cjh 随包
// 自动拉起、退出只收自己 spawn 的那一只——单二进制 + vendor 目录即可分发，无需启动脚本。
//
// 与 ai-chat 示例的**有意差异**：那边让用户选 cjh 可执行文件路径（引导卡里点「选择…」），
// 这里把 cjh 按平台打进 vendor/cjh/bin/<平台>/ 随包分发——笔记应用的用户不该知道
// 「cjh 是什么、装在哪、怎么配环境变量」。发现顺序：
//   CJNOTE_CJH 环境变量（开发调试 / 打包后换版本）→ vendor 打包布局 → 早期解包目录。
//
// 环境变量：
//   CJNOTE_CJH       —— 覆写 cjh 可执行文件路径（可选）
//   CJNOTE_CJH_PORT  —— 覆写端口（默认 8765，与 cjh web 默认一致）

package cjnote

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import cjTauri.*
import stdx.encoding.json.*
import stdx.net.http.*

public let CJH_DEFAULT_PORT: Int64 = 8765

/** 子进程句柄与归属记账（不做并发保护——AGENTS §2：不给「不会发生的并发」上锁） */
public var gCjhProc: Option<SubProcess> = None
/** true = cjh 是本应用 spawn 的（退出时要收尾）；false = 用户自己的实例（别动人家的） */
public var gCjhOwned: Bool = false

func cjhPort(): Int64 {
    if (let Some(v) <- getVariable("CJNOTE_CJH_PORT")) {
        return parsePortEnv(v, CJH_DEFAULT_PORT)
    }
    return CJH_DEFAULT_PORT
}

func parsePortEnv(v: String, fallback: Int64): Int64 {
    try {
        let n = Int64.parse(v)
        if (n > 0 && n <= 65535) {
            return n
        }
    } catch (e: Exception) {
        let _ = e
    }
    return fallback
}

/** cjh web 是否已在目标端口活着：GET /api/health 收到 200 即认为就绪 */
public func cjhHealthy(port: Int64): Bool {
    let client = ClientBuilder()
        .readTimeout(Duration.second * 1)
        .writeTimeout(Duration.second * 1)
        .build()
    var ok = false
    try {
        let req = HttpRequestBuilder().get().url("http://127.0.0.1:${port}/api/health").build()
        let resp = client.send(req)
        ok = Int64(resp.status) == 200
        resp.close()
    } catch (e: Exception) {
        let _ = e
    }
    client.close()
    return ok
}

/** cjh 可执行文件候选路径：环境变量优先，其次是打包布局，最后兼容早期解包目录 */
func cjhBinCandidates(): ArrayList<String> {
    let list = ArrayList<String>()
    if (let Some(p) <- getVariable("CJNOTE_CJH")) {
        if (p.size > 0) {
            list.add(p)
        }
    }
    list.add("vendor/cjh/bin/linux-x64/cjh")
    list.add("vendor/cjh/bin/windows-x64/cjh.exe")
    list.add("vendor/cjh/.extract/cjh-v1.5.1-linux-x64")
    list.add("vendor/cjh/.extract/cjh-v1.5.1-windows-x64.exe")
    return list
}

/** 找随包 cjh：第一个存在且可读的候选。只回布尔式的值、不留 stderr——
 *  调用方（status / ensure）各自给得出更贴情境的一行提示 */
func findCjhBin(): Option<String> {
    for (p in cjhBinCandidates()) {
        if (fileReadable(p)) {
            return Some(p)
        }
    }
    return None
}

/** 这个路径能不能打开（不存在 / 没权限都算不行） */
func fileReadable(p: String): Bool {
    try {
        let f = File(Path(p), OpenMode.Read)
        f.close()
        return true
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

/** 可用端点的统一形状：页面拿到就能自己接上 */
func putEndpoints(obj: JsonObject, port: Int64): Unit {
    obj.put("port", JsonInt(port))
    obj.put("apiUrl", JsonString("http://127.0.0.1:${port}"))
    obj.put("wsUrl", JsonString("ws://127.0.0.1:${port}/ws"))
}

/**
 * cjh 当前状态（`cjh:status` 命令的正文）：三态 + 可用时的端点。**纯读、无副作用**
 * （不 spawn、不 kill），页面可以随便轮询。
 *
 *   running    —— 端口上有活的 cjh（本应用拉起的或用户自己的），直接可用
 *   configured —— 找得到随包二进制但健康检查不通：可原地拉起
 *   missing    —— 没有可用二进制且端口没活：只能如实显示不可用
 */
public func cjhStatusJson(): JsonValue {
    let port = cjhPort()
    let obj = JsonObject()
    obj.put("port", JsonInt(port))
    if (cjhHealthy(port)) {
        obj.put("state", JsonString("running"))
        putEndpoints(obj, port)
        obj.put("owned", JsonBool(gCjhOwned))
        return obj
    }
    match (findCjhBin()) {
        case Some(p) =>
            obj.put("state", JsonString("configured"))
            obj.put("binPath", JsonString(p))
        case None => obj.put("state", JsonString("missing"))
    }
    return obj
}

/**
 * 按指定路径拉起 cjh web 并等健康检查（100ms 一步，最多 10 秒——cjh web 启动要装 Agent 栈，
 * 秒级是正常量级）。阻塞只落在命令 worker 线程上，不冻窗口。
 *
 * 两平台同一实现（SubProcess 直管）。铁律：用户自己的 cjh 实例（端口上已有的活实例）
 * 永远不会被顶掉——拉起前只收**我们 spawn 的**那一只（换路径重试时旧进程若还占着端口，
 * 新的那只绑定就会失败，而表象只是「10 秒后仍不通」）。
 *
 * 显式 `--bind 127.0.0.1`：cjh web 默认绑 0.0.0.0 且默认不带鉴权 token，跟着默认走等于把
 * 「能读写工作区、能跑 shell」的整套 API 摆到局域网上；本应用的消费面全在本机。
 */
func ensureCjhUp(bin: String): Bool {
    stopOwnedCjh()
    var proc: SubProcess
    try {
        proc = launch(bin, ["web", "--port", cjhPort().toString(), "--bind", "127.0.0.1"])
    } catch (e: Exception) {
        eprintln("[cjnote] 启动 cjh web 失败：${e}")
        return false
    }
    gCjhProc = Some(proc)
    let port = cjhPort()
    var waited: Int64 = 0
    while (waited < 10000) {
        if (cjhHealthy(port)) {
            gCjhOwned = true
            eprintln("[cjnote] cjh web 已就绪（port=${port}，等了 ${waited}ms）")
            return true
        }
        if (!proc.isAlive()) {
            eprintln("[cjnote] cjh web 进程退出（exit=${proc.wait()}）——检查 vendor/cjh 二进制")
            gCjhProc = None
            return false
        }
        sleep(Duration.millisecond * 100)
        waited += 100
    }
    eprintln("[cjnote] cjh web 启动后 10s 健康检查仍不通——按不可用处理")
    gCjhOwned = true
    return false
}

/** 收掉**我们 spawn 的**那只 cjh（复用的不动——那是用户自己的实例） */
func stopOwnedCjh(): Unit {
    if (let Some(p) <- gCjhProc) {
        if (p.isAlive()) {
            eprintln("[cjnote] 收尾：终止 cjh web")
            p.terminate()
            // 给 200ms 走完收尾再 wait，避免僵尸
            sleep(Duration.millisecond * 200)
            let _ = p.wait()
        }
        gCjhProc = None
    }
}

/** 重启**我们 spawn 的**那只 cjh（调用前已确认 gCjhOwned） */
func restartOwnedCjh(): Bool {
    match (findCjhBin()) {
        case Some(bin) => return ensureCjhUp(bin)
        case None =>
            eprintln("[cjnote] 未找到随包 cjh（vendor/cjh/bin/）")
            return false
    }
}

/** 应用退出时收尾：只终止**自己 spawn 的** cjh（复用的不动——那是用户自己的实例） */
public func shutdownCjh(): Unit {
    if (!gCjhOwned) {
        return
    }
    stopOwnedCjh()
}

/**
 * `cjh:status` / `cjh:start` 两条应用命令：把「cjh 在不在、能不能起」交给页面问。
 *
 * 为什么不放插件里：这两条管的是**本应用自己 spawn 的进程**（句柄就在本文件的两个全局里），
 * 没有跨应用复用价值；插件包是要给别的应用当依赖的，把 cjnote 的进程策略塞进去等于
 * 把应用逻辑倒灌进框架（AGENTS §2 的依赖方向）。
 */
// ── 配置读写：直接操作 ~/.cjh 下的两份 JSON ──
// 为什么不走 cjh 的 /api/settings（实测 2026-10-19，端口上跑的 1.3.0 实例 + vendor 1.5.1）：
// 那条 POST 是**按字段白名单**的部分更新——baseUrl / model / temperature / maxTokens 能写，
// 但接入协议 provider_protocol 传进去静默忽略（GET 也不回显该字段）。而 cjh 的配置是两份：
//   settings.json：base_url / model / provider_protocol / temperature / max_tokens / max_iterations …
//   auth.json    ：api_key / openai_api_key / deepseek_api_key …
// 而且「修改后重启 cjh 生效」（配置里自己写的）。所以要让设置页改的东西真的生效，
// 唯一可靠路径是：宿主写文件 → 重启 cjh。页面没有 fs 权限碰 ~/.cjh，得由宿主代劳。

/** cjh 配置目录：CJH_HOME 覆写 → HOME/.cjh → USERPROFILE/.cjh（Windows） */
func cjhConfigDir(): String {
    if (let Some(v) <- getVariable("CJH_HOME")) {
        if (v != "") {
            return v
        }
    }
    if (let Some(h) <- getVariable("HOME")) {
        if (h != "") {
            return "${h}/.cjh"
        }
    }
    if (let Some(h) <- getVariable("USERPROFILE")) {
        if (h != "") {
            return "${h}/.cjh"
        }
    }
    return ".cjh"
}

/** 读一个 JSON 对象文件；不存在 / 读不动 / 不是对象 → 空对象（调用方当「没有这项配置」） */
func readJsonObjectOr(path: String): JsonObject {
    let empty = JsonObject()
    try {
        let text = String.fromUtf8(File.readFrom(path))
        let v = JsonValue.fromStr(text)
        match (v.kind()) {
            case JsonKind.JsObject => return v.asObject()
            case _ => return empty
        }
    } catch (e: Exception) {
        let _ = e
        return empty
    }
}

func jsonStrOf(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

func jsonIntOf(obj: JsonObject, key: String): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return 0
            }
        case None => return 0
    }
}

func jsonFloatOf(obj: JsonObject, key: String): Float64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsFloat => return v.asFloat().getValue()
                case JsonKind.JsInt => return Float64(v.asInt().getValue())
                case _ => return 0.0
            }
        case None => return 0.0
    }
}

/** 密钥脱敏：只回「像不像填过」，绝不把明文丢给页面 */
func maskSecret(k: String): String {
    if (k == "") {
        return ""
    }
    if (k.size <= 8) {
        return "********"
    }
    return "${k[0..5]}****${k[k.size - 4..k.size]}"
}

func cjhApiKey(): String {
    let auth = readJsonObjectOr("${cjhConfigDir()}/auth.json")
    let k = jsonStrOf(auth, "api_key")
    if (k != "") {
        return k
    }
    return jsonStrOf(auth, "openai_api_key")
}

/** `cjh:config`：当前配置（密钥脱敏 + hasKey，页面只用来回填表单） */
public func cjhConfigJson(): JsonValue {
    let dir = cjhConfigDir()
    let s = readJsonObjectOr("${dir}/settings.json")
    let key = cjhApiKey()
    let obj = JsonObject()
    obj.put("ok", JsonBool(true))
    obj.put("home", JsonString(dir))
    obj.put("settingsPath", JsonString("${dir}/settings.json"))
    obj.put("authPath", JsonString("${dir}/auth.json"))
    obj.put("baseUrl", JsonString(jsonStrOf(s, "base_url")))
    obj.put("model", JsonString(jsonStrOf(s, "model")))
    let proto = jsonStrOf(s, "provider_protocol")
    obj.put("protocol", JsonString(if (proto == "") { "openai" } else { proto }))
    obj.put("temperature", JsonFloat(jsonFloatOf(s, "temperature")))
    obj.put("maxTokens", JsonInt(jsonIntOf(s, "max_tokens")))
    obj.put("maxIterations", JsonInt(jsonIntOf(s, "max_iterations")))
    obj.put("apiKey", JsonString(maskSecret(key)))
    obj.put("hasKey", JsonBool(key != ""))
    return obj
}

/** 写一个 JSON 对象文件（目录不在就建），失败只记 stderr 不抛——保存失败要让页面看得见原因 */
func writeJsonObject(path: String, obj: JsonObject): Bool {
    try {
        File.writeTo(path, obj.toJsonString().toArray())
        return true
    } catch (e: Exception) {
        eprintln("[cjnote] 写配置失败 ${path}：${e}")
        return false
    }
}

/**
 * `cjh:saveConfig`：把设置页的字段合并写进两份配置，回 `{ok, wrote:[...], needsRestart}`。
 *
 * 合并而非覆盖：cjh 的 settings.json 里有 _说明、models、capability、mcp_servers 等一大片
 * 本页不管的字段，覆盖写等于把它们全抹掉。所以先读原对象、只 put 我们管的键。
 * 空串=「不改」（页面留空代表保持原值；密钥框留空就是不动 key）。
 */
public func saveCjhConfig(args: JsonObject): JsonValue {
    let dir = cjhConfigDir()
    let settingsPath = "${dir}/settings.json"
    let authPath = "${dir}/auth.json"
    let s = readJsonObjectOr(settingsPath)
    let auth = readJsonObjectOr(authPath)
    let wrote = ArrayList<String>()

    let baseUrl = jsonStrOf(args, "baseUrl")
    if (baseUrl != "") {
        s.put("base_url", JsonString(baseUrl))
        wrote.add("base_url")
    }
    let model = jsonStrOf(args, "model")
    if (model != "") {
        s.put("model", JsonString(model))
        wrote.add("model")
    }
    let proto = jsonStrOf(args, "protocol")
    if (proto != "") {
        s.put("provider_protocol", JsonString(proto))
        wrote.add("provider_protocol")
    }
    match (args.get("temperature")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsFloat => s.put("temperature", JsonFloat(v.asFloat().getValue())); wrote.add("temperature")
                case JsonKind.JsInt => s.put("temperature", JsonFloat(Float64(v.asInt().getValue()))); wrote.add("temperature")
                case _ => ()
            }
        case None => ()
    }
    match (args.get("maxTokens")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt =>
                    if (v.asInt().getValue() > 0) {
                        s.put("max_tokens", JsonInt(v.asInt().getValue()))
                        wrote.add("max_tokens")
                    }
                case _ => ()
            }
        case None => ()
    }
    match (args.get("maxIterations")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt =>
                    if (v.asInt().getValue() > 0) {
                        s.put("max_iterations", JsonInt(v.asInt().getValue()))
                        wrote.add("max_iterations")
                    }
                case _ => ()
            }
        case None => ()
    }

    let obj = JsonObject()
    var ok = writeJsonObject(settingsPath, s)
    // 密钥单独一份（auth.json）：只有用户真输了新 key 才写。带 **** 的是脱敏回显，写回去等于把 key 弄坏
    let newKey = jsonStrOf(args, "apiKey")
    if (newKey != "" && !newKey.contains("****")) {
        auth.put("api_key", JsonString(newKey))
        if (!writeJsonObject(authPath, auth)) {
            ok = false
        } else {
            wrote.add("api_key")
        }
    }
    obj.put("ok", JsonBool(ok))
    let arr = JsonArray()
    for (w in wrote) {
        arr.add(JsonString(w))
    }
    obj.put("wrote", arr)
    obj.put("needsRestart", JsonBool(wrote.size > 0))
    obj.put("settingsPath", JsonString(settingsPath))
    obj.put("authPath", JsonString(authPath))
    return obj
}

/**
 * `cjh:restart`：让新配置生效——重启**本应用 spawn 的**那只 cjh。
 * 端口上是别人的实例时不动它（gCjhOwned=false），只回「需手动重启」这一事实。
 */
public func restartCjhWeb(): JsonValue {
    let port = cjhPort()
    let obj = JsonObject()
    if (!gCjhOwned) {
        let alive = cjhHealthy(port)
        obj.put("ok", JsonBool(false))
        obj.put("needsManualRestart", JsonBool(true))
        obj.put("error", JsonString(if (alive) {
            "端口 ${port} 上是本应用之外启动的 cjh；配置已写盘，重启那个实例后生效"
        } else {
            "cjh 当前未运行；配置已写盘，下次拉起时生效"
        }))
        return obj
    }
    let started = restartOwnedCjh()
    obj.put("ok", JsonBool(started))
    obj.put("needsManualRestart", JsonBool(false))
    obj.put("port", JsonInt(port))
    obj.put("apiUrl", JsonString("http://127.0.0.1:${port}"))
    obj.put("wsUrl", JsonString("ws://127.0.0.1:${port}/ws"))
    if (!started) {
        obj.put("error", JsonString("重启 cjh 失败：10 秒内健康检查不通，细节见应用日志"))
    }
    return obj
}

/**
 * `cjh:status` / `cjh:start` / `cjh:config` / `cjh:saveConfig` / `cjh:restart` 五条应用命令：
 * 把「cjh 在不在、能不能起、配置是什么、能不能改」交给页面问。
 *
 * 为什么不放插件里：这几条管的是**本应用 spawn 的进程**（句柄在本文件的两个全局里）
 * 与**这台机器上 cjh 的配置文件**，没有跨应用复用价值；插件包是要给别的应用当依赖的，
 * 把 cjnote 的进程与配置策略塞进去等于把应用逻辑倒灌进框架（AGENTS §2 的依赖方向）。
 */
public class CjhCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "cjh:status" => cjhStatusJson()
            case "cjh:start" => this.startCjh(args)
            case "cjh:config" => cjhConfigJson()
            case "cjh:saveConfig" => saveCjhConfig(args)
            case "cjh:restart" => restartCjhWeb()
            case _ => throw CommandException("unknown cjh command: ${cmd}")
        }
    }

    /**
     * 拉起 cjh，回 `{ok, port, apiUrl, wsUrl}`；失败回 `{ok:false, error}`
     * ——失败原因是要显示给人看的一行话，**不抛异常**（抛出去前端只剩一句 reject 文本）。
     *
     * 参数 `path` 可选：不给就用随包二进制（正常路径）；给了用于开发调试换版本。
     */
    private func startCjh(args: JsonObject): JsonValue {
        let port = cjhPort()
        let obj = JsonObject()
        // 端口上已经活着就直接复用：用户自己的实例不许被顶掉（gCjhOwned 保持 false）
        if (cjhHealthy(port)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(true))
            putEndpoints(obj, port)
            return obj
        }
        var bin = stringArgOr(args, "path", "")
        if (bin.size == 0) {
            match (findCjhBin()) {
                case Some(p) => bin = p
                case None => bin = ""
            }
        }
        if (bin.size == 0) {
            obj.put("ok", JsonBool(false))
            obj.put("error", JsonString("找不到随包 cjh（vendor/cjh/bin/）"))
            return obj
        }
        if (!fileReadable(bin)) {
            obj.put("ok", JsonBool(false))
            obj.put("error", JsonString("打不开这个文件：${bin}（不存在或没有读权限）"))
            return obj
        }
        if (ensureCjhUp(bin)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(false))
            putEndpoints(obj, port)
            return obj
        }
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("cjh 没在 10 秒内就绪，启动错误见应用日志"))
        return obj
    }

    /** 取字符串参数：缺失或类型不符都退回默认值（调用方自己判空，给出更贴业务的话） */
    private func stringArgOr(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
            case None => return fallback
        }
    }
}
