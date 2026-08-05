import Foundation
import NibCore
import Testing

@testable import NibUI

@Suite("Tabs")
struct TabsTests {

    @Test("a new model starts with exactly one tab, and it is active")
    func startsWithOneTab() {
        let model = AppModel()
        #expect(model.tabs.count == 1)
        #expect(model.session.id == model.activeTabID)
        #expect(!model.canCloseTab)
    }

    @Test("opening a tab selects it and leaves the others alone")
    func newTabIsSelected() {
        let model = AppModel()
        let first = model.session
        first.spec.url = "https://one.example"

        let second = model.newTab()

        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == second.id)
        #expect(model.session.spec.url.isEmpty)
        // Each tab is a whole session; opening one must not disturb the other's request.
        #expect(first.spec.url == "https://one.example")
    }

    @Test("tabs are independent sessions rather than views of one")
    func tabsAreIndependent() {
        let model = AppModel()
        model.session.spec.url = "https://one.example"
        model.session.spec.method = .post

        let second = model.newTab()
        second.spec.url = "https://two.example"

        #expect(model.tabs[0].spec.url == "https://one.example")
        #expect(model.tabs[0].spec.method == .post)
        #expect(model.tabs[1].spec.url == "https://two.example")
        #expect(model.tabs[1].spec.method == .get)
    }

    /// Closing the active tab should land on its neighbour, not jump to the first one — that is
    /// what every editor does and what the muscle memory expects.
    @Test("closing the active tab selects its neighbour")
    func closingSelectsNeighbour() {
        let model = AppModel()
        let first = model.session
        let second = model.newTab()
        let third = model.newTab()

        model.select(second.id)
        model.closeTab(second.id)

        #expect(model.tabs.map(\.id) == [first.id, third.id])
        #expect(model.activeTabID == third.id)
    }

    @Test("closing an inactive tab does not move the selection")
    func closingInactiveKeepsSelection() {
        let model = AppModel()
        let first = model.session
        let second = model.newTab()

        model.closeTab(first.id)

        #expect(model.activeTabID == second.id)
        #expect(model.tabs.count == 1)
    }

    /// A window with no request in it has nothing to show and no way back.
    @Test("closing the last tab opens a fresh one rather than leaving none")
    func neverEmpty() {
        let model = AppModel()
        model.closeTab(model.activeTabID)

        #expect(model.tabs.count == 1)
        #expect(model.session.spec.url.isEmpty)
        #expect(model.tabs.contains { $0.id == model.activeTabID })
    }

    @Test("selecting by position ignores a number with no tab behind it")
    func selectByPosition() {
        let model = AppModel()
        let first = model.session
        let second = model.newTab()

        model.selectTab(at: 0)
        #expect(model.activeTabID == first.id)

        model.selectTab(at: 9)
        #expect(model.activeTabID == first.id)

        model.selectTab(at: 1)
        #expect(model.activeTabID == second.id)
    }

    @Test("next and previous wrap around")
    func cyclingWraps() {
        let model = AppModel()
        let first = model.session
        let second = model.newTab()

        model.select(first.id)
        model.selectNextTab(by: -1)
        #expect(model.activeTabID == second.id)

        model.selectNextTab(by: 1)
        #expect(model.activeTabID == first.id)
    }

    @Test("cycling with one tab is a no-op rather than an error")
    func cyclingWithOneTab() {
        let model = AppModel()
        let only = model.activeTabID
        model.selectNextTab(by: 1)
        #expect(model.activeTabID == only)
    }

    /// Two tabs can legitimately hold the same saved request. A single shared "already loaded"
    /// latch would stop the second one ever loading it.
    @Test("the loaded-request latch is per tab")
    func loadedRequestIsPerTab() {
        let model = AppModel()
        let first = model.session
        first.loadedRequestID = NodeID(rawValue: "01REQUEST00000000000000000")

        let second = model.newTab()
        #expect(second.loadedRequestID == nil)
        #expect(first.loadedRequestID != nil)
    }

    @Test("saving is offered only for a tab holding a saved request")
    func savingNeedsARequest() {
        let model = AppModel()
        #expect(!model.canSaveSelectedRequest)

        model.session.loadedRequestID = NodeID(rawValue: "01REQUEST00000000000000000")
        #expect(model.canSaveSelectedRequest)
    }
}
