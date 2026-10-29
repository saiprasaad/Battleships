import Foundation
import Testing
@testable import Battleships

// Foundation only (no UIKit or SwiftUI), so these also run in the Linux compile check.

/// Positions are floating point, so compare them with a little slack.
private func expectClose(
    _ value: Double,
    _ expected: Double,
    within tolerance: Double = 1e-9,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(value - expected) < tolerance, comment, sourceLocation: sourceLocation)
}

@Suite("Particles")
struct ParticleTests {
    /// One list from every emitter, so a rule can be checked against all of them.
    private var everyEmitter: [(name: String, particles: [Particle])] {
        [
            ("splash", Emitters.splash(seed: 11)),
            ("close splash", Emitters.splash(seed: 12, close: true)),
            ("detonation", Emitters.detonation(seed: 13)),
            ("secondary", Emitters.detonation(seed: 14, scale: 0.55, isPrimary: false)),
            ("smoke", Emitters.smoke(cell: 37, phase: 0.8, isTargetBoard: true)),
            ("boil", Emitters.boil(rect: SIMD4(-1.5, -0.5, 3, 1), seed: 15)),
            ("plunk", Emitters.plunk(rect: SIMD4(-1, -0.5, 2, 1), seed: 16)),
            ("wake", Emitters.wake(from: SIMD2(2, 3), heading: SIMD2(1, 0), seed: 17)),
            ("firework", Emitters.firework(seed: 18, launch: SIMD2(100, 400), apex: SIMD2(120, 120), shape: .chrysanthemum, count: 40)),
            ("surface rings", Emitters.surfaceRings(center: SIMD2(4, 4), seed: 19)),
        ]
    }

