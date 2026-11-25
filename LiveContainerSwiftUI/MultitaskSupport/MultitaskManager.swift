//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import Foundation

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers: [String: UUID] = [:]
    
    @objc class func registerMultitaskContainer(container: String, request: UUID) {
        usingMultitaskContainers[container] = request
    }
    
    @objc class func unregisterMultitaskContainer(container: String, request: UUID) {
        if usingMultitaskContainers[container] == request { usingMultitaskContainers.removeValue(forKey: container) }
    }
    
    @objc class func isUsing(container: String) -> Bool {
        return usingMultitaskContainers[container] != nil
    }
    
    @objc class func isMultitasking() -> Bool {
        return usingMultitaskContainers.count > 0
    }
}
