// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

public enum AppAccessibilityIdentifier {
    public static let debuggerState = "debugger-state"
    public static let sourceLocationStatus = "source-location-status"
    public static let currentLineStatus = "current-line-status"
    public static let operationError = "operation-error"
}

@MainActor
public struct AccessibleStatusStrip: NSViewRepresentable {
    private let stateText: String
    private let currentLineText: String?
    private let sourceLocationText: String?
    private let operationErrorText: String?

    public init(
        stateText: String,
        currentLineText: String?,
        sourceLocationText: String?,
        operationErrorText: String?
    ) {
        self.stateText = stateText
        self.currentLineText = currentLineText
        self.sourceLocationText = sourceLocationText
        self.operationErrorText = operationErrorText
    }

    public func makeNSView(context: Context) -> StatusStackView {
        StatusStackView()
    }

    public func updateNSView(_ view: StatusStackView, context: Context) {
        view.update(
            stateText: stateText,
            currentLineText: currentLineText,
            sourceLocationText: sourceLocationText,
            operationErrorText: operationErrorText
        )
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: StatusStackView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.fittingSize.width,
            height: StatusStackView.preferredHeight
        )
    }
}

@MainActor
public final class StatusStackView: NSStackView {
    public static let preferredHeight: CGFloat = 30

    private let stateLabel = StatusItemView(
        identifier: AppAccessibilityIdentifier.debuggerState,
        emphasis: .state
    )
    private let currentLineLabel = StatusItemView(identifier: AppAccessibilityIdentifier.currentLineStatus)
    private let sourceLocationLabel = StatusItemView(identifier: AppAccessibilityIdentifier.sourceLocationStatus)
    private let operationErrorLabel = StatusItemView(
        identifier: AppAccessibilityIdentifier.operationError,
        emphasis: .error
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 14
        edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("构建与调试状态")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        operationErrorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addArrangedSubview(stateLabel)
        addArrangedSubview(currentLineLabel)
        addArrangedSubview(sourceLocationLabel)
        addArrangedSubview(spacer)
        addArrangedSubview(operationErrorLabel)
        setAccessibilityChildren([
            stateLabel,
            currentLineLabel,
            sourceLocationLabel,
            operationErrorLabel
        ])
        operationErrorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    public override var fittingSize: NSSize {
        var size = super.fittingSize
        size.height = Self.preferredHeight
        return size
    }

    fileprivate func update(
        stateText: String,
        currentLineText: String?,
        sourceLocationText: String?,
        operationErrorText: String?
    ) {
        stateLabel.update(text: stateText)
        currentLineLabel.update(text: currentLineText)
        sourceLocationLabel.update(text: sourceLocationText)
        operationErrorLabel.update(text: operationErrorText)
    }
}

@MainActor
private final class StatusItemView: NSView {
    enum Emphasis {
        case normal
        case state
        case error
    }

    private let statusIdentifier: String
    private let textField = NSTextField(labelWithString: "")

    init(identifier: String, emphasis: Emphasis = .normal) {
        statusIdentifier = identifier
        super.init(frame: .zero)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: emphasis == .state ? .semibold : .regular
        )
        textField.textColor = emphasis == .error ? .systemRed : .labelColor
        textField.setAccessibilityElement(false)
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)
        update(text: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        textField.intrinsicContentSize
    }

    fileprivate func update(text: String?) {
        let value = text ?? ""
        textField.stringValue = value
        invalidateIntrinsicContentSize()
        isHidden = text == nil
        setAccessibilityIdentifier(statusIdentifier)
        setAccessibilityLabel(value)
        setAccessibilityValue(value)
    }
}
