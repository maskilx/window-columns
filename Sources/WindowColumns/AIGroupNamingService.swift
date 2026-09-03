import Foundation

struct GroupNamingRequest: Sendable {
    let id: UUID
    let currentName: String
    let windows: [(appName: String, title: String)]
}

struct GroupNamingResult: Sendable {
    let suggestions: [UUID: String]
    let notice: String?
}

actor AIGroupNamingService {
    static let shared = AIGroupNamingService()

    func suggestNames(
        for groups: [GroupNamingRequest],
        apiKey: String?
    ) async -> GroupNamingResult {
        guard !groups.isEmpty else { return GroupNamingResult(suggestions: [:], notice: nil) }

        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            do {
                let suggestions = try await queryGemini(groups: groups, apiKey: apiKey)
                if !suggestions.isEmpty {
                    return GroupNamingResult(suggestions: suggestions, notice: "Generated with Gemini 2.0 Flash")
                }
            } catch {
                NSLog("[WindowColumns] Gemini AI naming failed: %@, falling back to local heuristic", error.localizedDescription)
                let localNames = generateHeuristicNames(for: groups)
                let shortError = error.localizedDescription.contains("400") || error.localizedDescription.contains("403")
                    ? "Invalid API key" : "Network error"
                return GroupNamingResult(suggestions: localNames, notice: "\(shortError) — used smart local suggestions.")
            }
        }

        // Fallback to local heuristic naming when no key is set
        let localNames = generateHeuristicNames(for: groups)
        return GroupNamingResult(suggestions: localNames, notice: "Local suggestions. Set a free Gemini key in Settings for AI.")
    }

    private func queryGemini(
        groups: [GroupNamingRequest],
        apiKey: String
    ) async throws -> [UUID: String] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
            throw URLError(.badURL)
        }

        var groupsDescription = ""
        for (index, group) in groups.enumerated() {
            let windowList = group.windows.map { win in
                let cleanTitle = win.title.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\"", with: "'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(win.appName) (\(cleanTitle.prefix(35)))"
            }.joined(separator: ", ")
            let safeWindows = windowList.isEmpty ? "General Workspace" : windowList
            groupsDescription += "Group \(index + 1) [ID: \(group.id.uuidString)] (Current: \"\(group.currentName)\"): \(safeWindows)\n"
        }

        let prompt = """
        You are an intelligent macOS workspace assistant.
        Given the following window groups and the windows in each group, suggest strictly a SINGLE WORD (1 word only, max 10 letters, capitalized) that best describes the workflow of each group (e.g., "Code", "Research", "Design", "Chat", "Terminal", "Web", "Music", "Notes", "Review").
        NEVER output more than one word. Output strictly 1 word per group.
        
        Return ONLY a JSON array with objects containing "id" and "name".
        Example:
        [{"id": "00000000-0000-0000-0000-000000000000", "name": "Code"}]

        Groups:
        \(groupsDescription)
        """

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "AIGroupNamingService", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }

        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        struct NameItem: Decodable {
            let id: String
            let name: String
        }

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = geminiResponse.candidates?.first?.content?.parts?.first?.text else {
            return [:]
        }

        var cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedText.hasPrefix("```json") {
            cleanedText = cleanedText.replacingOccurrences(of: "^```json\\s*", with: "", options: .regularExpression)
        }
        if cleanedText.hasPrefix("```") {
            cleanedText = cleanedText.replacingOccurrences(of: "^```\\s*", with: "", options: .regularExpression)
        }
        if cleanedText.hasSuffix("```") {
            cleanedText = cleanedText.replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }

        guard let jsonData = cleanedText.data(using: .utf8),
              let items = try? JSONDecoder().decode([NameItem].self, from: jsonData) else {
            return [:]
        }

        var result: [UUID: String] = [:]
        for item in items {
            if let uuid = UUID(uuidString: item.id) {
                // Strictly enforce a single word
                let words = item.name.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.,;:/\\&()[]")))
                    .filter { !$0.isEmpty }
                if let firstWord = words.first {
                    let cleaned = firstWord.trimmingCharacters(in: .punctuationCharacters)
                    if !cleaned.isEmpty {
                        let formatted = cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
                        result[uuid] = String(formatted.prefix(12))
                    }
                }
            }
        }
        return result
    }

    private func generateHeuristicNames(for groups: [GroupNamingRequest]) -> [UUID: String] {
        var result: [UUID: String] = [:]

        for group in groups {
            let appNames = group.windows.map { $0.appName.lowercased() }

            let isDev = appNames.contains { $0.contains("code") || $0.contains("xcode") || $0.contains("terminal") || $0.contains("warp") || $0.contains("iterm") || $0.contains("antigravity") }
            let isBrowser = appNames.contains { $0.contains("safari") || $0.contains("chrome") || $0.contains("brave") || $0.contains("edge") || $0.contains("arc") }
            let isComms = appNames.contains { $0.contains("slack") || $0.contains("discord") || $0.contains("teams") || $0.contains("mail") || $0.contains("messages") }
            let isDesign = appNames.contains { $0.contains("figma") || $0.contains("sketch") || $0.contains("illustrator") || $0.contains("photoshop") }
            let isNotes = appNames.contains { $0.contains("notes") || $0.contains("notion") || $0.contains("obsidian") || $0.contains("craft") }

            if isDev {
                result[group.id] = "Code"
            } else if isDesign {
                result[group.id] = "Design"
            } else if isComms {
                result[group.id] = "Chat"
            } else if isNotes {
                result[group.id] = "Notes"
            } else if isBrowser {
                result[group.id] = "Web"
            } else if let firstApp = group.windows.first?.appName {
                let cleanApp = firstApp.components(separatedBy: .whitespacesAndNewlines).first ?? firstApp
                result[group.id] = String(cleanApp.prefix(10))
            } else {
                result[group.id] = "Work"
            }
        }

        return result
    }
}
