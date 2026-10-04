import Foundation

/// A mood as a timeline of engine setters, relative to the moment the mood starts:
/// an intro played once, then an optional loop.
nonisolated struct MimoMoodScript: Sendable {
    enum Action: Equatable, Sendable {
        case state(Bloub.StateID)
        case expression(Bloub.ExpressionID)
        case look(Bloub.Look?, morph: Double)
    }

    struct Step: Equatable, Sendable {
        var at: Double
        var action: Action
    }

    var intro: [Step]
    var loop: [Step] = []
    /// When the loop starts, after the mood starts.
    var loopStart = 0.0
    /// Length of one loop iteration.
    var period = 0.0

    var loops: Bool { !loop.isEmpty && period > 0 }

    /// When a non-looping script has played its last step.
    var end: Double { intro.map(\.at).max() ?? 0 }

    /// An upward glance to one side, for thinking.
    static func ponder(yaw: Double, pitch: Double = 20) -> Bloub.Look {
        Bloub.Look(yaw: yaw, pitch: pitch, mix: 1, spin: 0, wander: 0.2)
    }

    static func script(for mood: MimoMood, style: MimoAvatarStyle) -> MimoMoodScript {
        let rest = style.rest.expression.gaze
        switch mood {
        case .idle:
            return MimoMoodScript(intro: [
                Step(at: 0, action: .state(.idle)),
                Step(at: 0, action: .expression(style.rest)),
                Step(at: 0, action: .look(nil, morph: 0.5)),
            ])
        case .listening:
            // The listening face (a head tilt) turned to face the user, drift kept low.
            return MimoMoodScript(intro: [
                Step(at: 0, action: .state(.idle)),
                Step(at: 0, action: .expression(style.listening)),
                Step(at: 0, action: .look(Bloub.Look(yaw: 2, pitch: 2, mix: 0.6, spin: 0, wander: 0.5), morph: 0.5)),
            ])
        case .thinking:
            // Pondering: Mimo keeps its body and face and glances up to one side,
            // drifts, then up to the other, as someone does while they think.
            // (bloub's own thinking state turns the body into three dots.)
            return MimoMoodScript(
                intro: [
                    Step(at: 0, action: .state(.idle)),
                    Step(at: 0, action: .expression(style.rest)),
                    Step(at: 0, action: .look(Self.ponder(yaw: -18), morph: 0.45)),
                ],
                loop: [
                    Step(at: 0, action: .look(Self.ponder(yaw: -18), morph: 0.45)),
                    Step(at: 1.1, action: .look(Self.ponder(yaw: -9, pitch: 24), morph: 0.6)),
                    Step(at: 1.7, action: .look(Self.ponder(yaw: 18), morph: 0.45)),
                    Step(at: 2.8, action: .look(Self.ponder(yaw: 9, pitch: 24), morph: 0.6)),
                ],
                loopStart: 0.6,
                period: 3.4
            )
        case .talking:
            // Small nods of the gaze, at a speaking rhythm, around the rest face.
            func nod(_ dYaw: Double, _ dPitch: Double) -> Action {
                .look(Bloub.Look(yaw: rest.yaw + dYaw, pitch: rest.pitch + dPitch, mix: 1, spin: 0, wander: 0.35), morph: 0.26)
            }
            return MimoMoodScript(
                intro: [Step(at: 0, action: .state(.idle)), Step(at: 0, action: .expression(style.rest))],
                loop: [
                    Step(at: 0, action: nod(1, 6)),
                    Step(at: 0.3, action: nod(0, -2)),
                    Step(at: 0.62, action: nod(-2, 5)),
                    Step(at: 0.9, action: nod(1, -1)),
                    Step(at: 1.35, action: nod(3, 7)),
                    Step(at: 1.66, action: nod(0, -3)),
                    Step(at: 2.1, action: nod(-1, 3)),
                ],
                loopStart: 0,
                period: 2.6
            )
        case .happy:
            return MimoMoodScript(intro: [
                Step(at: 0, action: .look(nil, morph: 0.5)),
                Step(at: 0, action: .state(.wink)),
                Step(at: 1.2, action: .state(.idle)),
                Step(at: 1.2, action: .expression(style.happy)),
                Step(at: 3.2, action: .expression(style.rest)),
            ])
        }
    }
}

/// Plays moods on a `Bloub.Engine`.
///
/// Every setter is applied with its own scheduled timestamp, never the frame's, so what
/// you see depends only on when the moods changed, not on the frame rate. The engine
/// stays a pure function of time; this class only holds the schedule.
final class MimoAvatarDirector {
    private var engine: Bloub.Engine
    private var style: MimoAvatarStyle
    /// The date of engine time 0.
    private var origin: Date?
    /// Where on bloub's clock this avatar starts, so two avatars on screen don't blink
    /// and drift in unison. Within the first minute, far from the 900 s schedule end.
    private let clockStart: Double
    private var mood: MimoMood?
    private var script = MimoMoodScript(intro: [])
    private var scriptStart = 0.0
    /// Next intro step to apply.
    private var introCursor = 0
    /// Next loop step to apply: iteration and index.
    private var loopIteration = 0
    private var loopCursor = 0
    /// The last time a setter changed something visible.
    private var lastChange = -10.0

