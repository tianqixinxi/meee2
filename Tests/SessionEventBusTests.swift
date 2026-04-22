import XCTest
import Combine
@testable import meee2Kit

final class SessionEventBusTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// 订阅 bus，send 一个事件，订阅者必须在超时前收到对应事件。
    func testSubscribeReceivesPublishedEvent() {
        let exp = expectation(description: "bus delivers event")
        let uniq = "sid-evtbus-\(UUID().uuidString.lowercased())"

        SessionEventBus.shared.publisher
            .sink { event in
                if case .sessionMetadataChanged(let sid) = event, sid == uniq {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        SessionEventBus.shared.publish(.sessionMetadataChanged(sessionId: uniq))

        wait(for: [exp], timeout: 1.0)
    }

    /// 可发布 channel/message 变体并被订阅者观察到。
    func testChannelAndMessageEventVariants() {
        let expCh = expectation(description: "channel event")
        let expMsg = expectation(description: "message event")

        let chName = "bus-chan-\(UUID().uuidString.lowercased().prefix(6))"
        let msgId = "m-\(UUID().uuidString.lowercased().prefix(8))"

        SessionEventBus.shared.publisher
            .sink { event in
                switch event {
                case .channelMutated(let name) where name == chName:
                    expCh.fulfill()
                case .messageMutated(let id, let channel) where id == msgId && channel == chName:
                    expMsg.fulfill()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        SessionEventBus.shared.publish(.channelMutated(name: chName))
        SessionEventBus.shared.publish(.messageMutated(id: msgId, channel: chName))

        wait(for: [expCh, expMsg], timeout: 1.0)
    }
}
