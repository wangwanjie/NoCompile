//
//  U04CollectionViewController.swift
//  场景 U04：UICollectionView + 组合布局 + DiffableDataSource + CellRegistration 闭包
//

import UIKit

final class U04CollectionViewController: UIViewController {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)), subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
        collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), collectionViewLayout: layout)
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            content.text = "U04(@@v1@@):" + item
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collectionView, indexPath, item in
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(["x", "y"])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func firstCellText() -> String {
        collectionView.layoutIfNeeded()
        let cell = dataSource.collectionView(collectionView, cellForItemAt: IndexPath(item: 0, section: 0)) as? UICollectionViewListCell
        return (cell?.contentConfiguration as? UIListContentConfiguration)?.text ?? "no-text"
    }
}

enum U04 {
    static func probe() -> String {
        let controller = U04CollectionViewController()
        controller.loadViewIfNeeded()
        return controller.firstCellText()
    }
}
