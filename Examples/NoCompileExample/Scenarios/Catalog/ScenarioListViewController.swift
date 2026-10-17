//
//  ScenarioListViewController.swift
//  场景清单页：按分组列出全部场景及其当前输出，每秒刷新。人工验证时在这里观察改动是否生效
//

import UIKit

final class ScenarioListViewController: UITableViewController {
    private let groups: [(name: String, scenarios: [Scenario])]
    private var values: [String: String] = [:]
    private var refreshTimer: Timer?

    init() {
        var order: [String] = []
        var buckets: [String: [Scenario]] = [:]
        for scenario in ScenarioCatalog.all {
            if buckets[scenario.group] == nil {
                order.append(scenario.group)
            }
            buckets[scenario.group, default: []].append(scenario)
        }
        groups = order.map { ($0, buckets[$0] ?? []) }
        super.init(style: .insetGrouped)
        title = "场景清单（\(ScenarioCatalog.all.count)）"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        values = ProbeWriter.snapshot()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return groups.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return groups[section].name
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups[section].scenarios.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let scenario = groups[indexPath.section].scenarios[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "\(scenario.id)  \(scenario.title)"
        content.textProperties.font = .systemFont(ofSize: 14, weight: .medium)
        content.secondaryText = values[scenario.id] ?? "-"
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
