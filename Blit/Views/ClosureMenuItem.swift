// A menu item that runs a closure: the file lists' AppKit menus.

import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// A copy runs the same closure. (NSMenuItem's own copy calls an
    /// initializer this class doesn't have: copying a menu of these crashed.)
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = ClosureMenuItem(title, handler: handler)
        if let attributedTitle { copy.attributedTitle = attributedTitle }
        copy.isEnabled = isEnabled
        copy.isHidden = isHidden
        copy.image = image
        copy.toolTip = toolTip
        copy.state = state
        copy.tag = tag
        copy.representedObject = representedObject
        copy.indentationLevel = indentationLevel
        copy.keyEquivalent = keyEquivalent
        copy.keyEquivalentModifierMask = keyEquivalentModifierMask
        copy.submenu = submenu?.copy() as? NSMenu
        return copy
    }

    @objc private func fire() { handler() }
}
