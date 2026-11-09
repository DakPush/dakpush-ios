import UIKit
import XCTest

@testable import DakPush

/// In-app messages in a real app: windows in the app's scene, the layouts'
/// sizes against the dashboard preview's, right to left, dark mode, Dynamic
/// Type, VoiceOver, the keyboard, and the presenter end to end.
///
/// With TEST_RUNNER_DAK_SNAPSHOTS=/some/folder, each layout is also saved
/// there as a PNG (and attached to the test result) to look at.
@MainActor
final class InAppHostedTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var presenters: [InAppPresenter] = []
    private var controllers: [InAppController] = []

    override func setUp() async throws {
        // The example's own messages (if it has any cached) stay away.
        Dak.pauseInApp(true)
    }

    override func tearDown() async throws {
        for p in presenters { p.stop() }
        for c in controllers { c.dispose() }
        for w in windows { w.isHidden = true }
        presenters = []
        controllers = []
        windows = []
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private var scene: UIWindowScene {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes[0]
    }

    private var appWindow: UIWindow { InAppPresenter.appWindow(in: scene)! }

    private func message(_ layout: String, _ content: [String: Any], id: String = "m1") -> InAppMessage {
        InAppMessage.parse(JSON(any: ["id": id, "layout": layout, "content": content, "frequency": ["type": "once"]]))!
    }

    private static let buttons: [[String: Any]] = [
        ["id": "join", "text": "Start", "action": ["type": "deep_link", "url": "amarpartner://challenge/travel"]],
        ["id": "later", "text": "Later", "action": ["type": "dismiss"]],
    ]

    /// A picture to stand in for the message's image.
    private func picture(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
    }

    /// Draws [m] in a window of its own in the app's scene, laid out, without
    /// the animation.
    private func show(
        _ m: InAppMessage, image: UIImage? = nil, style: UIUserInterfaceStyle = .light,
        size: UIContentSizeCategory? = nil, rtl: Bool = false, keyboard: CGRect? = nil
    ) -> InAppViewController {
        let window = InAppWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.overrideUserInterfaceStyle = style
        if #available(iOS 17.0, *) {
            if let size { window.traitOverrides.preferredContentSizeCategory = size }
            if rtl { window.traitOverrides.layoutDirection = .rightToLeft }
        }
        let vc = InAppViewController(message: m, image: image, theme: DakInAppTheme(), appTop: nil)
        vc.keyboardFrame = keyboard
        window.passThrough = m.layout.isBanner
        window.rootViewController = vc
        window.isHidden = false
        window.layoutIfNeeded()
        vc.view.layoutIfNeeded()
        windows.append(window)
        return vc
    }

    private func view(_ id: String, in vc: InAppViewController) -> UIView? {
        func find(_ v: UIView) -> UIView? {
            if v.accessibilityIdentifier == id { return v }
            for s in v.subviews { if let hit = find(s) { return hit } }
            return nil
        }
        return find(vc.view)
    }

    /// [id]'s frame in the window.
    private func frame(_ id: String, in vc: InAppViewController, file: StaticString = #filePath, line: UInt = #line)
        -> CGRect
    {
        guard let v = view(id, in: vc) else {
            XCTFail("no \(id)", file: file, line: line)
            return .zero
        }
        return v.convert(v.bounds, to: nil)
    }

    private func inWindow(_ v: UIView?) -> CGRect {
        guard let v else { return .zero }
        return v.convert(v.bounds, to: nil)
    }

    /// The app with the message over it, as a PNG.
    private func snapshot(_ name: String, _ vc: InAppViewController) {
        guard let window = vc.view.window else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            appWindow.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["DAK_SNAPSHOTS"], !dir.isEmpty, let png = image.pngData() {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: - Layouts

    func testTheModalHasThePreviewsSizes() throws {
        let vc = show(
            message(
                "modal",
                [
                    "title": "New speaking challenge!", "body": "Today's topic: travel. Talk for 5 minutes.",
                    "buttons": Self.buttons,
                ]))
        snapshot("modal", vc)
        let window = try XCTUnwrap(vc.view.window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let sheet = frame("dak-in-app-sheet", in: vc)
        XCTAssertEqual(sheet.width, min(400, safe.width - 48), accuracy: 0.5)
        XCTAssertEqual(sheet.midX, safe.midX, accuracy: 0.5)
        XCTAssertEqual(sheet.midY, safe.midY, accuracy: 0.5, "centred")
        XCTAssertEqual(view("dak-in-app-sheet", in: vc)?.layer.cornerRadius, 20)
        XCTAssertEqual(frame("dak-in-app-title", in: vc).minY - sheet.minY, 36, accuracy: 0.5)
        let title = frame("dak-in-app-title", in: vc)
        let body = frame("dak-in-app-body", in: vc)
        XCTAssertEqual(title.minX - sheet.minX, 20, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(body.minY - title.maxY, 8 - 0.5)
        let start = frame("dak-in-app-button-join", in: vc)
        let later = frame("dak-in-app-button-later", in: vc)
        XCTAssertEqual(start.height, 40, accuracy: 0.5)
        XCTAssertEqual(start.minY, later.minY, "side by side")
        XCTAssertEqual(later.minX - start.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(start.width, later.width, accuracy: 0.5)
        XCTAssertEqual(start.minY - body.maxY, 20, accuracy: 1)
        XCTAssertEqual(sheet.maxY - start.maxY, 16, accuracy: 0.5)
        let close = frame("dak-in-app-close", in: vc)
        XCTAssertEqual(close, CGRect(x: sheet.maxX - 44, y: sheet.minY + 4, width: 40, height: 40))
        XCTAssertEqual(frame("dak-in-app-backdrop", in: vc), window.bounds)
        // The first button takes the app's tint; the second is a text button.
        XCTAssertNotNil(view("dak-in-app-button-join", in: vc)?.backgroundColor)
        XCTAssertNil(view("dak-in-app-button-later", in: vc)?.backgroundColor)
    }

    func testAModalImageKeepsItsShapeUpTo240High() throws {
        let content: [String: Any] = ["title": "T", "body": "B", "image_url": "https://cdn.example.com/a.png"]
        let wide = show(message("modal", content), image: picture(600, 300))
        snapshot("modal-image", wide)
        let sheet = frame("dak-in-app-sheet", in: wide)
        let image = frame("dak-in-app-image", in: wide)
        XCTAssertEqual(image.width, sheet.width, accuracy: 0.5)
        XCTAssertEqual(image.height, sheet.width / 2, accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-title", in: wide).minY - image.maxY, 20, accuracy: 0.5)
        XCTAssertNotNil(view("dak-in-app-close", in: wide)?.backgroundColor, "the X has a dark circle on an image")

        let tall = show(message("modal", content), image: picture(300, 900))
        XCTAssertEqual(frame("dak-in-app-image", in: tall).height, 240, accuracy: 0.5)
    }

    func testTheCardSlidesUpFromTheBottomEdge() throws {
        let content: [String: Any] = [
            "title": "Your weekly report", "body": "You spoke for 3 hours this week.", "image_url": "https://x/a.png",
            "buttons": Self.buttons,
        ]
        let vc = show(message("card", content), image: picture(800, 400))
        snapshot("card", vc)
        let window = try XCTUnwrap(vc.view.window)
        let sheet = frame("dak-in-app-sheet", in: vc)
        XCTAssertEqual(sheet.maxY, window.bounds.maxY, accuracy: 0.5, "runs under the home indicator")
        XCTAssertEqual(sheet.width, min(600, window.bounds.width), accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-image", in: vc).height, 200, accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-close", in: vc).minY - sheet.minY, 8, accuracy: 0.5)
        let button = frame("dak-in-app-button-join", in: vc)
        XCTAssertEqual(window.bounds.maxY - window.safeAreaInsets.bottom - button.maxY, 16, accuracy: 0.5)
        let layer = try XCTUnwrap(view("dak-in-app-sheet", in: vc)?.layer)
        XCTAssertEqual(layer.cornerRadius, 24)
        XCTAssertEqual(layer.maskedCorners, [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    func testTheFullScreenPageSplitsImageAndTextFiveToFour() throws {
        let content: [String: Any] = [
            "title": "Banglay IELTS", "body": "The new course starts on Sunday.", "image_url": "https://x/a.png",
            "buttons": Self.buttons, "close_button": false,
        ]
        let vc = show(message("fullscreen", content), image: picture(800, 800))
        snapshot("fullscreen", vc)
        let window = try XCTUnwrap(vc.view.window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let image = frame("dak-in-app-image", in: vc)
        let button = frame("dak-in-app-button-join", in: vc)
        XCTAssertEqual(image.minY, safe.minY, accuracy: 0.5)
        XCTAssertEqual(image.height / (button.minY - image.maxY), 1.25, accuracy: 0.01)
        XCTAssertEqual(safe.maxY - button.maxY, 20, accuracy: 0.5)
        XCTAssertNil(view("dak-in-app-close", in: vc), "it has buttons: no X")
        XCTAssertEqual(vc.view.backgroundColor, .systemBackground)

        let noWayOut = show(message("fullscreen", ["title": "T", "close_button": false]))
        let close = frame("dak-in-app-close", in: noWayOut)
        XCTAssertEqual(close.minY, safe.minY + 4, accuracy: 0.5, "a page with no other way out keeps its X")
        XCTAssertEqual(close.maxX, safe.maxX - 4, accuracy: 0.5)
    }

    func testABannerLetsTheAppBeUsedAroundIt() throws {
        let content: [String: Any] = [
            "title": "Rahim is online", "body": "Say hello and practise together.", "image_url": "https://x/a.png",
            "click_action": ["type": "deep_link", "url": "app://chat"],
        ]
        let vc = show(message("banner_top", content), image: picture(200, 200))
        snapshot("banner-top", vc)
        let window = try XCTUnwrap(vc.view.window as? InAppWindow)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let sheet = frame("dak-in-app-sheet", in: vc)
        XCTAssertEqual(sheet.minY, safe.minY + 12, accuracy: 0.5)
        XCTAssertEqual(sheet.width, min(600, safe.width - 24), accuracy: 0.5)
        XCTAssertEqual(view("dak-in-app-sheet", in: vc)?.layer.cornerRadius, 16)
        let image = frame("dak-in-app-image", in: vc)
        XCTAssertEqual(image.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(image.minX - sheet.minX, 12, accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-title", in: vc).minX - image.maxX, 12, accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-close", in: vc).maxX, sheet.maxX - 4, accuracy: 0.5)
        // Touches outside the banner reach the app; on it, the banner.
        XCTAssertNil(window.hitTest(CGPoint(x: safe.midX, y: safe.midY), with: nil))
        XCTAssertNotNil(window.hitTest(CGPoint(x: sheet.midX, y: sheet.midY), with: nil))
    }

    func testABottomBannerStaysAboveTheKeyboard() throws {
        let content: [String: Any] = ["title": "Saved", "body": "Your answer was saved."]
        let plain = show(message("banner_bottom", content))
        let window = try XCTUnwrap(plain.view.window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        XCTAssertEqual(frame("dak-in-app-sheet", in: plain).maxY, safe.maxY - 12, accuracy: 0.5)

        let keyboard = CGRect(x: 0, y: window.bounds.height - 336, width: window.bounds.width, height: 336)
        let typing = show(message("banner_bottom", content), keyboard: keyboard)
        snapshot("banner-bottom-keyboard", typing)
        XCTAssertEqual(frame("dak-in-app-sheet", in: typing).maxY, keyboard.minY - 12, accuracy: 0.5)

        // A keyboard that floats (iPad) covers nothing below it.
        let floating = show(message("banner_bottom", content), keyboard: CGRect(x: 20, y: 200, width: 300, height: 200))
        XCTAssertEqual(frame("dak-in-app-sheet", in: floating).maxY, safe.maxY - 12, accuracy: 0.5)
    }

    func testABannerShowsTwoLinesOfTitleAndThreeOfText() throws {
        let long = String(repeating: "অনেক লম্বা লেখা ", count: 30)
        let vc = show(message("banner_top", ["title": long, "body": long]))
        snapshot("banner-long-bangla", vc)
        XCTAssertEqual((view("dak-in-app-title", in: vc) as? UILabel)?.numberOfLines, 2)
        XCTAssertEqual((view("dak-in-app-body", in: vc) as? UILabel)?.numberOfLines, 3)
        XCTAssertLessThan(frame("dak-in-app-sheet", in: vc).height, 200)
    }

    func testThreeButtonsStackAndSoDoTwoAtTheLargestTypeSizes() throws {
        let three = Self.buttons + [["id": "never", "text": "Never", "action": ["type": "dismiss"]]]
        let vc = show(message("card", ["title": "Pick one", "buttons": three]))
        snapshot("card-three-buttons", vc)
        let a = frame("dak-in-app-button-join", in: vc)
        let b = frame("dak-in-app-button-later", in: vc)
        let c = frame("dak-in-app-button-never", in: vc)
        XCTAssertEqual(b.minY - a.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(c.minY - b.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5)

        guard #available(iOS 17.0, *) else { return }
        let large = show(
            message(
                "modal",
                [
                    "title": "নতুন স্পিকিং চ্যালেঞ্জ!", "body": "আজকের বিষয়: ভ্রমণ। পাঁচ মিনিট কথা বলুন।",
                    "buttons": Self.buttons,
                ]), size: .accessibilityExtraExtraExtraLarge)
        snapshot("modal-bangla-xxxl", large)
        let start = frame("dak-in-app-button-join", in: large)
        let later = frame("dak-in-app-button-later", in: large)
        XCTAssertGreaterThan(later.minY, start.maxY, "stacked at the largest sizes")
        let title = try XCTUnwrap(view("dak-in-app-title", in: large) as? UILabel)
        let font = try XCTUnwrap(title.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, 30, "Dynamic Type scales the title")
        XCTAssertEqual(title.numberOfLines, 0)
        // Long Bangla text is never cut at the top or bottom of a line.
        XCTAssertGreaterThanOrEqual(title.bounds.height, title.intrinsicContentSize.height - 0.5)
    }

    func testRightToLeftPutsTheXAndTheImageOnTheOtherSide() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("traitOverrides needs iOS 17") }
        let content: [String: Any] = ["title": "مرحبا", "body": "تحدث مع شريك اليوم.", "image_url": "https://x/a.png"]
        let vc = show(message("banner_top", content), image: picture(100, 100), rtl: true)
        snapshot("banner-rtl", vc)
        let sheet = frame("dak-in-app-sheet", in: vc)
        XCTAssertEqual(frame("dak-in-app-image", in: vc).maxX, sheet.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(frame("dak-in-app-close", in: vc).minX, sheet.minX + 4, accuracy: 0.5)
        XCTAssertEqual((view("dak-in-app-title", in: vc) as? UILabel)?.textAlignment, .right, "starts on the right")
        XCTAssertEqual(
            frame("dak-in-app-title", in: vc).maxX, frame("dak-in-app-image", in: vc).minX - 12, accuracy: 0.5)

        let modal = show(message("modal", ["title": "مرحبا", "buttons": Self.buttons]), rtl: true)
        let sheet2 = frame("dak-in-app-sheet", in: modal)
        XCTAssertEqual(frame("dak-in-app-close", in: modal).minX, sheet2.minX + 4, accuracy: 0.5)
        XCTAssertGreaterThan(
            frame("dak-in-app-button-join", in: modal).minX, frame("dak-in-app-button-later", in: modal).minX,
            "the first button is on the right")
    }

    func testDarkModeAndTheMessagesOwnColours() throws {
        let dark = show(
            message("modal", ["title": "Dark", "body": "Follows the system.", "buttons": Self.buttons]), style: .dark)
        snapshot("modal-dark", dark)
        let sheetColor = try XCTUnwrap(view("dak-in-app-sheet", in: dark)?.backgroundColor)
        let traits = dark.traitCollection
        XCTAssertEqual(traits.userInterfaceStyle, .dark)
        XCTAssertTrue(InAppColors.isDark(sheetColor, traits))
        let title = try XCTUnwrap(view("dak-in-app-title", in: dark) as? UILabel)
        let titleColor = try XCTUnwrap(title.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        XCTAssertFalse(InAppColors.isDark(titleColor, traits), "light text on the dark sheet")

        let own = show(
            message(
                "modal",
                [
                    "title": "Sale", "body": "50% off", "background_color": "#102030",
                    "buttons": [
                        ["id": "red", "text": "Buy", "action": ["type": "dismiss"], "background_color": "#FFD60A"],
                        ["id": "no", "text": "No", "action": ["type": "dismiss"]],
                    ],
                ]))
        snapshot("modal-own-colours", own)
        let t = try XCTUnwrap(view("dak-in-app-title", in: own) as? UILabel)
        XCTAssertEqual(t.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .white)
        XCTAssertEqual(InAppColors.readable(on: InAppColors.color(0xFFFF_D60A)), UIColor(white: 0, alpha: 0xDE / 255.0))
        XCTAssertEqual(InAppColors.readable(on: InAppColors.color(0xFF10_2030)), .white)
    }

    func testVoiceOverReadsADialogAndCanCloseIt() throws {
        let modal = show(message("modal", ["title": "T", "body": "B", "buttons": Self.buttons]))
        XCTAssertTrue(modal.view.accessibilityViewIsModal)
        let title = try XCTUnwrap(view("dak-in-app-title", in: modal))
        XCTAssertTrue(title.accessibilityTraits.contains(.header))
        XCTAssertFalse(InAppStrings.close.isEmpty)
        XCTAssertEqual(view("dak-in-app-close", in: modal)?.accessibilityLabel, InAppStrings.close)
        XCTAssertEqual(view("dak-in-app-button-join", in: modal)?.accessibilityLabel, "Start")
        XCTAssertTrue(view("dak-in-app-button-join", in: modal)?.accessibilityTraits.contains(.button) == true)
        XCTAssertFalse(view("dak-in-app-backdrop", in: modal)?.isAccessibilityElement ?? true, "the X is the way out")
        var dismissed = 0
        modal.onDismiss = { dismissed += 1 }
        XCTAssertTrue(modal.view.accessibilityPerformEscape())
        XCTAssertEqual(dismissed, 1)

        // A tappable message reads its title and text as one button.
        let tappable = show(
            message("banner_top", ["title": "T", "body": "B", "click_action": ["type": "custom"]]))
        XCTAssertFalse(tappable.view.accessibilityViewIsModal)
        XCTAssertEqual((view("dak-in-app-title", in: tappable) as? UILabel)?.textAlignment, .left)
        let label = try XCTUnwrap(view("dak-in-app-title", in: tappable))
        XCTAssertEqual(label.accessibilityLabel, "T, B")
        XCTAssertTrue(label.accessibilityTraits.contains(.button))
        XCTAssertFalse(view("dak-in-app-body", in: tappable)?.isAccessibilityElement ?? true)
        var clicks = 0
        tappable.onClick = { _ in clicks += 1 }
        XCTAssertTrue(label.accessibilityActivate())
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(label.accessibilityCustomActions?.first?.name, InAppStrings.close)
        XCTAssertEqual(tappable.announcement, "T. B")

        // Without an X, the dimmed backdrop is the way out.
        let noX = show(message("modal", ["title": "T", "close_button": false]))
        XCTAssertTrue(view("dak-in-app-backdrop", in: noX)?.isAccessibilityElement ?? false)
    }

    func testLandscapeKeepsTheMaximumWidths() throws {
        // A landscape iPhone's width in a container of that size.
        let vc = InAppViewController(
            message: message("card", ["title": "T", "buttons": Self.buttons]), image: nil, theme: DakInAppTheme(),
            appTop: nil)
        let host = UIViewController()
        let window = InAppWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        windows.append(window)
        host.addChild(vc)
        vc.view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        host.view.addSubview(vc.view)
        vc.didMove(toParent: host)
        vc.view.layoutIfNeeded()
        let sheet = view("dak-in-app-sheet", in: vc)!
        XCTAssertEqual(sheet.bounds.width, 600, accuracy: 0.5, "a card is at most 600 wide")
        XCTAssertEqual(sheet.convert(sheet.bounds, to: vc.view).midX, 437, accuracy: 0.5)
    }

    // MARK: - The presenter, end to end

    /// A presenter with a controller whose saved list holds [messages] (no
    /// server: nothing is fetched).
    private func present(_ messages: [JSON]) -> (InAppController, InAppPresenter, Box<[DakInAppClick]>) {
        let store = TestStore()
        store.value = JSON.encode(["v": .int(1), "messages": .array(messages)])
        let api = DakApi(baseURL: "https://unused.dak.test", appId: "app", http: URLSessionHTTP(), userAgent: "test")
        let c = InAppController(
            api: api, store: store, credentials: { nil }, setTags: { _ in }, openURL: nil, home: MainQueueScheduler(),
            io: QueueScheduler(label: "dakpush.test.inapp"), clock: Date.init, log: DakLog(debug: false),
            eventDelay: nil)
        let clicks = Box<[DakInAppClick]>([])
        c.onClick = { clicks.value.append($0) }
        let p = InAppPresenter(controller: c)
        p.start()
        c.start()
        controllers.append(c)
        presenters.append(p)
        return (c, p, clicks)
    }

    private func json(_ id: String, _ layout: String, _ content: [String: Any], priority: Int = 0) -> JSON {
        JSON(any: [
            "id": id, "layout": layout, "content": content, "frequency": ["type": "once"], "priority": priority,
        ])
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private var visibleMessageWindows: [UIWindow] {
        scene.windows.filter { $0 is InAppWindow && !$0.isHidden && !windows.contains($0) }
    }

    func testAModalTakesTheKeyboardFocusAndGivesItBack() async throws {
        let field = UITextField(frame: CGRect(x: 20, y: 200, width: 200, height: 40))
        appWindow.addSubview(field)
        defer { field.removeFromSuperview() }
        let before = appWindow
        XCTAssertTrue(field.becomeFirstResponder())

        let (c, p, clicks) = present([json("m", "modal", ["title": "T", "buttons": Self.buttons])])
        try await waitFor("the message") { p.shownController != nil && c.isShowing }
        let window = try XCTUnwrap(p.shownWindow)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(window.windowLevel.rawValue, UIWindow.Level.alert.rawValue - 1)
        XCTAssertTrue(window.accessibilityViewIsModal)
        XCTAssertFalse(field.isFirstResponder, "the message has the focus")
        XCTAssertEqual(c.pendingEvents, 1, "one impression")

        let button = try XCTUnwrap(p.shownController?.buttonViews.first)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(clicks.value.map(\.buttonId), ["join"])
        XCTAssertEqual(clicks.value.first?.actionType, .deepLink)
        XCTAssertEqual(clicks.value.first?.url, "amarpartner://challenge/travel")
        XCTAssertNil(c.current)
        try await waitFor("the window to go") { window.isHidden }
        XCTAssertTrue(before.isKeyWindow, "the app's window is key again")
        XCTAssertTrue(field.isFirstResponder, "the focus is back")
        XCTAssertEqual(c.pendingEvents, 2)
    }

    func testABannerLeavesTheAppItsFocusAndClosesByItself() async throws {
        let before = appWindow
        let (c, p, _) = present([json("b", "banner_top", ["title": "T", "auto_dismiss_seconds": 1])])
        try await waitFor("the banner") { p.shownController != nil && c.isShowing }
        let window = try XCTUnwrap(p.shownWindow as? InAppWindow)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(before.isKeyWindow)
        XCTAssertTrue(window.passThrough)
        if UIAccessibility.isVoiceOverRunning { return }
        try await waitFor("the timer", timeout: 4) { c.current == nil }
        try await waitFor("the window to go") { window.isHidden }
        XCTAssertEqual(c.pendingEvents, 2, "impression and dismissal")
    }

    func testPausingHidesTheMessageAndItComesBackWithoutANewImpression() async throws {
        let (c, p, _) = present([json("m", "card", ["title": "T", "body": "B"])])
        try await waitFor("the card") { c.isShowing }
        let first = try XCTUnwrap(p.shownWindow)
        c.block()
        try await waitFor("it hides") { first.isHidden }
        XCTAssertNil(p.shownController)
        c.unblock()
        try await waitFor("it comes back") { c.isShowing && p.shownWindow != nil }
        XCTAssertEqual(c.pendingEvents, 1)
        p.shownController?.closeButton?.sendActions(for: .touchUpInside)
        XCTAssertNil(c.current)
        XCTAssertEqual(c.pendingEvents, 2)
    }

    func testTheSceneGoingAwayTakesTheMessageAlongAndBringsItBack() async throws {
        let (c, p, _) = present([json("m", "modal", ["title": "T"])])
        try await waitFor("the modal") { c.isShowing }
        let host = InAppPresenter.host(scene)
        XCTAssertEqual(c.activeHost, host)
        c.detach(host)
        try await waitFor("it hides") { p.shownWindow == nil }
        XCTAssertNil(c.current)
        c.attach(host)
        try await waitFor("it is back") { c.isShowing }
        XCTAssertEqual(c.pendingEvents, 1, "the same display")
    }

    func testAnImageThatDoesNotLoadIsLeftOutOrTheMessageSkipped() async throws {
        let (c, p, _) = present([
            json("image-only", "modal", ["image_url": "https://nowhere.invalid/a.png"], priority: 2),
            json("with-text", "modal", ["title": "T", "image_url": "https://nowhere.invalid/b.png"], priority: 1),
        ])
        try await waitFor("the message with text", timeout: 12) { c.current?.id == "with-text" && c.isShowing }
        XCTAssertNil(p.shownController?.imageView, "shown without its image")
        XCTAssertNotNil(p.shownController?.titleLabel)
    }
}

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

final class TestStore: DakStateStore {
    var value: Data?
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}
