import Foundation

/// 有界且可跨執行緒使用的 LRU；查詢、更新與淘汰均不掃描整份快取。
final class BoundedLRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let lock = NSLock()
    private let capacity: Int
    private var nodes: [Key: Node] = [:]
    private var oldest: Node?
    private var newest: Node?

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[key] else { return nil }
        touch(node)
        return node.value
    }

    func store(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let node = nodes[key] {
            node.value = value
            touch(node)
            return
        }
        if nodes.count == capacity, let node = oldest {
            unlink(node)
            nodes.removeValue(forKey: node.key)
        }
        let node = Node(key: key, value: value)
        nodes[key] = node
        append(node)
    }

    private func touch(_ node: Node) {
        guard newest !== node else { return }
        unlink(node)
        append(node)
    }

    private func unlink(_ node: Node) {
        if let previous = node.previous {
            previous.next = node.next
        } else {
            oldest = node.next
        }
        if let next = node.next {
            next.previous = node.previous
        } else {
            newest = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    private func append(_ node: Node) {
        node.previous = newest
        newest?.next = node
        newest = node
        if oldest == nil { oldest = node }
    }
}
