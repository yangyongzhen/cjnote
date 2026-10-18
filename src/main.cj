// cjnote：本地优先的 AI 笔记（M1 骨架）
// 三栏布局：左笔记列表 / 中 CodeMirror 编辑器 / 右 AI 侧栏（占位，M3 接 AI 通路）
//
// 页面是独立 ui/index.html（不内联三引号字符串）：Markdown 渲染必然有正则与反斜杠，
// 内联会踩 AGENTS §4 的三引号转义坑；独立文件还能 node --check 验语法。
// run(html) 的页面没有真实来源，vendor 库在装配期读盘内联进占位符（markdown-notes 同款）。

package cjnote

import cjTauri.*
import cjTauri.plugins.store.*
import cjTauri.plugins.http.*
import cjTauri.plugins.log.*
import cjTauri.plugins.clipboard.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/** 前端自检/日志回投：页面每条断言打一行 stderr，取证 grep 这一个前缀 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/** notes:env：宿主侧启动参数交给页面（页面没有进程环境） */
public class NotesEnvCommand <: CommandHandler {
    private let selfCheck: Bool

    public init(selfCheck: Bool) {
        this.selfCheck = selfCheck
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let out = JsonObject()
        out.put("selfcheck", JsonBool(this.selfCheck))
        out.put("workspace", JsonString("notes"))
        return out
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

/** 读一份文本文件，读不到返回空串（调用方打 stderr，不致命） */
func readTextOr(path: String, hint: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        eprintln("[cjnote] 缺 ${path}（${hint}）：${e}")
        return ""
    }
}

/** 把 vendor 库内联进页面占位符：run(html) 无真实来源，`<script src>` 相对路径取不到。
 *  库缺失不致命——渲染退化为纯文本也不该启动失败，每份只留一行 stderr。 */
func inlineVendor(html: String): String {
    var js = readTextOr("ui/vendor/marked.min.js", "渲染退化为纯文本") + "\n"
    js += readTextOr("ui/vendor/highlight.min.js", "代码无高亮") + "\n"
    js += readTextOr("ui/vendor/codemirror.min.js", "编辑器退化为纯 textarea") + "\n"
    var out = html.replace("/*__VENDOR_JS__*/", js)
    let cmCss = readTextOr("ui/vendor/codemirror.min.css", "编辑器无样式")
    let hlCss = readTextOr("ui/vendor/github-dark.min.css", "高亮无配色")
    out = out.replace("/*__VENDOR_CSS__*/", cmCss + "\n" + hlCss)
    return out
}

main(): Int64 {
    var selfCheck = false
    if (let Some(v) <- getVariable("CJNOTE_SELFCHECK")) {
        if (v == "1") {
            selfCheck = true
        }
    }

    let htmlRaw = readTextOr("ui/index.html", "请在工程根目录启动")
    if (htmlRaw.size == 0) {
        return 1
    }
    let html = inlineVendor(htmlRaw)

    eprintln("[cjnote] main start (selfcheck=${selfCheck})")

    // 笔记存取（M2 自研，替代 fs 插件）：路径全部由 NoteStore 内部拼，页面只传文件名
    let noteCmds = NoteCommands(NoteStore("notes"))

    let app = TauriApp()
        .window(WindowConfig("cjnote — AI 笔记", 1280, 800))
        .plugin(StorePlugin())
        .plugin(HttpPlugin())
        .plugin(LogPlugin())
        .plugin(ClipboardPlugin())
        .register("report", ReportCommand())
        .register("notes:env", NotesEnvCommand(selfCheck))
        .register("note:list", noteCmds)
        .register("note:open", noteCmds)
        .register("note:save", noteCmds)
        .register("note:create", noteCmds)
        .register("note:delete", noteCmds)

    // 工作区在装配期建好 + 播种欢迎笔记（幂等：目录/文件已存在不重建）。
    // 建目录是应用装配的事，不进 fs 插件命令面（markdown-notes 同款）。
    if (!exists("notes")) {
        try {
            Directory.create("notes", recursive: true)
            eprintln("[cjnote] 工作区 notes/ 不存在，已创建")
        } catch (e: Exception) {
            eprintln("[cjnote] 创建工作区 notes/ 失败（列表会空）：${e}")
        }
    }
    if (!exists("notes/欢迎.md")) {
        let welcome: String = "# 欢迎，来到 cjnote\n\n本地优先的 AI 笔记：笔记是磁盘上的纯 .md 文件，AI 长在编辑工作流里。\n\n这是你的第一篇笔记，改改看：\n\n- **粗体**、*斜体*、`行内码`\n- 中间编辑，右侧预览实时渲染\n- 右侧栏是 AI（M3 接通）\n\n```cangjie\nprintln(\"你好，仓颉\")\n```\n"
        try {
            File.writeTo("notes/欢迎.md", welcome.toArray())
            eprintln("[cjnote] 已播种欢迎笔记 notes/欢迎.md")
        } catch (e: Exception) {
            eprintln("[cjnote] 播种欢迎笔记失败（不影响使用）：${e}")
        }
    }

    // 探针模式（CJNOTE_PROBE_AI=1）：注入 mock 端点配置，前端自检追加一条 AI 流式探针
    // （ai-chat 的 CJ_AICHAT_PROBE 同款：无人值守验证管道，真机配置仍走设置面板/store）
    if (let Some(v) <- getVariable("CJNOTE_PROBE_AI")) {
        if (v == "1") {
            let base = envOr("CJNOTE_MOCK_URL", "http://127.0.0.1:18923/chat/completions")
            let js = "window.__CJNOTE_AI_CFG__ = {base: '" + base + "', key: 'probe', model: 'mock'};\n"
            match (app.hostOf("main")) {
                case Some(host) =>
                    host.addInitScript(js)
                    eprintln("[cjnote] AI 探针配置已注入（${base}）")
                case None => eprintln("[cjnote] AI 探针：主窗未登记，配置没注入")
            }
        }
    }

    app.run(html)
    eprintln("[cjnote] after run")
    return 0
}
