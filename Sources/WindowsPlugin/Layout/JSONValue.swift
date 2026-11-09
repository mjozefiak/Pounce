import Foundation

/// Conversions between a typed record and the JSON kept as it came (`JSONValue` is defined with the layout
/// document). `state.json` keeps the state of every layout kind this way: a strategy decodes its own part, and a
/// part written by a kind this build does not know is kept as it is.
extension JSONValue {
    /// The JSON form of an encodable value, or `nil` when it cannot be encoded.
    init?<Value: Encodable>(encoding value: Value) {
        guard let data = try? JSONEncoder().encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        self = json
    }

    /// The value of type `Value` this JSON describes, or `nil` when it does not decode.
    func decoded<Value: Decodable>(as type: Value.Type) -> Value? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
