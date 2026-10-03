import Foundation

@main
enum CacheSmoke {
    private final class Payload {}

    static func main() {
        let cache = BoundedLRUCache<String, [Int]>(capacity: 2)
        cache.store([], for: "a")
        cache.store([2], for: "b")
        precondition(cache.value(for: "a") == [], "空結果仍須視為命中")
        cache.store([3], for: "c")
        precondition(cache.value(for: "b") == nil, "淘汰最久未使用的項目")
        cache.store([4], for: "a")
        cache.store([5], for: "d")
        precondition(cache.value(for: "c") == nil && cache.value(for: "a") == [4], "更新需刷新順位")

        var single: BoundedLRUCache<Int, Payload>? = BoundedLRUCache(capacity: 1)
        weak var evicted: Payload?
        weak var retained: Payload?
        do {
            let first = Payload()
            evicted = first
            single?.store(first, for: 1)
            let second = Payload()
            retained = second
            single?.store(second, for: 2)
        }
        precondition(evicted == nil && retained != nil, "淘汰應釋放資料")
        single = nil
        precondition(retained == nil, "單項快取釋放後不可保留資料")

        var linked: BoundedLRUCache<Int, Payload>? = BoundedLRUCache(capacity: 2)
        weak var firstLinked: Payload?
        weak var lastLinked: Payload?
        do {
            let first = Payload()
            let last = Payload()
            firstLinked = first
            lastLinked = last
            linked?.store(first, for: 1)
            linked?.store(last, for: 2)
        }
        linked = nil
        precondition(firstLinked == nil && lastLinked == nil, "雙向鏈結不可形成循環參照")

        let concurrent = BoundedLRUCache<Int, Int>(capacity: 32)
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            concurrent.store(index, for: index)
            _ = concurrent.value(for: index)
        }
        let survivors = (0..<2_000).filter { concurrent.value(for: $0) != nil }
        precondition(survivors.count == 32, "並行操作後仍遵守容量上限")
        print("LRU Smoke：空結果、淘汰、更新、記憶體釋放與並行操作全部通過。")
    }
}
