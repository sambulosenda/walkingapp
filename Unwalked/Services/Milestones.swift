import Foundation

/// Something worth marking: a street walked end to end, a share of the area covered, a distance reached.
struct Milestone: Identifiable, Hashable {
    var id: String
    var symbol: String
    var title: String
}

/// Milestones are worked out from what has been walked, never stored: there is nothing to migrate,
/// and deleting walks takes them away again.
enum Milestones {
    static let streetSteps = [1, 5, 10, 25, 50, 100, 250, 500]
    static let coverageSteps = [5, 10, 25, 50, 75, 100]
    static let kmSteps = [10, 25, 50, 100, 250, 500, 1000]

    static func earned(streets: Int, coverage: Double, km: Double) -> [Milestone] {
        var out: [Milestone] = []
        for step in streetSteps where streets >= step {
            out.append(Milestone(id: "streets-\(step)", symbol: "signpost.right",
                                 title: step == 1 ? "Your first whole street" : "\(step) streets walked end to end"))
        }
        for step in coverageSteps where Int((coverage * 100).rounded(.down)) >= step {
            out.append(Milestone(id: "coverage-\(step)", symbol: "map",
                                 title: step == 100 ? "Every street in your area" : "\(step)% of your area walked"))
        }
        for step in kmSteps where km >= Double(step) {
            out.append(Milestone(id: "km-\(step)", symbol: "figure.walk", title: "\(step) km walked"))
        }
        return out
    }

    /// What is nearest to being earned, one line for each kind.
    static func next(streets: Int, coverage: Double, km: Double) -> [String] {
        var out: [String] = []
        if let step = streetSteps.first(where: { $0 > streets }) {
            let left = step - streets
            out.append(step == 1 ? "Walk one street end to end"
                       : "\(left) more whole \(left == 1 ? "street" : "streets") to reach \(step)")
        }
        if let step = coverageSteps.first(where: { $0 > Int((coverage * 100).rounded(.down)) }) {
            out.append("\(step)% of your area is next")
        }
        if let step = kmSteps.first(where: { Double($0) > km }) {
            out.append(String(format: "%.1f km to go to %d km", Double(step) - km, step))
        }
        return out
    }
}
