import Darwin
import Foundation

// vphone-launchpad-cli: drives a running vphone-launchpad over its control
// socket. It holds no state and no privileges of its own: the app installs
// bundles through its helper, runs the active bundle's vphone-cli, and shows
// every command in its window. Output lines go to stderr as they arrive; the
// result, a JSON document, goes to stdout. The exit status is 0 on success.

// MARK: - Arguments

func usage() -> String {
    var text = """
    usage: vphone-launchpad-cli <command> [arguments] [options]

    Drives a running vphone-launchpad, starting it if needed. Progress goes to
    stderr; the result is JSON on stdout.

    """
    for command in VPhoneLaunchpadControlCommand.all {
        text += "\n  \(command.usage)\n      \(command.summary)\n"
    }
    return text
}

func fail(_ message: String, detail: String? = nil) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    if let detail, !detail.isEmpty {
        FileHandle.standardError.write(Data("\(detail)\n".utf8))
    }
    exit(1)
}

func parse(_ words: [String]) -> VPhoneLaunchpadControlRequest {
    // Two words name a grouped command ("vm start"), one word the others.
    var rest = words
    var command: VPhoneLaunchpadControlCommand?
    if rest.count >= 2, let grouped = VPhoneLaunchpadControlCommand.named("\(rest[0]).\(rest[1])") {
        command = grouped
        rest.removeFirst(2)
    } else if let single = VPhoneLaunchpadControlCommand.named(rest[0]) {
        command = single
        rest.removeFirst()
    }
    guard let command else {
        let group = VPhoneLaunchpadControlCommand.all.filter { $0.name.hasPrefix("\(words[0]).") }
        if !group.isEmpty {
            fail("\(words[0]) needs a command.", detail: group.map { "  \($0.usage)" }.joined(separator: "\n"))
        }
        fail("unknown command \(words.prefix(2).joined(separator: " ")). Run vphone-launchpad-cli help.")
    }
    var request = VPhoneLaunchpadControlRequest(command: command.name)
    // exec hands everything after it to vphone-cli untouched.
    if command.name == "exec" {
        request.arguments = rest
        return request
    }

    var positional: [String] = []
    var index = 0
    while index < rest.count {
        let word = rest[index]
        index += 1
        if word == "--" {
            positional += rest[index...]
            break
        }
        guard word.hasPrefix("--"), word.count > 2 else {
            positional.append(word)
            continue
        }
        var name = String(word.dropFirst(2))
        var value: String?
        if let equals = name.firstIndex(of: "=") {
            value = String(name[name.index(after: equals)...])
            name = String(name[..<equals])
        }
        if command.flags.contains(name), value == nil {
            request.options[name] = "true"
        } else if command.options.contains(name) {
            if value == nil, index < rest.count {
                value = rest[index]
                index += 1
            }
            guard let value else {
                fail("--\(name) needs a value.")
            }
            request.options[name] = value
        } else {
            fail("unknown option --\(name).", detail: "usage: vphone-launchpad-cli \(command.usage)")
        }
    }

    // A trailing `...` argument may be empty.
    let named = command.takesRest ? command.arguments.count - 1 : command.arguments.count
    guard positional.count >= named, command.takesRest || positional.count == named else {
        fail("wrong number of arguments.", detail: "usage: vphone-launchpad-cli \(command.usage)")
    }
    // The app runs elsewhere; a relative path means nothing to it.
    if command.name == "bundle.install-local" {
        positional[0] = URL(fileURLWithPath: positional[0]).standardizedFileURL.path
    }
    if let root = request.options["root"] {
        request.options["root"] = URL(fileURLWithPath: root).standardizedFileURL.path
    }
    request.arguments = positional
    return request
}

// MARK: - Connection

func connectControl() -> Int32? {
    var address = sockaddr_un()
    guard VPhoneLaunchpadControl.address(VPhoneLaunchpadControl.socketPath, into: &address) else {
        fail("the control socket path is too long: \(VPhoneLaunchpadControl.socketPath)")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return nil
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    return fd
}

/// Opens the Launchpad this tool ships in, in the background, else the one
/// Launch Services knows, and waits for its socket.
func launchAndConnect() -> Int32 {
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let app = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = app?.pathExtension == "app" ? ["-g", app!.path] : ["-g", "-b", "com.vphone.launchpad"]
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    FileHandle.standardError.write(Data("starting vphone-launchpad…\n".utf8))
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("unable to start vphone-launchpad.", detail: error.localizedDescription)
    }
    for _ in 0 ..< 120 {
        if let fd = connectControl() {
            return fd
        }
        usleep(250_000)
    }
    fail("vphone-launchpad did not open its control socket.", detail: VPhoneLaunchpadControl.socketPath)
}

// MARK: - Main

let words = Array(CommandLine.arguments.dropFirst())
if words.isEmpty || ["help", "-h", "--help"].contains(words[0]) {
    print(usage(), terminator: "")
    exit(words.isEmpty ? 1 : 0)
}
let request = parse(words)
let fd = connectControl() ?? launchAndConnect()

guard var line = try? JSONEncoder().encode(request) else {
    fail("unable to encode the request.")
}
line.append(0x0A)
guard VPhoneLaunchpadControl.write(line, to: fd) else {
    fail("vphone-launchpad closed the connection.")
}

// Interrupting this process closes the socket, which cancels the command in
// the app where the command can be cancelled.
var splitter = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count < 0, errno == EINTR {
        continue
    }
    guard count > 0 else {
        break
    }
    splitter.append(contentsOf: buffer[0 ..< count])
    while let newline = splitter.firstIndex(of: 0x0A) {
        let data = splitter[splitter.startIndex ..< newline]
        splitter.removeSubrange(splitter.startIndex ... newline)
        guard let event = try? JSONDecoder().decode(VPhoneLaunchpadControlEvent.self, from: data) else {
            continue
        }
        if let output = event.output {
            FileHandle.standardError.write(Data("\(output)\n".utf8))
        }
        guard event.done == true else {
            continue
        }
        guard event.ok == true else {
            fail(event.error ?? "the command failed.", detail: event.detail)
        }
        print(event.result ?? "null")
        exit(0)
    }
}
fail("vphone-launchpad closed the connection before the command finished.")
