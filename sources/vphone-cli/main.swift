import AppKit
import ArgumentParser
import Foundation

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        // Prevent SIGPIPE from killing the process when a client disconnects
        // before we finish writing a response.  EPIPE is handled via write()
        // return codes throughout the codebase — we never want the default
        // signal handler to terminate the process (and the VM with it).
        signal(SIGPIPE, SIG_IGN)
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    default:
        var runnable = command
        try runnable.run()
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
