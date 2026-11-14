// ohmai-lidhelper: runs as root under launchd. All logic lives in OhmaiLidHelperCore;
// this file only wires it up. The helper's only effect is `pmset -a disablesleep 0|1`.

import Foundation
import OhmaiLidHelperCore
import OhmaiLidXPC

let runtime = LidRuntime(controller: LidController(sleep: PmsetSleepSetting(), power: SystemPowerReading()))

// Startup reset, always: a crash or reboot may have left sleep disabled.
runtime.start()

// Fail closed: without a valid team ID we can't check callers, so accept no one.
let info = Bundle.main.infoDictionary ?? [:]
guard let teamID = info[LidHelperXPC.teamIDInfoKey] as? String,
      let requirement = LidHelperXPC.requirement(identifier: LidHelperXPC.appBundleID, teamID: teamID)
else {
    runtime.shutdown()
    exit(0)  // clean exit, so launchd's KeepAlive doesn't respawn us
}

// launchd sends SIGTERM on unregister, shutdown and logout: turn sleep back on first.
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { runtime.shutdown() }
        exit(0)
    }
    source.resume()
    return source
}

let service = LidService(runtime: runtime, helperVersion: info["CFBundleVersion"] as? String ?? "0")
let delegate = LidListenerDelegate(service: service, requirement: requirement)
let listener = NSXPCListener(machServiceName: LidHelperXPC.machServiceName)
listener.delegate = delegate
listener.resume()

dispatchMain()
