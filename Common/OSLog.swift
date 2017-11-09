//
//  OSLog.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import os.log


extension OSLog {
    convenience init(category: String) {
        self.init(subsystem: "com.ps2.rileylink", category: category)
    }

    func debug(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .debug, args)
    }

    func info(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .info, args)
    }

    func error(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .error, args)
    }

    private func log(_ message: StaticString, type: OSLogType, _ args: CVarArg...) {
        os_log(message, log: self, type: type, args)
    }
}
