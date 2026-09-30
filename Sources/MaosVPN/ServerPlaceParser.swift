import Foundation
import MaosVPNCore

enum ServerPlaceParser {
    struct Place {
        let flag: String
        let title: String
        let city: String
    }

    private struct Country {
        let iso: String
        let english: String
        let russian: String
        let aliases: [String]
        let cities: [(alias: String, english: String, russian: String)]
    }

    private static var cache: [String: Place] = [:]
    private static let noise: Set<String> = [
        "vless", "vmess", "trojan", "ss", "shadowsocks", "hysteria", "hysteria2",
        "tcp", "udp", "ws", "grpc", "reality", "tls", "xtls", "vpn", "vip", "premium", "plus"
    ]

    static func clearCache() { cache.removeAll(keepingCapacity: true) }

    static func parse(_ name: String) -> Place {
        let key = (AppLanguage.current == .russian ? "r\u{1e}" : "e\u{1e}") + name
        if let cached = cache[key] { return cached }
        let place = resolve(name)
        if cache.count > 1500 { cache.removeAll(keepingCapacity: true) }
        cache[key] = place
        return place
    }

    private static func resolve(_ name: String) -> Place {
        let stripped = stripFlag(name)
        var countryMatch: (Country, Range<String.Index>, Int)?
        var cityMatch: (String, String, Country, Range<String.Index>, Int)?
        for country in countries {
            for alias in country.aliases {
                guard let range = rangeOfAlias(alias, in: stripped.rest) else { continue }
                let length = rangeLength(range, in: stripped.rest)
                if countryMatch == nil || length > countryMatch!.2 {
                    countryMatch = (country, range, length)
                }
            }
            for city in country.cities {
                guard let range = rangeOfAlias(city.alias, in: stripped.rest) else { continue }
                let length = rangeLength(range, in: stripped.rest)
                if cityMatch == nil || length > cityMatch!.4 {
                    cityMatch = (city.english, city.russian, country, range, length)
                }
            }
        }

        let resolvedCountry = countryMatch?.0 ?? cityMatch?.2
        guard let resolvedCountry = resolvedCountry else {
            let title = cleanup(stripped.rest)
            return Place(flag: stripped.flag ?? "🌐", title: title.isEmpty ? name : title, city: "")
        }

        let matchingCity: (String, String, Country, Range<String.Index>, Int)? = {
            guard let cityMatch = cityMatch else { return nil }
            if let countryMatch = countryMatch, cityMatch.2.iso != countryMatch.0.iso { return nil }
            return cityMatch
        }()
        var ranges: [Range<String.Index>] = []
        if let countryMatch = countryMatch { ranges.append(countryMatch.1) }
        if let matchingCity = matchingCity { ranges.append(matchingCity.3) }
        let extra = prettifyLeftover(removing(ranges, from: stripped.rest))
        let russian = AppLanguage.current == .russian
        let title = russian ? resolvedCountry.russian : resolvedCountry.english
        var city = ""
        if let matchingCity = matchingCity {
            city = russian ? matchingCity.1 : matchingCity.0
            if !extra.isEmpty, extra.count <= 12, !city.localizedCaseInsensitiveContains(extra) {
                city += " " + extra
            }
        } else if extra.count <= 22 {
            city = extra
        }
        return Place(flag: flag(iso: resolvedCountry.iso), title: title, city: city)
    }

    private static func rangeLength(_ range: Range<String.Index>, in text: String) -> Int {
        text.distance(from: range.lowerBound, to: range.upperBound)
    }

