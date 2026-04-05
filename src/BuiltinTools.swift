import Foundation

// ---------------------------------------------------------------------------
// Tool definition shared between built-ins and MCP
// ---------------------------------------------------------------------------

struct ToolDefinition: Encodable {
    struct Parameter: Encodable {
        let type: String
        let description: String
        let `enum`: [String]?
        init(type: String, description: String, enum: [String]? = nil) {
            self.type = type
            self.description = description
            self.enum = `enum`
        }
    }
    struct Parameters: Encodable {
        let type = "object"
        let properties: [String: Parameter]
        let required: [String]
    }
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters
    }
    let type = "function"
    let function: Function
}

// ---------------------------------------------------------------------------
// Built-in tools
// ---------------------------------------------------------------------------

@MainActor
protocol BuiltinTool {
    var definition: ToolDefinition { get }
    func execute(arguments: [String: Any]) async throws -> String
}

// MARK: - DateTime

struct DateTimeTool: BuiltinTool {
    let definition = ToolDefinition(
        function: .init(
            name: "get_current_datetime",
            description: "Returns the current date, time, and timezone on the user's device.",
            parameters: .init(properties: [:], required: [])
        )
    )

    func execute(arguments: [String: Any]) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: Date())
    }
}

// MARK: - Weather (Open-Meteo, no API key required)

struct WeatherTool: BuiltinTool {
    let definition = ToolDefinition(
        function: .init(
            name: "get_weather",
            description: "Get current weather conditions for any city or location. Returns temperature, conditions, humidity and wind speed.",
            parameters: .init(
                properties: [
                    "location": .init(type: "string", description: "City name, e.g. 'Lisbon' or 'New York'")
                ],
                required: ["location"]
            )
        )
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let location = arguments["location"] as? String else {
            throw ToolError.missingArgument("location")
        }

        // Step 1: geocode location → lat/lon via Open-Meteo geocoding
        let geoQuery = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? location
        let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(geoQuery)&count=1&language=en&format=json")!
        let (geoData, _) = try await URLSession.shared.data(from: geoURL)

        struct GeoResponse: Decodable {
            struct Result: Decodable {
                let name: String
                let country: String?
                let latitude: Double
                let longitude: Double
            }
            let results: [Result]?
        }
        guard let geo = try? JSONDecoder().decode(GeoResponse.self, from: geoData),
              let place = geo.results?.first else {
            return "Could not find location '\(location)'."
        }

        // Step 2: fetch weather
        let weatherURL = URL(string:
            "https://api.open-meteo.com/v1/forecast" +
            "?latitude=\(place.latitude)&longitude=\(place.longitude)" +
            "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m" +
            "&temperature_unit=celsius&wind_speed_unit=kmh&timezone=auto"
        )!
        let (weatherData, _) = try await URLSession.shared.data(from: weatherURL)

        struct WeatherResponse: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let relative_humidity_2m: Int
                let weather_code: Int
                let wind_speed_10m: Double
            }
            let current: Current
        }
        guard let weather = try? JSONDecoder().decode(WeatherResponse.self, from: weatherData) else {
            return "Failed to fetch weather data."
        }

        let c = weather.current
        let condition = wmoDescription(c.weather_code)
        let country = place.country.map { ", \($0)" } ?? ""
        return """
        Weather in \(place.name)\(country):
        • Condition: \(condition)
        • Temperature: \(c.temperature_2m)°C
        • Humidity: \(c.relative_humidity_2m)%
        • Wind: \(c.wind_speed_10m) km/h
        """
    }

    // WMO Weather Code → human description
    private func wmoDescription(_ code: Int) -> String {
        switch code {
        case 0:        return "Clear sky"
        case 1:        return "Mainly clear"
        case 2:        return "Partly cloudy"
        case 3:        return "Overcast"
        case 45, 48:   return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 71, 73, 75: return "Snow"
        case 80, 81, 82: return "Rain showers"
        case 95:       return "Thunderstorm"
        case 96, 99:   return "Thunderstorm with hail"
        default:       return "Unknown (code \(code))"
        }
    }
}

enum ToolError: LocalizedError {
    case missingArgument(String)
    var errorDescription: String? {
        switch self { case .missingArgument(let a): return "Missing required argument: \(a)" }
    }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

@MainActor
final class BuiltinToolRegistry {
    static let shared = BuiltinToolRegistry()
    private let tools: [String: any BuiltinTool] = {
        let list: [any BuiltinTool] = [DateTimeTool(), WeatherTool()]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.definition.function.name, $0) })
    }()

    var definitions: [ToolDefinition] { Array(tools.values.map(\.definition)) }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard let tool = tools[name] else {
            throw ToolError.missingArgument("No built-in tool named '\(name)'")
        }
        return try await tool.execute(arguments: arguments)
    }

    func canHandle(_ name: String) -> Bool { tools[name] != nil }
}
