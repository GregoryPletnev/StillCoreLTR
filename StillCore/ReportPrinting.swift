import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns a report into paper, a PDF or a CSV.
///
/// Printing and PDF export share one renderer: the print job is the exported
/// PDF, so what the printer produces is exactly what the export contains.
@MainActor
enum ReportExporter {
    enum ExportError: LocalizedError {
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed:
                return "The report could not be rendered."
            }
        }
    }

    // MARK: - Printing

    static func print(_ report: Report) throws {
        let printInfo = makePrintInfo()
        let pageSize = printableSize(for: printInfo)

        guard
            let data = pdfData(for: report, pageSize: pageSize),
            let document = PDFDocument(data: data)
        else {
            throw ExportError.renderFailed
        }

        // Pages are already composed at the paper size, so no extra scaling.
        let operation = document.printOperation(
            for: printInfo, scalingMode: .pageScaleNone, autoRotate: false)
        operation?.jobTitle = report.exportName()
        operation?.run()
    }

    // MARK: - PDF

    static func exportPDF(_ report: Report) throws {
        guard let data = pdfData(for: report, pageSize: ReportPageLayout.defaultPageSize) else {
            throw ExportError.renderFailed
        }
        save(data: data, name: "\(report.exportName()).pdf", type: .pdf)
    }

    /// Renders every page into one PDF. Content is drawn as vectors, so the
    /// output stays sharp at any zoom and prints at the device resolution.
    static func pdfData(for report: Report, pageSize: CGSize) -> Data? {
        let pages = ReportPageBuilder.pages(for: report, pageSize: pageSize)
        guard !pages.isEmpty else { return nil }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        // The report palette resolves against the current appearance. Paper is
        // white, so every page is drawn in the light appearance.
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            for page in pages {
                let renderer = ImageRenderer(content: page)
                renderer.proposedSize = ProposedViewSize(pageSize)
                renderer.render { _, renderInContext in
                    context.beginPDFPage(nil)
                    renderInContext(context)
                    context.endPDFPage()
                }
            }
        }
        context.closePDF()

        return output as Data
    }

    // MARK: - CSV

    static func exportCSV(_ report: Report) {
        let data = Data(report.csv().utf8)
        save(data: data, name: "\(report.exportName()).csv", type: .commaSeparatedText)
    }

    // MARK: - Helpers

    private static func makePrintInfo() -> NSPrintInfo {
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.orientation = .landscape
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        return printInfo
    }

    /// Paper size in points, in landscape. Falls back to A4 when the print
    /// system reports something unusable.
    private static func printableSize(for printInfo: NSPrintInfo) -> CGSize {
        let paper = printInfo.paperSize
        guard paper.width > 100, paper.height > 100 else {
            return ReportPageLayout.defaultPageSize
        }
        return printInfo.orientation == .landscape && paper.width < paper.height
            ? CGSize(width: paper.height, height: paper.width)
            : paper
    }

    private static func save(data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
