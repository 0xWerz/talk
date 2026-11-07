import Foundation

struct HistoryEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let date: Date
    let audioSeconds: Double
    let milliseconds: Int
}

/// Dictations saved to disk, so a missed paste or a restart never loses one.
enum HistoryStore {
    static let limit = 500

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: Paths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try data.write(to: Paths.history, options: [.atomic])
        } catch {
            Log.error("history", "could not save: \(error.localizedDescription)")
        }
    }
}
