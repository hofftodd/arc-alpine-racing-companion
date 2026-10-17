import PDFKit
import SwiftUI

/// Shows a bundled PDF at a page and highlights the cited passage; the toolbar prints it.
struct DocumentViewer: View {
    let filename: String
    let pageIndex: Int
    var highlight: String?
    /// Names the print job ("Protest Form") instead of the bundled file name.
    var title: String?

    var body: some View {
        if let url = Self.url(for: filename), let document = PDFDocument(url: url) {
            PDFKitView(document: document, pageIndex: pageIndex, highlight: highlight)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Print", systemImage: "printer") {
                            Self.print(document, url: url, jobName: title ?? url.deletingPathExtension().lastPathComponent)
                        }
                        .keyboardShortcut("p")
                    }
                }
        } else {
            ContentUnavailableView("Document not found", systemImage: "doc.questionmark", description: Text(filename))
        }
    }

    static func url(for filename: String) -> URL? {
        Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Documents")
            ?? Bundle.main.url(forResource: filename, withExtension: nil)
    }

    /// The whole document, not just the visible page: forms are printed to fill in by hand.
    @MainActor
    static func print(_ document: PDFDocument, url: URL, jobName: String) {
        #if os(iOS)
            let info = UIPrintInfo.printInfo()
            info.outputType = .general
            info.jobName = jobName
            let controller = UIPrintInteractionController.shared
            controller.printInfo = info
            controller.printingItem = url
            controller.present(animated: true)
        #else
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .spool
            guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
            operation.jobTitle = jobName
            operation.run()
        #endif
    }

    /// Finds the passage on (or next to) the target page. Extracted text can differ
    /// slightly from the PDF's own text layer, so try progressively shorter phrases.
    static func selection(in document: PDFDocument, pageIndex: Int, excerpt: String) -> PDFSelection? {
        // Skip the leading rule number; it is often laid out apart from the text.
        let words = excerpt.split(separator: " ").drop { $0.first?.isNumber == true }
        let nearby = Set([pageIndex, pageIndex + 1].compactMap { document.page(at: $0) })
        for count in [10, 6, 4] where words.count >= count {
            let phrase = words.prefix(count).joined(separator: " ")
            let matches = document.findString(phrase, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if let match = matches.first(where: { $0.pages.contains(where: nearby.contains) }) {
                return match
            }
        }
        return nil
    }
}

#if os(iOS)
    private typealias Representable = UIViewRepresentable
#else
    private typealias Representable = NSViewRepresentable
#endif

private struct PDFKitView: Representable {
    let document: PDFDocument
    let pageIndex: Int
    let highlight: String?

    final class Coordinator {
        var navigatedTo: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeView() -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    private func update(_ view: PDFView, coordinator: Coordinator) {
        if view.document !== document { view.document = document }
        // Navigate once per target page so re-renders don't undo the user's scrolling.
        guard coordinator.navigatedTo != pageIndex, let page = document.page(at: pageIndex) else { return }
        coordinator.navigatedTo = pageIndex
        // Wait a run-loop turn so autoScales has laid out the pages before jumping.
        Task { @MainActor in
            if let highlight,
                let selection = DocumentViewer.selection(in: document, pageIndex: pageIndex, excerpt: highlight)
            {
                selection.color = .systemYellow.withAlphaComponent(0.5)
                view.highlightedSelections = [selection]
                view.go(to: selection)
            } else {
                view.go(to: page)
            }
        }
    }

    #if os(iOS)
        func makeUIView(context: Context) -> PDFView { makeView() }
        func updateUIView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
    #else
        func makeNSView(context: Context) -> PDFView { makeView() }
        func updateNSView(_ view: PDFView, context: Context) { update(view, coordinator: context.coordinator) }
    #endif
}
