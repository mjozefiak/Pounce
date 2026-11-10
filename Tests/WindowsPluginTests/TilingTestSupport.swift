import CoreGraphics
import LintelKit

@testable import WindowsPlugin

/// Short builders for tiling trees: `win(1)` is window number 1 of pid 100.
func win(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

func leaf(_ number: UInt32, _ weight: Double = 1) -> TilingChild {
    TilingChild(weight: weight, node: .window(win(number)))
}

func box(_ orientation: TilingOrientation, _ weight: Double = 1, _ children: [TilingChild]) -> TilingChild {
    TilingChild(weight: weight, node: .container(TilingContainer(orientation: orientation, children: children)))
}

func box(_ orientation: TilingOrientation, _ children: [TilingChild]) -> TilingChild {
    box(orientation, 1, children)
}

func tree(_ orientation: TilingOrientation, _ children: [TilingChild]) -> TilingTree {
    TilingTree(root: TilingContainer(orientation: orientation, children: children))
}

/// The windows of a tree in layout order, as numbers.
func numbers(_ tree: TilingTree) -> [UInt32] { tree.windows.map(\.number) }

let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
