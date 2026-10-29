import SwiftUI

/// Draws a seeded particle list (`Particle`, `Emitters` in Model/Particles.swift) into a Canvas:
/// `elapsed` seconds into its effect, `unit` points per particle unit (a cell on a board, 1 in a
/// scene), with the particles' origin at `center`. Sparks, embers and stars are added as light in one
/// `plusLighter` layer, puffs of smoke are softened through one blurred layer, and everything else is
/// plain fills and thin strokes, so a burst costs two layers however many particles it has. `budget`
/// truncates the list (`policy.particleBudget`; 0 draws nothing) and `flashes` allows the white-hot
/// heads on sparks and stars. Nothing here allocates per frame beyond the two layers.
enum ParticleRenderer {
    /// How far behind its head a spark's streak trails, in seconds.
    private static let sparkTrail: TimeInterval = 0.05
    private static let starTrail: TimeInterval = 0.08
    private static let streakTrail: TimeInterval = 0.06

    static func draw(
        _ particles: [Particle],
        elapsed: TimeInterval,
        unit: CGFloat,
        at center: CGPoint,
        flashes: Bool,
        budget: Int,
        in context: inout GraphicsContext
    ) {
        guard budget > 0, unit > 0, !particles.isEmpty else { return }
        let drawn = particles.prefix(budget)
        var hasLight = false
        var hasPuffs = false
        var hasPlain = false
        for particle in drawn where particle.age(at: elapsed) != nil {
            switch particle.kind {
            case .spark, .ember, .star:
                hasLight = true
            case .puff:
                hasPuffs = true
            case .droplet, .shard, .bubble, .ring, .streak, .foam:
                hasPlain = true
            }
        }

        // Smoke first, so everything else burns over it.
        if hasPuffs {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: unit * 0.1))
                for particle in drawn where particle.kind == .puff {
                    drawPuff(particle, elapsed: elapsed, unit: unit, center: center, in: &layer)
                }
            }
        }

        if hasPlain {
            for particle in drawn {
                switch particle.kind {
                case .droplet:
                    drawDroplet(particle, elapsed: elapsed, unit: unit, center: center, in: &context)
                case .shard:
                    drawShard(particle, elapsed: elapsed, unit: unit, center: center, in: &context)
                case .bubble:
                    drawBubble(particle, elapsed: elapsed, unit: unit, center: center, in: &context)
                case .ring, .foam:
                    drawRing(particle, elapsed: elapsed, unit: unit, center: center, in: &context)
                case .streak:
                    drawStreak(particle, elapsed: elapsed, unit: unit, center: center, in: &context)
                case .spark, .ember, .star, .puff:
                    continue
                }
            }
        }

        if hasLight {
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                for particle in drawn {
                    switch particle.kind {
                    case .spark:
                        drawSpark(particle, elapsed: elapsed, unit: unit, center: center, flashes: flashes, in: &layer)
                    case .ember:
                        drawEmber(particle, elapsed: elapsed, unit: unit, center: center, in: &layer)
                    case .star:
                        drawStar(particle, elapsed: elapsed, unit: unit, center: center, flashes: flashes, in: &layer)
                    case .droplet, .shard, .bubble, .ring, .streak, .foam, .puff:
                        continue
                    }
                }
            }
        }
    }

    // MARK: Plain

    private static func drawDroplet(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let radius = max(0.5, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        let color = particle.tint > 0.6 ? Theme.reticle : Color.white
        context.fill(circle(point, radius), with: .color(color.opacity(0.9 * alpha)))
    }

    private static func drawRing(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let radius = max(0.5, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        if particle.tint >= 0.5 {
            // An oil slick's ring: dark and soft.
            context.stroke(
                circle(point, radius),
                with: .color(Color.black.opacity(0.35 * alpha)),
                lineWidth: max(1, unit * 0.12)
            )
        } else {
            let brightness = particle.kind == .foam ? 0.6 : 0.75
            context.stroke(
                circle(point, radius),
                with: .color(Color.white.opacity(brightness * alpha)),
                lineWidth: 0.5 + 1.5 * CGFloat(alpha)
            )
        }
    }

    private static func drawBubble(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let radius = max(0.75, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        context.stroke(circle(point, radius), with: .color(Color.white.opacity(0.55 * alpha)), lineWidth: max(0.5, unit * 0.02))
        let highlight = CGPoint(x: point.x - radius * 0.35, y: point.y - radius * 0.35)
        context.fill(circle(highlight, max(0.5, radius * 0.25)), with: .color(Color.white.opacity(0.7 * alpha)))
    }

    private static func drawShard(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0, let age = particle.age(at: elapsed) else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let size = max(1, CGFloat(particle.size) * unit)
        let body = CGRect(x: -size * 1.1, y: -size * 0.45, width: size * 2.2, height: size * 0.9)
        let transform = CGAffineTransform(translationX: point.x, y: point.y).rotated(by: CGFloat(particle.spin * age))
        let color = particle.tint < 0.5 ? Theme.gunMetal : Theme.hullShadow
        context.fill(Path(body).applying(transform), with: .color(color.opacity(0.9 * alpha)))
    }

    private static func drawStreak(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let head = position(of: particle, at: elapsed, unit: unit, center: center)
        let tail = position(of: particle, at: elapsed - streakTrail, unit: unit, center: center)
        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.85 * alpha)),
            style: StrokeStyle(lineWidth: max(0.75, CGFloat(particle.size) * unit), lineCap: .round)
        )
    }

    private static func drawPuff(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let radius = max(1, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        context.fill(circle(point, radius), with: .color(Color.black.opacity((0.32 + 0.1 * particle.tint) * alpha)))
    }

    // MARK: Light

    private static func drawSpark(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, flashes: Bool, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let head = position(of: particle, at: elapsed, unit: unit, center: center)
        let tail = position(of: particle, at: elapsed - sparkTrail, unit: unit, center: center)
        let radius = max(0.5, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        let color = particle.tint > 0.5 ? Theme.flame : Theme.hit
        context.stroke(path, with: .color(color.opacity(0.85 * alpha)), style: StrokeStyle(lineWidth: max(0.6, radius * 1.2), lineCap: .round))
        context.fill(circle(head, radius), with: .color((flashes ? Color.white : Theme.ember).opacity(alpha)))
    }

    private static func drawEmber(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let point = position(of: particle, at: elapsed, unit: unit, center: center)
        let radius = max(0.5, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        let color = particle.tint > 0.5 ? Theme.ember : Theme.flame
        context.fill(circle(point, radius * 2.2), with: .color(color.opacity(0.25 * alpha)))
        context.fill(circle(point, radius), with: .color(color.opacity(0.9 * alpha)))
    }

    private static func drawStar(_ particle: Particle, elapsed: TimeInterval, unit: CGFloat, center: CGPoint, flashes: Bool, in context: inout GraphicsContext) {
        let alpha = particle.alpha(at: elapsed)
        guard alpha > 0 else { return }
        let head = position(of: particle, at: elapsed, unit: unit, center: center)
        let tail = position(of: particle, at: elapsed - starTrail, unit: unit, center: center)
        let radius = max(0.5, CGFloat(particle.size * particle.scale(at: elapsed)) * unit)
        let color: Color = particle.tint < 0.33 ? Theme.gold : (particle.tint < 0.66 ? Color.white : Theme.reticle)
        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        context.stroke(path, with: .color(color.opacity(0.7 * alpha)), style: StrokeStyle(lineWidth: max(0.5, radius * 0.9), lineCap: .round))
        context.fill(circle(head, radius), with: .color((flashes ? Color.white : color).opacity(alpha)))
    }

    // MARK: Geometry

    /// Where `particle` is at `t`, in points.
    static func position(of particle: Particle, at t: TimeInterval, unit: CGFloat, center: CGPoint) -> CGPoint {
        let point = particle.position(at: t)
        return CGPoint(x: center.x + CGFloat(point.x) * unit, y: center.y + CGFloat(point.y) * unit)
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
