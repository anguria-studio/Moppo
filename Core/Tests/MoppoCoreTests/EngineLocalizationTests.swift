import Foundation
import Testing
@testable import MoppoCore

struct EngineLocalizationTests {
    @Test("A rule label uses the selected language and English fallback",
          arguments: [("it", "Cache di compilazione di Go"), ("fr", "Cache de compilation Go"),
                      ("es", "Caché de compilación de Go"), ("ja", "Go build cache")])
    func ruleLabel(language: String, expected: String) {
        let label = EngineText.rule("Go build cache")
        #expect(label.english == "Go build cache")
        #expect(label.localized(language: language, locale: .init(identifier: "en_US")) == expected)
    }

    @Test("A file name that matches a rule label stays unchanged")
    func preservesFileName() {
        let url = URL(fileURLWithPath: "/tmp/Go build cache")
        let entry = FileEntry(url: url, kind: .file, allocatedBytes: 128)
        #expect(entry.nameText.localized(language: "it", locale: .init(identifier: "it_IT")) == "Go build cache")
        #expect(entry.id == url.path)
    }

    @Test("The catalog formats item counts and preserves the folder path",
          arguments: [(0, "elementos"), (1, "elemento"), (2, "elementos")])
    func formatsItemCount(count: Int, noun: String) {
        let path = "/tmp/Go build cache"
        let label: EngineText = "\(path) · \(count) items"
        #expect(label.localized(language: "es", locale: .init(identifier: "es_ES")) == "\(path) · \(count) \(noun)")
    }

    @Test("Plural rules follow the app language when the region uses another language")
    func formatsMixedLanguageAndRegion() {
        let count = 0
        let label: EngineText = "\(count) files"
        let region = Locale(identifier: "en_US")
        #expect(label.localized(language: "fr", locale: region) == "0 fichier")
        let presentation = PresentationLocale.appLanguage("fr", in: region)
        #expect(presentation.region == region.region)
        #expect(1234.5.formatted(.number.locale(presentation)) == 1234.5.formatted(.number.locale(region)))
    }

    @Test("A Git check uses localized guidance and preserves its English result")
    func formatsWorktreeCheck() {
        let detail = GitWorktreeReview.failureReason(ProcessError.timedOut("/usr/bin/git"), tool: .git)
        #expect(detail.english == "Git timed out.")
        #expect(detail.localized(language: "it", locale: .init(identifier: "en_US")) == "Git ha superato il tempo limite.")
    }

    @Test("A stored simulator result localizes guidance with its original Xcode version")
    func localizesStoredSimulatorGuidance() throws {
        let saved = """
            {
              "targetID": "simulator-runtime:065BE591-9A66-452D-9198-84B15E197715",
              "name": "iOS 18.1 Simulator Runtime",
              "command": "/usr/bin/xcrun simctl runtime delete 065BE591-9A66-452D-9198-84B15E197715",
              "status": "completed",
              "exitStatus": 0,
              "standardError": "The runtime inventory command reached its time limit.",
              "afterBytes": 1250000000,
              "remainingStorageReason": "macOS still stores the downloaded image (1.25 GB).\\nThis can result from an Xcode 27.1.3 issue. Apple lists a fix in Xcode 27.2. After you update Xcode, retry removal in Xcode Components."
            }
            """
        let result = try JSONDecoder().decode(ToolCommandRemovalResult.self, from: Data(saved.utf8))
        let summary = result.localizedSummary(language: "it", locale: .init(identifier: "it_IT"))
        #expect(summary.contains("macOS conserva ancora l’immagine scaricata (1,25 GB)."))
        #expect(summary.contains("La causa può essere un problema in Xcode 27.1.3."))
        #expect(summary.hasSuffix(result.standardError))
        #expect(result.summary.contains("This can result from an Xcode 27.1.3 issue."))
    }

    @Test("The simulator verification timeout and raw standard error survive a history reload")
    func localizesStoredSimulatorTimeout() throws {
        var result = ToolCommandRemovalResult(targetID: "simulator-runtime:065BE591-9A66-452D-9198-84B15E197715",
                                              name: "iOS 18.1 Simulator Runtime", command: "/usr/bin/xcrun")
        let raw = "The runtime inventory command reached its time limit.\nCommand output."
        result.status = .failed
        result.exitStatus = 0
        result.failureReason = "Runtime removal could not be verified. Scan again."
        result.standardError = raw + "\nThe runtime inventory command reached its time limit."

        let saved = try JSONEncoder().encode(result)
        let reloaded = try JSONDecoder().decode(ToolCommandRemovalResult.self, from: saved)
        let summary = reloaded.localizedSummary(language: "it", locale: .init(identifier: "it_IT"))
        #expect(reloaded == result)
        #expect(reloaded.summary.hasSuffix(result.standardError))
        #expect(summary.hasSuffix(raw + "\nIl comando che elenca gli ambienti di esecuzione ha raggiunto il tempo limite."))
    }

    @Test("Storage uses the current display locale and retains fixed command formatting")
    func formatsStorage() {
        let bytes: Int64 = 173_890_000_000
        #expect(ByteFormatting.localizedString(bytes, locale: .init(identifier: "it_IT")) == "173,89 GB")
        #expect(ByteFormatting.localizedString(bytes, locale: .init(identifier: "fr_FR")) == "173,89\u{202F}Go")
        #expect(ByteFormatting.string(bytes) == "173.89 GB")
    }
}
