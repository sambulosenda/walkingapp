import Foundation

/// Sunrise and sunset, so Unwalked can switch to its After dark look and wording.
/// NOAA's simplified solar position formula; good to a few minutes.
enum SunClock {
    static func isDark(at date: Date = .now, lat: Double, lon: Double) -> Bool {
        guard let (rise, set) = sunriseSunset(on: date, lat: lat, lon: lon) else {
            // Polar day or night: fall back to the clock.
            let hour = Calendar.current.component(.hour, from: date)
            return hour < 6 || hour >= 20
        }
        return date < rise || date > set
    }

    static func sunriseSunset(on date: Date, lat: Double, lon: Double) -> (Date, Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        let n = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let γ = 2 * .pi / 365 * (n - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(γ) - 0.032077 * sin(γ) - 0.014615 * cos(2 * γ) - 0.040849 * sin(2 * γ))
        let decl = 0.006918 - 0.399912 * cos(γ) + 0.070257 * sin(γ) - 0.006758 * cos(2 * γ)
            + 0.000907 * sin(2 * γ) - 0.002697 * cos(3 * γ) + 0.00148 * sin(3 * γ)
        let φ = lat * .pi / 180
        let cosH = cos(90.833 * .pi / 180) / (cos(φ) * cos(decl)) - tan(φ) * tan(decl)
        guard cosH >= -1, cosH <= 1 else { return nil }
        let ha = acos(cosH) * 180 / .pi
        let riseMin = 720 - 4 * (lon + ha) - eqTime
        let setMin = 720 - 4 * (lon - ha) - eqTime
        return (dayStart.addingTimeInterval(riseMin * 60), dayStart.addingTimeInterval(setMin * 60))
    }
}