    private static func stripFlag(_ text: String) -> (flag: String?, rest: String) {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2 else { return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let first = scalars[0].value
        let second = scalars[1].value
        guard (0x1F1E6...0x1F1FF).contains(first), (0x1F1E6...0x1F1FF).contains(second) else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let flag = string(from: scalars.prefix(2))
        let rest = string(from: scalars.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (flag, rest)
    }

    private static func rangeOfAlias(_ alias: String, in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while start < text.endIndex {
            guard let found = text.range(of: alias, options: [.caseInsensitive], range: start..<text.endIndex) else { break }
            let beforeOK = found.lowerBound == text.startIndex || !isNameLetter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex || !isNameLetter(text[found.upperBound])
            if beforeOK && afterOK { return found }
            start = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func isNameLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func removing(_ ranges: [Range<String.Index>], from text: String) -> String {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for range in sorted {
            if range.lowerBound < cursor { continue }
            result.append(contentsOf: text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func prettifyLeftover(_ raw: String) -> String {
        let parts = raw.split { character in
            character.isWhitespace || "-_|·•,/()[]{}#:+".contains(character)
        }.map(String.init)
        let kept = parts.filter { part in
            let token = part.lowercased()
            return !noise.contains(token) && token != "server" && token != "node" && part.count <= 24
        }
        return kept.joined(separator: " ")
    }

    private static func cleanup(_ raw: String) -> String {
        prettifyLeftover(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flag(iso: String) -> String {
        var scalars: [UnicodeScalar] = []
        for scalar in iso.uppercased().unicodeScalars {
            let value = scalar.value
            guard value >= 65, value <= 90, let flag = UnicodeScalar(0x1F1E6 + value - 65) else { return "🌐" }
            scalars.append(flag)
        }
        return string(from: scalars[...])
    }

    private static func string(from scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static let countries: [Country] = [
        Country(iso: "US", english: "United States", russian: "США", aliases: ["united states", "usa", "america", "сша", "америка"], cities: [
            ("new york", "New York", "Нью-Йорк"), ("los angeles", "Los Angeles", "Лос-Анджелес"),
            ("chicago", "Chicago", "Чикаго"), ("miami", "Miami", "Майами"), ("seattle", "Seattle", "Сиэтл"),
            ("dallas", "Dallas", "Даллас"), ("ashburn", "Ashburn", "Ашберн"), ("san jose", "San Jose", "Сан-Хосе"),
            ("atlanta", "Atlanta", "Атланта"), ("denver", "Denver", "Денвер"), ("boston", "Boston", "Бостон")
        ]),
        Country(iso: "GB", english: "United Kingdom", russian: "Великобритания", aliases: ["united kingdom", "great britain", "britain", "england", "uk", "великобритания", "англия"], cities: [
            ("london", "London", "Лондон"), ("manchester", "Manchester", "Манчестер")
        ]),
        Country(iso: "NL", english: "Netherlands", russian: "Нидерланды", aliases: ["netherlands", "holland", "нидерланды", "голландия", "nl"], cities: [
            ("amsterdam", "Amsterdam", "Амстердам"), ("rotterdam", "Rotterdam", "Роттердам")
        ]),
        Country(iso: "DE", english: "Germany", russian: "Германия", aliases: ["germany", "deutschland", "германия", "de"], cities: [
            ("frankfurt", "Frankfurt", "Франкфурт"), ("berlin", "Berlin", "Берлин"), ("munich", "Munich", "Мюнхен"), ("falkenstein", "Falkenstein", "Фалькенштайн")
        ]),
        Country(iso: "SG", english: "Singapore", russian: "Сингапур", aliases: ["singapore", "сингапур", "sg"], cities: [
            ("singapore", "Singapore", "Сингапур")
        ]),
        Country(iso: "CA", english: "Canada", russian: "Канада", aliases: ["canada", "канада", "ca"], cities: [
            ("toronto", "Toronto", "Торонто"), ("montreal", "Montreal", "Монреаль"), ("vancouver", "Vancouver", "Ванкувер")
        ]),
        Country(iso: "FR", english: "France", russian: "Франция", aliases: ["france", "франция", "fr"], cities: [
            ("paris", "Paris", "Париж"), ("marseille", "Marseille", "Марсель")
        ]),
        Country(iso: "JP", english: "Japan", russian: "Япония", aliases: ["japan", "япония", "jp"], cities: [
            ("tokyo", "Tokyo", "Токио"), ("osaka", "Osaka", "Осака")
        ]),
        Country(iso: "AU", english: "Australia", russian: "Австралия", aliases: ["australia", "австралия", "au"], cities: [
            ("sydney", "Sydney", "Сидней"), ("melbourne", "Melbourne", "Мельбурн")
        ]),
        Country(iso: "KR", english: "South Korea", russian: "Корея", aliases: ["south korea", "korea", "корея", "kr"], cities: [
            ("seoul", "Seoul", "Сеул")
        ]),
        Country(iso: "HK", english: "Hong Kong", russian: "Гонконг", aliases: ["hong kong", "hongkong", "гонконг", "hk"], cities: []),
        Country(iso: "TW", english: "Taiwan", russian: "Тайвань", aliases: ["taiwan", "тайвань", "tw"], cities: [
            ("taipei", "Taipei", "Тайбэй")
        ]),
        Country(iso: "SE", english: "Sweden", russian: "Швеция", aliases: ["sweden", "швеция", "se"], cities: [
            ("stockholm", "Stockholm", "Стокгольм")
        ]),
        Country(iso: "NO", english: "Norway", russian: "Норвегия", aliases: ["norway", "норвегия"], cities: [
            ("oslo", "Oslo", "Осло")
        ]),
        Country(iso: "FI", english: "Finland", russian: "Финляндия", aliases: ["finland", "финляндия", "fi"], cities: [
            ("helsinki", "Helsinki", "Хельсинки")
        ]),
        Country(iso: "CH", english: "Switzerland", russian: "Швейцария", aliases: ["switzerland", "швейцария", "ch"], cities: [
            ("zurich", "Zurich", "Цюрих")
        ]),
        Country(iso: "AT", english: "Austria", russian: "Австрия", aliases: ["austria", "австрия"], cities: [
            ("vienna", "Vienna", "Вена")
        ]),
        Country(iso: "IT", english: "Italy", russian: "Италия", aliases: ["italy", "италия"], cities: [
            ("milan", "Milan", "Милан"), ("rome", "Rome", "Рим")
        ]),
        Country(iso: "ES", english: "Spain", russian: "Испания", aliases: ["spain", "испания"], cities: [
            ("madrid", "Madrid", "Мадрид"), ("barcelona", "Barcelona", "Барселона")
        ]),
        Country(iso: "PL", english: "Poland", russian: "Польша", aliases: ["poland", "польша", "pl"], cities: [
            ("warsaw", "Warsaw", "Варшава")
        ]),
        Country(iso: "TR", english: "Turkey", russian: "Турция", aliases: ["turkey", "turkiye", "türkiye", "турция", "tr"], cities: [
            ("istanbul", "Istanbul", "Стамбул")
        ]),
        Country(iso: "AE", english: "United Arab Emirates", russian: "ОАЭ", aliases: ["united arab emirates", "uae", "оаэ", "ae"], cities: [
            ("dubai", "Dubai", "Дубай")
        ]),
        Country(iso: "IN", english: "India", russian: "Индия", aliases: ["india", "индия"], cities: [
            ("mumbai", "Mumbai", "Мумбаи"), ("delhi", "Delhi", "Дели")
        ]),
        Country(iso: "BR", english: "Brazil", russian: "Бразилия", aliases: ["brazil", "бразилия", "br"], cities: [
            ("sao paulo", "Sao Paulo", "Сан-Паулу")
        ]),
        Country(iso: "UA", english: "Ukraine", russian: "Украина", aliases: ["ukraine", "украина", "ua"], cities: [
            ("kyiv", "Kyiv", "Киев"), ("kiev", "Kyiv", "Киев")
        ]),
        Country(iso: "KZ", english: "Kazakhstan", russian: "Казахстан", aliases: ["kazakhstan", "казахстан", "kz"], cities: [
            ("almaty", "Almaty", "Алматы")
        ]),
        Country(iso: "RU", english: "Russia", russian: "Россия", aliases: ["russia", "россия", "ru"], cities: [
            ("moscow", "Moscow", "Москва"), ("москва", "Moscow", "Москва")
        ]),
        Country(iso: "IL", english: "Israel", russian: "Израиль", aliases: ["israel", "израиль"], cities: [
            ("tel aviv", "Tel Aviv", "Тель-Авив")
        ]),
        Country(iso: "ID", english: "Indonesia", russian: "Индонезия", aliases: ["indonesia", "индонезия"], cities: [
            ("jakarta", "Jakarta", "Джакарта")
        ]),
        Country(iso: "TH", english: "Thailand", russian: "Таиланд", aliases: ["thailand", "таиланд"], cities: [
            ("bangkok", "Bangkok", "Бангкок")
        ]),
        Country(iso: "VN", english: "Vietnam", russian: "Вьетнам", aliases: ["vietnam", "вьетнам"], cities: [
            ("hanoi", "Hanoi", "Ханой")
        ]),
        Country(iso: "PH", english: "Philippines", russian: "Филиппины", aliases: ["philippines", "филиппины"], cities: [
            ("manila", "Manila", "Манила")
        ]),
        Country(iso: "MY", english: "Malaysia", russian: "Малайзия", aliases: ["malaysia", "малайзия"], cities: [
            ("kuala lumpur", "Kuala Lumpur", "Куала-Лумпур")
        ]),
        Country(iso: "AR", english: "Argentina", russian: "Аргентина", aliases: ["argentina", "аргентина"], cities: [
            ("buenos aires", "Buenos Aires", "Буэнос-Айрес")
        ]),
        Country(iso: "MX", english: "Mexico", russian: "Мексика", aliases: ["mexico", "мексика"], cities: []),
        Country(iso: "ZA", english: "South Africa", russian: "ЮАР", aliases: ["south africa", "юар"], cities: [
            ("johannesburg", "Johannesburg", "Йоханнесбург")
        ]),
        Country(iso: "EG", english: "Egypt", russian: "Египет", aliases: ["egypt", "египет"], cities: []),
        Country(iso: "CZ", english: "Czechia", russian: "Чехия", aliases: ["czechia", "czech republic", "czech", "чехия"], cities: [
            ("prague", "Prague", "Прага")
        ]),
        Country(iso: "RO", english: "Romania", russian: "Румыния", aliases: ["romania", "румыния"], cities: [
            ("bucharest", "Bucharest", "Бухарест")
        ]),
        Country(iso: "BG", english: "Bulgaria", russian: "Болгария", aliases: ["bulgaria", "болгария"], cities: [
            ("sofia", "Sofia", "София")
        ]),
        Country(iso: "HU", english: "Hungary", russian: "Венгрия", aliases: ["hungary", "венгрия"], cities: []),
        Country(iso: "IE", english: "Ireland", russian: "Ирландия", aliases: ["ireland", "ирландия"], cities: []),
        Country(iso: "LU", english: "Luxembourg", russian: "Люксембург", aliases: ["luxembourg", "люксембург"], cities: []),
        Country(iso: "DK", english: "Denmark", russian: "Дания", aliases: ["denmark", "дания"], cities: []),
        Country(iso: "PT", english: "Portugal", russian: "Португалия", aliases: ["portugal", "португалия"], cities: [
            ("lisbon", "Lisbon", "Лиссабон")
        ]),
        Country(iso: "GR", english: "Greece", russian: "Греция", aliases: ["greece", "греция"], cities: []),
        Country(iso: "RS", english: "Serbia", russian: "Сербия", aliases: ["serbia", "сербия"], cities: []),
        Country(iso: "LT", english: "Lithuania", russian: "Литва", aliases: ["lithuania", "литва"], cities: []),
        Country(iso: "LV", english: "Latvia", russian: "Латвия", aliases: ["latvia", "латвия"], cities: []),
        Country(iso: "EE", english: "Estonia", russian: "Эстония", aliases: ["estonia", "эстония"], cities: []),
        Country(iso: "MD", english: "Moldova", russian: "Молдова", aliases: ["moldova", "молдова"], cities: []),
        Country(iso: "GE", english: "Georgia", russian: "Грузия", aliases: ["georgia", "грузия"], cities: []),
        Country(iso: "AM", english: "Armenia", russian: "Армения", aliases: ["armenia", "армения"], cities: []),
        Country(iso: "BY", english: "Belarus", russian: "Беларусь", aliases: ["belarus", "беларусь"], cities: []),
        Country(iso: "CN", english: "China", russian: "Китай", aliases: ["china", "китай"], cities: []),
        Country(iso: "NZ", english: "New Zealand", russian: "Новая Зеландия", aliases: ["new zealand", "новая зеландия"], cities: []),
        Country(iso: "BE", english: "Belgium", russian: "Бельгия", aliases: ["belgium", "бельгия"], cities: []),
        Country(iso: "IS", english: "Iceland", russian: "Исландия", aliases: ["iceland", "исландия"], cities: [])
    ]
}