    @Test func theSameSeedAlwaysGivesTheSameBurst() {
        #expect(Emitters.splash(seed: 7) == Emitters.splash(seed: 7))
        #expect(Emitters.detonation(seed: 7) == Emitters.detonation(seed: 7))
        #expect(Emitters.boil(rect: SIMD4(0, 0, 2, 1), seed: 7) == Emitters.boil(rect: SIMD4(0, 0, 2, 1), seed: 7))
        #expect(
            Emitters.firework(seed: 7, launch: .zero, apex: SIMD2(0, -200), shape: .willow, count: 30)
                == Emitters.firework(seed: 7, launch: .zero, apex: SIMD2(0, -200), shape: .willow, count: 30)
        )
        #expect(Emitters.smoke(cell: 3, phase: 0.2, isTargetBoard: false) == Emitters.smoke(cell: 3, phase: 0.2, isTargetBoard: false))
    }

    @Test func differentSeedsGiveDifferentBursts() {
        #expect(Emitters.splash(seed: 7) != Emitters.splash(seed: 8))
        #expect(Emitters.detonation(seed: 7) != Emitters.detonation(seed: 8))
        #expect(Emitters.smoke(cell: 3, phase: 0, isTargetBoard: false) != Emitters.smoke(cell: 4, phase: 0, isTargetBoard: false))
    }

    @Test func theGeneratorReplays() {
        var first = SplitMix64(seed: 99)
        var second = SplitMix64(seed: 99)
        for _ in 0..<16 {
            #expect(first.next() == second.next())
        }
        var other = SplitMix64(seed: 100)
        #expect(first.next() != other.next())
    }

    @Test func emittersGiveTheCountsTheSpecNames() {
        let splash = Emitters.splash(seed: 1)
        #expect(splash.count == 23)
        #expect(splash.filter { $0.kind == .droplet }.count == 14)
        #expect(splash.filter { $0.kind == .ring }.count == 6)
        #expect(splash.filter { $0.kind == .foam }.count == 3)

        let detonation = Emitters.detonation(seed: 1)
        #expect(detonation.count == 42)
        #expect(detonation.filter { $0.kind == .spark }.count == 24)
        #expect(detonation.filter { $0.kind == .shard }.count == 5)
        #expect(detonation.filter { $0.kind == .ember }.count == 8)
        #expect(detonation.filter { $0.kind == .puff }.count == 5)
        let secondary = Emitters.detonation(seed: 1, scale: 0.55, isPrimary: false)
        #expect(secondary.count == 29, "no embers or smoke along a chain")
        #expect(!secondary.contains { $0.kind == .puff || $0.kind == .ember })

        #expect(Emitters.smoke(cell: 4, phase: 0.3, isTargetBoard: true).count == 12)
        let boil = Emitters.boil(rect: SIMD4(-1.5, -0.5, 3, 1), seed: 1)
        #expect(boil.filter { $0.kind == .bubble }.count == 18)
        #expect(boil.filter { $0.kind == .ring }.count == 3)
        let plunk = Emitters.plunk(rect: SIMD4(-1, -0.5, 2, 1), seed: 1)
        #expect(plunk.filter { $0.kind == .droplet }.count == 8)
        #expect(plunk.filter { $0.kind == .ring }.count == 3)
        #expect(Emitters.wake(from: .zero, heading: SIMD2(0, 1), seed: 1).count == 12)
        let firework = Emitters.firework(seed: 1, launch: .zero, apex: SIMD2(0, -200), shape: .peony, count: 36)
        #expect(firework.count == 37)
        #expect(firework.filter { $0.kind == .star }.count == 36)
        #expect(firework.first?.kind == .streak)
        #expect(Emitters.surfaceRings(center: .zero, seed: 1).count == 10)
    }

    @Test func noParticleOutlivesItsLife() {
        for (name, particles) in everyEmitter {
            #expect(!particles.isEmpty, "\(name)")
            for particle in particles {
                #expect(particle.life > 0, "\(name)")
                let birth = particle.delay
                let death = particle.delay + particle.life
                #expect(particle.age(at: birth - 0.001) == nil, "\(name): not born yet")
                #expect(particle.age(at: birth) == 0, "\(name): born")
                #expect(particle.age(at: death) == nil, "\(name): gone at the end of its life")
                #expect(particle.age(at: death + 10) == nil, "\(name)")
                #expect(particle.alpha(at: birth - 0.001) == 0, "\(name)")
                #expect(particle.alpha(at: death) == 0, "\(name)")
                #expect(particle.alpha(at: death + 10) == 0, "\(name)")
                #expect(particle.alpha(at: birth + particle.life / 2) > 0, "\(name): visible mid-life")
                #expect(particle.progress(at: death) == 1, "\(name)")
                #expect(particle.progress(at: birth) == 0, "\(name)")
            }
        }
    }

    @Test func aParticleWaitsAtItsOriginAndStaysWhereItDied() {
        let particle = Particle(
            origin: SIMD2(1, 2), velocity: SIMD2(3, 0), gravity: 10, drag: 0,
            delay: 0.5, life: 2, size: 0.1, spin: 0, tint: 0, kind: .spark
        )
        #expect(particle.position(at: 0) == SIMD2(1, 2))
        #expect(particle.position(at: 0.5) == SIMD2(1, 2))
        let afterASecond = particle.position(at: 1.5)
        expectClose(afterASecond.x, 4, "velocity carries it 3 units in a second")
        expectClose(afterASecond.y, 2 + 5, "gravity pulls it ½·10·1² down")
        let end = particle.position(at: 2.5)
        #expect(particle.position(at: 50) == end, "after its death it stays put")
    }

    @Test func dragLimitsHowFarAParticleTravels() {
        let dragged = Particle(
            origin: .zero, velocity: SIMD2(4, 0), gravity: 0, drag: 2,
            delay: 0, life: 30, size: 0.1, spin: 0, tint: 0, kind: .ember
        )
        var previous = dragged.position(at: 0).x
        for step in 1...30 {
            let x = dragged.position(at: Double(step) * 0.5).x
            #expect(x >= previous, "it never comes back")
            #expect(x < 4 / 2, "at most |velocity| / drag units out")
            previous = x
        }
        expectClose(dragged.position(at: 0.5).x, 4 * (1 - exp(-1)) / 2, within: 1e-9)
        #expect(dragged.position(at: 30).x > 1.99, "it all but reaches the limit")
    }

    @Test func splashDropletsFlyUpAndFallBackToTheWater() {
        let droplets = Emitters.splash(seed: 5).filter { $0.kind == .droplet }
        for droplet in droplets {
            let peak = droplet.position(at: droplet.delay + droplet.life / 2)
            #expect(peak.y < -0.1, "it goes up (y is downward)")
            let landing = droplet.position(at: droplet.delay + droplet.life)
            expectClose(landing.y, 0, within: 1e-6, "back on the water line when it dies")
            #expect(droplet.life > 0.35 && droplet.life < 0.95)
        }
        let rings = Emitters.splash(seed: 5).filter { $0.kind == .ring }
        for ring in rings {
            #expect(ring.delay > 0.35 && ring.delay < 1, "a ring where a droplet lands")
            #expect(ring.origin.y == 0)
        }
    }

    @Test func ringsGrowAndFadeAndPuffsSwell() {
        let ring = Emitters.splash(seed: 2).first { $0.kind == .foam }!
        let young = ring.delay + 0.05
        let old = ring.delay + ring.life - 0.05
        #expect(ring.scale(at: young) < ring.scale(at: old))
        #expect(ring.alpha(at: young) > ring.alpha(at: old))
        let puff = Emitters.detonation(seed: 2).first { $0.kind == .puff }!
        #expect(puff.scale(at: puff.delay) == 1)
        #expect(puff.scale(at: puff.delay + puff.life) > 2)
        let spark = Emitters.detonation(seed: 2).first { $0.kind == .spark }!
        #expect(spark.scale(at: spark.delay + spark.life) < spark.scale(at: spark.delay))
    }

    @Test func smokeLoopsSeamlessly() {
        let puffs = Emitters.smoke(cell: 2, phase: 0.7, isTargetBoard: false)
        let period = Emitters.smokePeriod
        for step in 0..<48 {
            let time = period + Double(step) / 48 * period
            #expect(puffs.filter { $0.age(at: time) != nil }.count == 6, "six puffs alive at \(time)")
        }
        // The second loop is the first again, one period later.
        for index in 0..<6 {
            var again = puffs[index]
            again.delay += period
            #expect(puffs[index + 6] == again)
        }
        // Target-board smoke stays within its cell: it rises less and sways less.
        let clipped = Emitters.smoke(cell: 2, phase: 0, isTargetBoard: true)
        for puff in clipped {
            let end = puff.position(at: puff.delay + puff.life)
            #expect(abs(end.x) < 0.5)
            #expect(end.y > -0.5)
        }
    }

    @Test func aFireworkRisesThenBursts() {
        let launch = SIMD2<Double>(100, 400)
        let apex = SIMD2<Double>(120, 120)
        let firework = Emitters.firework(seed: 9, launch: launch, apex: apex, shape: .peony, count: 20)
        let rocket = firework[0]
        #expect(rocket.position(at: 0) == launch)
        let top = rocket.position(at: rocket.life)
        expectClose(top.x, apex.x, within: 1e-6)
        expectClose(top.y, apex.y, within: 1e-6)
        for star in firework.dropFirst() {
            #expect(star.delay == rocket.life, "the stars are born when the rocket dies")
            #expect(star.position(at: 0) == apex)
            #expect(abs(star.tint - rocket.tint) <= 0.05 + 1e-9, "one hue per shell")
        }
        let willow = Emitters.firework(seed: 9, launch: launch, apex: apex, shape: .willow, count: 20)
        #expect(willow[1].gravity > firework[1].gravity, "willow stars droop")
    }

    @Test func surfaceRingsAreStaggered() {
        let rings = Emitters.surfaceRings(center: SIMD2(3, 3), seed: 4).filter { $0.kind == .ring }
        #expect(rings.count == 4)
        for (index, ring) in rings.enumerated() {
            expectClose(ring.delay, Double(index) * Timing.Stagger.surfacing)
            #expect(ring.origin == SIMD2(3, 3))
        }
    }
}
