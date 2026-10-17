//
//  S07ChangeSignatureCallee.swift
//  场景 S07：改函数签名（加参数）并同时改调用方：被调用方与调用方在两个文件里，一次保存两个文件
//

import Foundation

func s07Compute(_ value: Int) -> String { // S07-SIG
    return "S07-\(value)" // S07-BODY
}
