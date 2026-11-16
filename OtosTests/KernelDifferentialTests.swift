import Foundation
@testable import OtosKit
import Testing

/// Assignment's kernel against the one it replaced (`ReferenceAssignment`, the dense kernel
/// measured on the owner's labelled faces): on generated libraries with every complication —
/// children across years, adults, birthdays, rejections, shared photos, undated faces, held
/// faces, people found among strangers — both give the same guesses, the same new people and
/// the same lapsed seeds, and likenesses within the precision a likeness is written at.
struct KernelDifferentialTests {
    @Test func theKernelGivesTheReferenceAssignment() {
        for (count, people, seed) in [(400, 5, UInt64(11)), (3000, 12, 23), (2500, 40, 31)] {
            var generator = SplitMix64(seed: seed)
            let faces = FaceAssignmentPolicyTests.randomFaces(count: count, people: people, generator: &generator)
            let facts = (1 ... people).map { index in
                PersonFact(
                    id: PersonID(rawValue: Int64(index)),
                    birthdaySeconds: index % 3 == 0 ? FaceAssignmentPolicyTests.epoch + Double(index) * FaceAssignmentPolicyTests.year : nil,
                    isBare: index % 4 == 0
                )
            }
            let differences = Self.differences(faces: faces, people: facts)
            #expect(differences.isEmpty, "\(count) faces, \(people) people: \(differences)")
        }
    }

    /// A family archive's shape at a tenth of it, and a cold start where nobody is named.
    @Test func theKernelGivesTheReferenceAssignmentOnAnArchive() {
        let (faces, people) = BenchmarkTests.groupingLibrary(faces: 6000, people: 20, confirmedEach: 30)
        #expect(Self.differences(faces: faces, people: people).isEmpty)
        let cold = faces.map {
            FaceFact(id: $0.id, captureSeconds: $0.captureSeconds, embedding: $0.embedding, assignment: .open, rejected: [])
        }
        #expect(Self.differences(faces: cold, people: []).isEmpty)
    }

    /// What the two kernels decided differently; empty when they agree.
    static func differences(faces: [FaceFact], people: [PersonFact]) -> [String] {
        let new = FaceAssignmentPolicy.assign(faces: faces, people: people)
        let old = ReferenceAssignment.assign(faces: faces, people: people)
        var differences: [String] = []
        if new.guesses != old.guesses {
            differences.append("guesses: \(new.guesses.count) and \(old.guesses.count), \(new.guesses.filter { old.guesses[$0.key] != $0.value }.count) differ")
        }
        if new.newPeople != old.newPeople {
            differences.append("new people: \(new.newPeople.count) and \(old.newPeople.count)")
        }
        if new.lapsedSeeds != old.lapsedSeeds {
            differences.append("lapsed seeds")
        }
        let moved = old.likeness.filter { abs($0.value - (new.likeness[$0.key] ?? .infinity)) > FaceAssignmentPlan.likenessPrecision }
        if !moved.isEmpty || new.likeness.count != old.likeness.count {
            differences.append("likeness: \(moved.count) moved")
        }
        if old.guesses.isEmpty, old.newPeople.isEmpty {
            differences.append("the fixture decided nothing")
        }
        return differences
    }
}
