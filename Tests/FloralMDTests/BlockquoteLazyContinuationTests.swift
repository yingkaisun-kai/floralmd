// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import Foundation
import Markdown
@testable import FloralMDCore

// CommonMark blockquote lazy continuation in edit-mode segmentation: a bare
// non-blank line after a plain block-quote paragraph joins the quote. Callouts
// stay strict (each `>`-run is its own block) so a following `> [!type]` can't
// be swallowed into a prior callout's paragraph (GFM ex. 228).
@Suite("BlockParser — blockquote lazy continuation")
struct BlockquoteLazyContinuationTests {

    // MARK: - Plain quotes: lazy continuation joins

    @Test("A bare line after a quote paragraph joins the quote")
    func lazyLineJoins() {
        let blocks = BlockParser.parse("> a\nb")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "> a\nb")
        #expect(blocks[0].kind == .quoteRun(isCallout: false))
    }

    @Test("A blank line ends the quote; the next line is a separate paragraph")
    func blankBreaksContinuation() {
        let blocks = BlockParser.parse("> a\n\nb")
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "> a")
        #expect(blocks[0].kind == .quoteRun(isCallout: false))
        #expect(blocks[2].content == "b")
        #expect(blocks[2].kind == .paragraph)
    }

    @Test("A heading after `>` does not lazily continue (it interrupts)")
    func headingInterrupts() {
        let blocks = BlockParser.parse("> a\n# h")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "> a")
        #expect(blocks[1].content == "# h")
        #expect(blocks[1].kind == .heading(level: 1))
    }

    @Test("A list item after `>` does not lazily continue")
    func listInterrupts() {
        let blocks = BlockParser.parse("> a\n- x")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "> a")
        #expect(blocks[1].content == "- x")
        #expect(blocks[1].kind == .listItem)
    }

    @Test("GFM ex. 228: mixed `>` and bare lines collapse to one quote")
    func example228() {
        let blocks = BlockParser.parse("> bar\nbaz\n> foo")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "> bar\nbaz\n> foo")
        #expect(blocks[0].kind == .quoteRun(isCallout: false))
    }

    @Test("An empty `>` closes the paragraph — the next bare line is separate")
    func emptyQuoteNoLazy() {
        let blocks = BlockParser.parse(">\nb")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == ">")
        #expect(blocks[1].content == "b")
        #expect(blocks[1].kind == .paragraph)
    }

    // MARK: - Callouts stay strict

    @Test("A callout body does not lazily continue (strict `>`-run)")
    func calloutStaysStrict() {
        let blocks = BlockParser.parse("> [!note] x\nlazy")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "> [!note] x")
        #expect(blocks[0].kind == .quoteRun(isCallout: true))
        #expect(blocks[1].content == "lazy")
        #expect(blocks[1].kind == .paragraph)
    }

    // MARK: - Differential oracle vs whole-doc CommonMark

    // For an isolated plain-quote doc, the first block's line span must equal
    // swift-markdown's first BlockQuote node span (edit segmentation == read).
    @Test("Plain-quote extent matches swift-markdown's BlockQuote span", arguments: [
        "> a\nb",
        "> a\nb\nc",
        "> bar\nbaz\n> foo",
        "> a\n# h",
        "> a\n- x",
        ">\nb",
    ])
    func matchesCommonMark(_ doc: String) {
        let blocks = BlockParser.parse(doc)
        let firstQuoteLines = blocks[0].content.split(separator: "\n",
            omittingEmptySubsequences: false).count

        let parsed = Document(parsing: doc, options: [.disableSmartOpts])
        guard let quote = parsed.child(at: 0) as? BlockQuote, let r = quote.range else {
            Issue.record("expected a leading BlockQuote in \(doc.debugDescription)")
            return
        }
        let cmarkQuoteLines: Int
        if parsed.childCount > 1, let nextStart = parsed.child(at: 1)?.range?.lowerBound.line {
            cmarkQuoteLines = nextStart - 1
        } else {
            cmarkQuoteLines = r.upperBound.line - r.lowerBound.line + 1
        }
        #expect(firstQuoteLines == cmarkQuoteLines,
                "quote extent mismatch for \(doc.debugDescription)")
    }
}
