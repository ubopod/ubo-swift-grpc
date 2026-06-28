//
//  UboStackItem.swift
//  UboSwift
//
//  One entry in the device's navigation stack, reduced to what a breadcrumb
//  needs: a stable id and a display label. Mirrors the Web UI's
//  `getStackItemLabel` derivation so desktop/TV clients can render the same
//  "Home › … › Current" trail.
//

import Foundation

public struct UboStackItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