    /// bloub pre-draws blinks for 900 s. Past this, the clock is moved back at the next
    /// quiet blink (see `reanchorIfQuiet`).
    private static let reanchorAfter = 600.0

    init(style: MimoAvatarStyle = .mimo, clockStart: Double = .random(in: 0..<60)) {
        self.style = style
        self.clockStart = clockStart
        engine = Bloub.Engine(scale: 1, initial: .idle, shape: style.bodyShape, expression: style.rest.expression)
    }

    /// The frame for `date`, starting or switching mood first if needed.
    func frame(at date: Date, mood: MimoMood, style: MimoAvatarStyle) -> Bloub.Frame {
        if origin == nil { origin = date.addingTimeInterval(-clockStart) }
        var now = date.timeIntervalSince(origin ?? date)
        if style != self.style {
            self.style = style
            engine.setShape(style.bodyShape, now: now)
            self.mood = nil
        }
        if mood != self.mood { start(mood, at: now) }
        advance(to: now)
        if now > Self.reanchorAfter, reanchorIfQuiet(at: now, date: date) {
            now = date.timeIntervalSince(origin ?? date)
        }
        return engine.sample(now)
    }

    private func start(_ mood: MimoMood, at now: Double) {
        self.mood = mood
        script = MimoMoodScript.script(for: mood, style: style)
        scriptStart = now
        introCursor = 0
        loopIteration = 0
        loopCursor = 0
    }

    private func advance(to now: Double) {
        while introCursor < script.intro.count, scriptStart + script.intro[introCursor].at <= now {
            apply(script.intro[introCursor].action, at: scriptStart + script.intro[introCursor].at)
            introCursor += 1
        }
        guard script.loops, now >= scriptStart + script.loopStart else { return }
        // After a long pause (app in the background), skip to the current iteration.
        let elapsed = now - scriptStart - script.loopStart
        let current = Int(elapsed / script.period)
        if current > loopIteration + 1 {
            loopIteration = current - 1
            loopCursor = 0
        }
        while true {
            let step = script.loop[loopCursor]
            let at = scriptStart + script.loopStart + Double(loopIteration) * script.period + step.at
            if at > now { break }
            apply(step.action, at: at)
            loopCursor += 1
            if loopCursor == script.loop.count {
                loopCursor = 0
                loopIteration += 1
            }
        }
    }

    private func apply(_ action: MimoMoodScript.Action, at t: Double) {
        switch action {
        case .state(let id):
            if engine.state != id { lastChange = t }
            engine.setState(id, now: t)
        case .expression(let id):
            if engine.currentExpression?.id != id { lastChange = t }
            engine.setExpression(id.expression, now: t)
        case .look(let look, let morph):
            if engine.currentLook != (look ?? .none) { lastChange = t }
            engine.setLook(look, now: t, morph: morph)
        }
    }

    /// bloub's blink schedule ends at 900 s and its gaze drift is a function of absolute
    /// time, so the clock can't simply wrap. Once a non-looping mood has settled, the
    /// engine is rebuilt on a fresh clock at the bottom of a scheduled blink, where the
    /// new clock is also mid-blink: the eyes are closed while the drift jumps.
    private func reanchorIfQuiet(at now: Double, date: Date) -> Bool {
        guard !script.loops, now - scriptStart > script.end + 1, now - lastChange > 2 else { return false }
        let schedule = Bloub.blinkSchedule
        guard let start = schedule.last(where: { $0 <= now }) else { return false }
        let into = now - start
        // the bottom of a blink: lid below about 0.3
        guard into > 0.055, into < 0.11, schedule.count > 2 else { return false }
        let fresh = schedule[2] + into
        var engine = Bloub.Engine(scale: 1, initial: self.engine.state, shape: style.bodyShape,
                                  expression: self.engine.currentExpression)
        let look = self.engine.currentLook
        engine.setLook(look == .none ? nil : look, now: fresh - 10)
        self.engine = engine
        origin = date.addingTimeInterval(-fresh)
        scriptStart = fresh - script.end - 10
        lastChange = fresh - 10
        return true
    }

    /// A still frame of a mood, for Reduce Motion: the pose the mood settles on.
    static func still(_ mood: MimoMood, style: MimoAvatarStyle) -> Bloub.Frame {
        switch mood {
        case .idle, .talking:
            return frozen(.idle, at: 1, style: style)
        case .listening:
            return frozen(.idle, at: 1, style: style, expression: style.listening,
                          look: Bloub.Look(yaw: 2, pitch: 2, mix: 0.6, spin: 0, wander: 0.5))
        case .thinking:
            return frozen(.idle, at: 1, style: style, look: MimoMoodScript.ponder(yaw: -18))
        case .happy:
            return frozen(.idle, at: 1, style: style, expression: style.happy)
        }
    }

    /// One exact frame of a bloub state, `t` seconds into it, in Mimo's style.
    static func frozen(_ state: Bloub.StateID, at t: Double, style: MimoAvatarStyle,
                       expression: Bloub.ExpressionID? = nil, look: Bloub.Look? = nil) -> Bloub.Frame
    {
        var engine = Bloub.Engine(scale: 1, initial: state, shape: style.bodyShape,
                                  expression: (expression ?? style.rest).expression)
        if let look { engine.setLook(look, now: t - 10) }
        return engine.sample(t)
    }
}
