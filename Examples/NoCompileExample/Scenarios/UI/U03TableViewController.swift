//
//  U03TableViewController.swift
//  场景 U03：UITableView + 数据源（Swift）+ 复用 framework 里的 ObjC cell（ExCardCell）
//

import UIKit
import ExKit

final class U03TableViewController: UITableViewController {
    private let rows = ["alpha", "beta"]

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(ExCardCell.self, forCellReuseIdentifier: ExCardCell.reuseIdentifier())
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ExCardCell.reuseIdentifier(), for: indexPath)
        if let card = cell as? ExCardCell {
            card.configure(withTitle: "U03(@@v1@@):" + rows[indexPath.row])
        }
        return cell
    }
}

enum U03 {
    static func probe() -> String {
        let controller = U03TableViewController(style: .plain)
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        return cell.textLabel?.text ?? "no-text"
    }
}
