//
//  HoverSummaryView.swift
//  tinyFire
//
//  Compact dark card for desktop hover — today total + optional live tok/s + sources.
//

import AppKit

final class HoverSummaryView: NSView {
    struct Model {
        var todayTokens: Int
        /// Estimated tokens/sec from recent burn (smoothed). Ignored when showLiveRate is false.
        var tokensPerSecond: Double
        /// Source-specific live rates. Used when multiple tools are active concurrently.
        var rates: [(source: UsageSource, tokensPerSecond: Double)]
        var showLiveRate: Bool
        var rows: [(source: UsageSource, tokens: Int, estimated: Bool)]
        var updatedAt: Date?
    }

    /// Fixed card width — independent of flame panel size.
    static let cardWidth: CGFloat = 248

    private var model = Model(
        todayTokens: 0,
        tokensPerSecond: 0,
        rates: [],
        showLiveRate: true,
        rows: [],
        updatedAt: nil
    )

    private let padX: CGFloat = 14
    private let padY: CGFloat = 12

    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    func apply(_ model: Model) {
        let same =
            self.model.todayTokens == model.todayTokens
            && abs(self.model.tokensPerSecond - model.tokensPerSecond) < 0.05
            && self.model.rates.count == model.rates.count
            && zip(self.model.rates, model.rates).allSatisfy {
                $0.source == $1.source && abs($0.tokensPerSecond - $1.tokensPerSecond) < 0.05
            }
            && self.model.showLiveRate == model.showLiveRate
            && self.model.rows.count == model.rows.count
            && zip(self.model.rows, model.rows).allSatisfy {
                $0.source == $1.source && $0.tokens == $1.tokens && $0.estimated == $1.estimated
            }
            && self.model.updatedAt == model.updatedAt
        if same { return }
        let sizeChanged =
            self.model.rows.count != model.rows.count
            || self.model.rates.count != model.rates.count
            || self.model.showLiveRate != model.showLiveRate
        self.model = model
        needsDisplay = true
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let liveRateRows = model.showLiveRate ? max(1, model.rates.count) : 0
        let headerH: CGFloat = model.showLiveRate ? max(48, CGFloat(liveRateRows) * 18 + 22) : 34
        let dividerGap: CGFloat = model.rows.isEmpty ? 0 : 10
        let rowH: CGFloat = CGFloat(model.rows.count) * 18
        let updatedH: CGFloat = model.updatedAt == nil ? 0 : 16
        return NSSize(
            width: Self.cardWidth,
            height: padY * 2 + headerH + dividerGap + rowH + updatedH
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.76).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        let content = bounds.insetBy(dx: padX, dy: padY)
        var y = content.maxY - 16

        if model.showLiveRate {
            let colGap: CGFloat = 10
            let leftW = floor(content.width * 0.52)
            let rightX = content.minX + leftW + colGap
            let rightW = content.width - leftW - colGap

            let todayText = formatTokens(model.todayTokens)
            let todayFont = fittedMonoFont(for: todayText, maxSize: 20, minSize: 13, width: leftW)

            drawText(
                todayText,
                at: NSPoint(x: content.minX, y: y - 2),
                font: todayFont,
                color: .white,
                width: leftW
            )
            drawText(
                L10n.t("hover.today"),
                at: NSPoint(x: content.minX, y: y - 18),
                font: .systemFont(ofSize: 9, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.38),
                width: leftW
            )

            if model.rates.count <= 1 {
                let source = model.rates.first?.source
                let value = model.rates.first?.tokensPerSecond ?? model.tokensPerSecond
                let rateText = formatRate(value)
                let rateFont = fittedMonoFont(for: rateText, maxSize: 20, minSize: 13, width: rightW)
                let rateColor = source.map(SourceFlameColors.nsColor(for:))
                    ?? (value > 0
                        ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.38, alpha: 1)
                        : NSColor.white.withAlphaComponent(0.55))

                drawText(
                    rateText,
                    at: NSPoint(x: rightX, y: y - 2),
                    font: rateFont,
                    color: rateColor,
                    width: rightW,
                    align: .right
                )
                drawText(
                    source?.displayName ?? L10n.t("hover.rate"),
                    at: NSPoint(x: rightX, y: y - 18),
                    font: .systemFont(ofSize: 9, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.38),
                    width: rightW,
                    align: .right
                )
                y -= 40
            } else {
                var rateY = y + 1
                for item in model.rates {
                    let valueText = formatRate(item.tokensPerSecond)
                    let nameW = floor(rightW * 0.50)
                    let valueW = rightW - nameW - 4
                    drawText(
                        item.source.displayName,
                        at: NSPoint(x: rightX, y: rateY - 1),
                        font: .systemFont(ofSize: 10, weight: .medium),
                        color: SourceFlameColors.nsColor(for: item.source).withAlphaComponent(0.95),
                        width: nameW
                    )
                    drawText(
                        valueText,
                        at: NSPoint(x: rightX + nameW + 4, y: rateY - 1),
                        font: fittedMonoFont(for: valueText, maxSize: 12, minSize: 9, width: valueW),
                        color: SourceFlameColors.nsColor(for: item.source),
                        width: valueW,
                        align: .right
                    )
                    rateY -= 18
                }
                drawText(
                    L10n.t("hover.rate"),
                    at: NSPoint(x: rightX, y: rateY - 1),
                    font: .systemFont(ofSize: 9, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.38),
                    width: rightW,
                    align: .right
                )
                y -= max(40, CGFloat(model.rates.count) * 18 + 14)
            }
        } else {
            let todayText = formatTokens(model.todayTokens)
            let valueW = content.width * 0.62
            let labelW = content.width - valueW - 6
            let todayFont = fittedMonoFont(for: todayText, maxSize: 22, minSize: 14, width: valueW)
            drawText(
                todayText,
                at: NSPoint(x: content.minX, y: y - 2),
                font: todayFont,
                color: .white,
                width: valueW
            )
            drawText(
                L10n.t("hover.tokens"),
                at: NSPoint(x: content.maxX - labelW, y: y + 2),
                font: .systemFont(ofSize: 10, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.45),
                width: labelW,
                align: .right
            )
            y -= 26
        }

