import AppKit
import SwiftUI

/// Lets the user review a report before opening an email draft.
struct SupportView: View {
    private let report = SupportReport.text()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Report a Problem").font(.title2)
            Text("Describe the steps and the result in your email. Remove private information before you send it.")
            Text("Support: \(SupportReport.email)").textSelection(.enabled)
            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("Email Support") {
                    if let url = SupportReport.emailURL(report: report) { NSWorkspace.shared.open(url) }
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 560, height: 380)
    }
}

/// Shows the privacy information included with the installed application.
struct PrivacyView: View {
    private var sections: [String] {
        guard let url = Bundle.main.url(forResource: "Privacy", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ["Privacy information is not available in this build. Contact \(SupportReport.email) for help."]
        }
        return text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    if section.hasPrefix("#") {
                        Text(section.trimmingCharacters(in: CharacterSet(charactersIn: "# \n"))).font(.headline)
                    } else {
                        Text(section.replacingOccurrences(of: "\n", with: " ")).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(width: 560, height: 440)
    }
}
