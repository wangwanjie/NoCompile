//
//  M04ListViewModelSubclass.swift
//  场景 M04：App 里的类继承 framework 里的泛型 open class 并重写方法
//

import Foundation
import ExKit

final class M04SongListViewModel: ExListViewModel<String> {
    override func title(for item: String) -> String {
        return "M04(@@v1@@):\(item)"
    }
}

enum M04 {
    static func probe() -> String {
        let viewModel = M04SongListViewModel()
        viewModel.append("a")
        viewModel.append("b")
        // summary() 在 framework 里实现，内部调用被重写的 title(for:)
        let base = ExListViewModel<Int>()
        base.append(1)
        return viewModel.summary() + " | base=" + base.summary()
    }
}
