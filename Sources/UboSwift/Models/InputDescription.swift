import Foundation

/// Field types supported by `WebUIInputDescription`. Mirrors
/// `ubo_app.store.input.types.InputFieldType`.
public enum InputFieldType: String, Sendable, CaseIterable {
    case long
    case text
    case password
    case number
    case checkbox
    case color
    case select
    case file
    case date
    case time

    public init(protoValue: Int) {
        switch protoValue {
        case 1: self = .long
        case 2: self = .text
        case 3: self = .password
        case 4: self = .number
        case 5: self = .checkbox
        case 6: self = .color
        case 7: self = .select
        case 8: self = .file
        case 9: self = .date
        case 10: self = .time
        default: self = .text
        }
    }
}

/// One field of a multi-field web/native input form.
public struct InputFieldDescription: Sendable, Identifiable, Hashable {
    public var name: String
    public var label: String
    public var type: InputFieldType
    public var description: String?
    public var title: String?
    public var fileMimetype: String?
    public var pattern: String?
    public var defaultValue: String?
    public var options: [String]
    public var required: Bool

    public var id: String { name }

    public init(
        name: String,
        label: String,
        type: InputFieldType,
        description: String? = nil,
        title: String? = nil,
        fileMimetype: String? = nil,
        pattern: String? = nil,
        defaultValue: String? = nil,
        options: [String] = [],
        required: Bool = false
    ) {
        self.name = name
        self.label = label
        self.type = type
        self.description = description
        self.title = title
        self.fileMimetype = fileMimetype
        self.pattern = pattern
        self.defaultValue = defaultValue
        self.options = options
        self.required = required
    }
}

/// A pending input demand of `input_method == WEB_DASHBOARD`. Each entry in
/// `state.web_ui.active_inputs` becomes one of these on the wire and one
/// dialog/sheet on the client.
public struct WebUIInputDescription: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String?
    public var prompt: String?
    public var fields: [InputFieldDescription]

    public init(
        id: String,
        title: String? = nil,
        prompt: String? = nil,
        fields: [InputFieldDescription] = []
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.fields = fields
    }
}
