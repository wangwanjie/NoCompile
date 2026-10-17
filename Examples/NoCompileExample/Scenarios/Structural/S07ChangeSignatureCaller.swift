//
//  S07ChangeSignatureCaller.swift
//

import Foundation

enum S07 {
    static func probe() -> String {
        return s07Compute(1) // S07-CALL
    }
}
