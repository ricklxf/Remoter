import Foundation
import CoreGraphics
import ObjectiveC

public final class VirtualDisplayManager: @unchecked Sendable {
    public static let shared = VirtualDisplayManager()

    private let lock = NSLock()
    private var activeVirtualDisplay: AnyObject?
    public private(set) var activeDisplayID: CGDirectDisplayID?

    private let allocSel = NSSelectorFromString("alloc")
    private lazy var msgSendAlloc: (@convention(c) (AnyClass, Selector) -> AnyObject)? = {
        guard let method = class_getMethodImplementation(object_getClass(NSObject.self), allocSel) else { return nil }
        return unsafeBitCast(method, to: (@convention(c) (AnyClass, Selector) -> AnyObject).self)
    }()

    public init() {}

    deinit {
        destroyVirtualDisplay()
    }

    @discardableResult
    public func createVirtualDisplay(
        width: UInt = 1920,
        height: UInt = 1080,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true,
        name: String = "Remoter-Virtual-Display"
    ) -> CGDirectDisplayID? {
        return createOrUpdateVirtualDisplay(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI, name: name)
    }

    @discardableResult
    public func createOrUpdateVirtualDisplay(
        logicalWidth: UInt,
        logicalHeight: UInt,
        refreshRate: Double = 60.0,
        scaleFactor: Double = 1.0,
        name: String = "Remoter-Virtual-Display"
    ) -> CGDirectDisplayID? {
        let hiDPI = scaleFactor > 1.0
        return applyVirtualDisplay(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            scaleFactor: scaleFactor,
            name: name
        )
    }

    @discardableResult
    public func createOrUpdateVirtualDisplay(
        width: UInt = 1920,
        height: UInt = 1080,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true,
        name: String = "Remoter-Virtual-Display"
    ) -> CGDirectDisplayID? {
        return applyVirtualDisplay(
            logicalWidth: width,
            logicalHeight: height,
            refreshRate: refreshRate,
            hiDPI: hiDPI,
            scaleFactor: hiDPI ? 2.0 : 1.0,
            name: name
        )
    }

    private func applyVirtualDisplay(
        logicalWidth: UInt,
        logicalHeight: UInt,
        refreshRate: Double,
        hiDPI: Bool,
        scaleFactor: Double,
        name: String
    ) -> CGDirectDisplayID? {
        lock.lock()
        defer { lock.unlock() }

        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor"),
              let modeCls = NSClassFromString("CGVirtualDisplayMode"),
              let setCls = NSClassFromString("CGVirtualDisplaySettings"),
              let dispCls = NSClassFromString("CGVirtualDisplay"),
              let allocFn = msgSendAlloc else {
            ConnectionLogger.shared.logStep(sessionId: "display", step: "virtual_display_unavailable", detail: "Classes not present")
            return nil
        }

        // When HiDPI is enabled (scaleFactor > 1.0), macOS renders a 2x Retina
        // backing store for the given logical UI mode so fonts and UI stay crisp
        // at normal readable sizes rather than shrinking.
        let backingScale = hiDPI ? max(scaleFactor, 2.0) : 1.0
        let backingWidth = UInt((Double(logicalWidth) * backingScale).rounded())
        let backingHeight = UInt((Double(logicalHeight) * backingScale).rounded())

        let displayObj: AnyObject
        if let existing = activeVirtualDisplay {
            displayObj = existing
        } else {
            // 1. Configure virtual display descriptor (allow up to 8K backing pixels dynamically)
            let desc = (descCls as! NSObject.Type).init()
            desc.setValue(name, forKey: "name")
            desc.setValue(max(backingWidth, 7680), forKey: "maxPixelsWide")
            desc.setValue(max(backingHeight, 4320), forKey: "maxPixelsHigh")
            desc.setValue(CGSize(width: 600, height: 340), forKey: "sizeInMillimeters")
            desc.setValue(UInt32(0x1234), forKey: "productID")
            desc.setValue(UInt32(0x5678), forKey: "vendorID")
            desc.setValue(UInt32(0x0001), forKey: "serialNum")

            // 2. Instantiate CGVirtualDisplay
            let dispAlloc = allocFn(dispCls, allocSel)
            let initDescSel = NSSelectorFromString("initWithDescriptor:")
            typealias InitWithDescFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
            guard let initDescMethod = class_getMethodImplementation(dispCls, initDescSel) else { return nil }
            let initWithDesc = unsafeBitCast(initDescMethod, to: InitWithDescFn.self)
            displayObj = initWithDesc(dispAlloc, initDescSel, desc)
        }

        // 3. Configure logical UI resolution and refresh rate
        let modeAlloc = allocFn(modeCls, allocSel)
        let initModeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        typealias InitModeFn = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject
        guard let initModeMethod = class_getMethodImplementation(modeCls, initModeSel) else { return nil }
        let initMode = unsafeBitCast(initModeMethod, to: InitModeFn.self)
        let mode = initMode(modeAlloc, initModeSel, logicalWidth, logicalHeight, refreshRate)

        // 4. Configure display settings (HiDPI 2x Retina support when scaleFactor > 1.0)
        let settings = (setCls as! NSObject.Type).init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(hiDPI ? 1 : 0, forKey: "hiDPI")

        // 5. Apply settings
        let applySel = NSSelectorFromString("applySettings:")
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let applyMethod = class_getMethodImplementation(dispCls, applySel) else { return nil }
        let apply = unsafeBitCast(applyMethod, to: ApplyFn.self)
        let ok = apply(displayObj, applySel, settings)

        guard ok else {
            ConnectionLogger.shared.logStep(sessionId: "display", step: "virtual_display_apply_failed")
            return nil
        }

        guard let displayID = (displayObj as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID, displayID != 0 else {
            ConnectionLogger.shared.logStep(sessionId: "display", step: "virtual_display_no_id")
            return nil
        }

        let isUpdate = (self.activeVirtualDisplay != nil)
        self.activeVirtualDisplay = displayObj
        self.activeDisplayID = displayID

        ConnectionLogger.shared.logStep(sessionId: "display",
            step: isUpdate ? "virtual_display_updated" : "virtual_display_created",
            detail: "logical=\(logicalWidth)x\(logicalHeight) backing=\(backingWidth)x\(backingHeight)@\(Int(refreshRate))Hz scale=\(String(format: "%.2f", scaleFactor)) hiDPI=\(hiDPI) id=\(displayID)")
        return displayID
    }

    public func destroyVirtualDisplay() {
        lock.lock()
        defer { lock.unlock() }

        guard let display = activeVirtualDisplay else { return }

        let termSel = NSSelectorFromString("termination")
        if (display as AnyObject).responds(to: termSel) {
            _ = (display as AnyObject).perform(termSel)
        }

        activeVirtualDisplay = nil
        activeDisplayID = nil
        ConnectionLogger.shared.logStep(sessionId: "display", step: "virtual_display_destroyed")
    }
}
