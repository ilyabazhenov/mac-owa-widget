@testable import OWAWidget
import XCTest

/// Mail kept out of the popover: the window stays, the popover's strip and inbox panel go.
@MainActor
final class MailPopoverModeTests: XCTestCase {
    private func makeService(popover: Bool) async -> (MailService, FakeMailProvider, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "popover-mode-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.popoverSectionEnabled = popover
        settings.save(to: defaults)
        PopoverInboxPanelStore.setShown(true, in: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("person")])
        let backend = FakeMailBackend(provider: provider)
        return (MailService(backend: backend, defaults: defaults), provider, backend)
    }

    func testPopoverSectionFollowsTheSwitch() async {
        let (on, _, onBackend) = await makeService(popover: true)
        let (off, _, offBackend) = await makeService(popover: false)
        _ = (onBackend, offBackend)
        XCTAssertTrue(on.showsPopoverSection)
        XCTAssertFalse(off.showsPopoverSection, "no strip and no inbox panel")
        XCTAssertTrue(off.isAvailable, "the mail window still opens")
    }

    func testPanelIsNotKeptFreshWhileMailIsOutOfThePopover() async {
        let (service, provider, backend) = await makeService(popover: false)
        _ = backend
        // The panel was open before the user turned the popover mail off.
        await service.refreshPanelList()
        await provider.setUnread(2)
        await service.checkInbox()
        var lists = await provider.calls.filter { $0.hasPrefix("conversations:") }
        XCTAssertEqual(lists, ["conversations:All"], "new mail fetches neither the panel nor the unread list")

        service.updateSettings { $0.popoverSectionEnabled = true }
        await provider.setUnread(3)
        await service.checkInbox()
        lists = await provider.calls.filter { $0.hasPrefix("conversations:All") }
        XCTAssertEqual(lists.count, 2, "back in the popover, the panel follows new mail again")
    }
}