        if !model.rows.isEmpty {
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: content.minX, y: y + 6))
            rule.line(to: NSPoint(x: content.maxX, y: y + 6))
            NSColor.white.withAlphaComponent(0.08).setStroke()
            rule.lineWidth = 1
            rule.stroke()
            y -= 4
        }

        for row in model.rows {
            y -= 18
            let dot = NSBezierPath(ovalIn: NSRect(x: content.minX, y: y + 4, width: 6, height: 6))
            SourceFlameColors.nsColor(for: row.source).withAlphaComponent(0.95).setFill()
            dot.fill()
            let suffix = row.estimated ? " · \(L10n.t("hover.estimated"))" : ""
            let nameW = content.width * 0.58
            let valueW = content.width - nameW - 12
            let valueText = formatTokens(row.tokens)
            drawText(
                row.source.displayName + suffix,
                at: NSPoint(x: content.minX + 12, y: y),
                font: .systemFont(ofSize: 11, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.58),
                width: nameW - 12
            )
            drawText(
                valueText,
                at: NSPoint(x: content.minX + nameW, y: y),
                font: fittedMonoFont(for: valueText, maxSize: 11, minSize: 9, width: valueW),
                color: NSColor.white.withAlphaComponent(0.88),
                width: valueW,
                align: .right
            )
        }

        if let updatedAt = model.updatedAt {
            y -= 18
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.resolvedLocale
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: updatedAt)
            drawText(
                String(format: L10n.t("hover.updated"), time),
                at: NSPoint(x: content.minX, y: y),
                font: .systemFont(ofSize: 9, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.34),
                width: content.width
            )
        }
    }

    private func drawText(
        _ string: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        align: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (string as NSString).draw(
            in: NSRect(x: point.x, y: point.y, width: width, height: font.pointSize + 6),
            withAttributes: attrs
        )
    }

    private func fittedMonoFont(
        for string: String,
        maxSize: CGFloat,
        minSize: CGFloat,
        width: CGFloat,
        weight: NSFont.Weight = .semibold
    ) -> NSFont {
        var size = maxSize
        while size > minSize {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            let measured = (string as NSString).size(withAttributes: [.font: font]).width
            if measured <= width { return font }
            size -= 0.5
        }
        return .monospacedDigitSystemFont(ofSize: minSize, weight: weight)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return value.formatted()
    }

    /// Digits only; unit lives in the subtitle so long values can shrink cleanly.
    private func formatRate(_ tps: Double) -> String {
        if tps < 0.2 {
            return "0"
        }
        if tps >= 100 {
            return String(format: "~%.0f", tps)
        }
        // One decimal so organic jitter is visible while hovering.
        return String(format: "~%.1f", tps)
    }
}
