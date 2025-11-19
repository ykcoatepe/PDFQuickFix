import Foundation
import Darwin

enum PDFKitWorkarounds {
    private static var hasInstalled = false

    /// Installs global PDFKit fixes that must run before any document loads.
    static func install() {
        guard !hasInstalled else { return }
        hasInstalled = true
        disableStructureTreeEmission()
    }

    /// PDFKit 2024.x crashes on some tagged PDFs while emitting structure trees to Metal.
    /// Force-disable that code path through every preference channel we can control.
    private static func disableStructureTreeEmission() {
        let defaults = UserDefaults.standard

        let falseKeys = ["PDFDocumentEmitStructureTree", "PDFDocumentEmitTaggedStructure", "PDFDocumentEmitTextStructure"]
        let trueKeys = ["PDFViewUseRenderingEngineLegacy", "PDFViewDisableFastPathRendering", "PDFViewDisableAsyncRendering"]

        defaults.setVolatileDomain(Dictionary(uniqueKeysWithValues: falseKeys.map { ($0, "false") }), forName: UserDefaults.registrationDomain)
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: falseKeys.map { ($0, "false") }))
        for key in falseKeys {
            defaults.set("false", forKey: key)
            setenv(key, "0", 1)
            CFPreferencesSetAppValue(key as CFString, "false" as CFString, kCFPreferencesCurrentApplication)
        }

        for key in trueKeys {
            defaults.set(true, forKey: key)
            setenv(key, "1", 1)
            CFPreferencesSetAppValue(key as CFString, kCFBooleanTrue, kCFPreferencesCurrentApplication)
        }

        defaults.set(true, forKey: "CGDisableAcceleratedPDFDrawing")
        defaults.set(true, forKey: "PDFViewDisableMetal")
        setenv("CGDisableAcceleratedPDFDrawing", "1", 1)
        setenv("PDFViewDisableMetal", "1", 1)

        defaults.synchronize()
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)

        NSLog("PDFQuickFix: forced %@=false (defaults=%@)", "PDFDocumentEmitStructureTree", defaults.bool(forKey: "PDFDocumentEmitStructureTree") ? "true" : "false")

        PDFQFInstallPDFPageGuard()
    }
}

// Execute immediately at module load time so PDFKit sees the flags before initialization.
private let _pdfKitWorkaroundsInstalled: Void = {
    PDFKitWorkarounds.install()
}()
