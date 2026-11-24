// Drives a debug build of Ferret Menu (DebugHooks.swift): swift scripts/drive.swift 'show:search' 'query:drill' …
// Each argument is one command, sent a second apart. See the app's log for what came back:
// log stream --predicate 'subsystem == "us.digitalempire.ferret.menu"'
import Foundation

let center = DistributedNotificationCenter.default()
for command in CommandLine.arguments.dropFirst() {
    if command.hasPrefix("wait:"), let seconds = Double(command.dropFirst(5)) {
        Thread.sleep(forTimeInterval: seconds)
        continue
    }
    center.postNotificationName(.init("us.digitalempire.ferret.menu.debug"), object: command, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 1)
}
