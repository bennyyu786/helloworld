// main.swift — macOS 原生插入层：把文本插到当前光标所在应用
// 对应 Wispr Flow Swift 助手里的 helper.paste_execute（AXValue / NSPasteboard + Cmd+V）。
//
// 用法:  dictate_insert --text "要插入的文本"
//        dictate_insert --file path.txt
//        dictate_insert --paste          # 只把文本放进剪贴板，不触发粘贴
//
// 构建:  cd insert && swift build
// 权限:  需要「系统设置 → 隐私与安全性 → 辅助功能」勾选构建出的可执行文件/终端。

import AppKit
import ApplicationServices
import Darwin

func usage() -> Never {
    FileHandle.standardError.write(Data("""
usage: dictate_insert [--text <str>] [--file <path>] [--paste]

  --text <str>  将文本插入当前光标处（先尝试 AXValue，失败回退剪贴板+Cmd+V）
  --file <path> 从文件读取文本后插入
  --paste       仅写入剪贴板，不发送粘贴按键
""".utf8))
    exit(1)
}

// 找当前前台 App 的 AXFocusedUIElement（即能接收文本的控件）
func focusedElement(_ app: AXUIElement) -> AXUIElement? {
    var el: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &el)
    guard err == .success, let e = el else { return nil }
    return (e as! AXUIElement)
}

// 方案 A：直接设置 AXValue（最精确，光标处生效）
func setAXValue(of element: AXUIElement, to text: String) -> Bool {
    let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
    return err == .success
}

// 方案 B：写剪贴板 + 发送 Cmd+V（回退），并保存/恢复原剪贴板
func pasteViaClipboard(_ text: String) {
    let pb = NSPasteboard.general
    let saved = NSPasteboardItem()
    let oldString = pb.string(forType: .string)
    if let old = oldString { saved.setString(old, forType: .string) }

    pb.clearContents()
    pb.setString(text, forType: .string)

    let src = CGEventSource(stateID: .hidSystemState)
    let v: CGKeyCode = 9 // 'V'
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    down?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    up?.flags = .maskCommand
    up?.post(tap: .cghidEventTap)

    usleep(200_000) // 给目标应用时间读取剪贴板
    // 恢复剪贴板
    pb.clearContents()
    if let old = oldString { pb.setString(old, forType: .string) }
}

func insert(_ text: String) {
    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("""
error: 未获得「辅助功能」权限。
  请打开 系统设置 → 隐私与安全性 → 辅助功能，勾选本程序（或运行它的终端）。
""".utf8))
        exit(2)
    }
    let app = AXUIElementCreateApplication(NSWorkspace.shared.frontmostApplication!.processIdentifier)
    guard let el = focusedElement(app) else {
        FileHandle.standardError.write(Data("error: 无法定位当前焦点控件\n".utf8))
        exit(3)
    }
    if setAXValue(of: el, to: text) {
        print("inserted via AXValue")
    } else {
        print("AXValue failed; falling back to clipboard paste")
        pasteViaClipboard(text)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var text: String?
var onlyPaste = false
var i = 0
while i < args.count {
    switch args[i] {
    case "--text": i += 1; text = args[i]
    case "--file": i += 1; text = try? String(contentsOfFile: args[i], encoding: .utf8)
    case "--paste": onlyPaste = true
    default: usage()
    }
    i += 1
}
guard let out = text, !out.isEmpty else { usage() }

if onlyPaste {
    let pb = NSPasteboard.general
    pb.clearContents(); pb.setString(out, forType: .string)
    print("copied to pasteboard")
} else {
    insert(out)
}
