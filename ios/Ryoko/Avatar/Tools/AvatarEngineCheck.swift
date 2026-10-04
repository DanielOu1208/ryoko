// Exactness check of the Swift bloub port (ios/Ryoko/Avatar/Engine/) against bloub's
// TypeScript engine. It runs on the Mac; nothing here is compiled into the app (the
// whole file is behind AVATAR_ENGINE_CHECK).
//
// 1. Reference samples from the TypeScript original, outside the repo:
//
//   git clone --depth 1 https://github.com/jeremy-prt/bloub /tmp/bloub
//   mkdir -p /tmp/bloub-ref && cd /tmp/bloub-ref && echo '{"type":"module"}' > package.json && npm i tsx@4
//   <check binary> --write-reference-script /tmp/bloub-ref/dump.ts
//   /tmp/bloub-ref/node_modules/.bin/tsx /tmp/bloub-ref/dump.ts /tmp/bloub > /tmp/bloub-ref/reference.json
//
// 2. Build and run the check (same Swift settings as the app target):
//
//   ROOT=$(git rev-parse --show-toplevel); OUT="$ROOT/ios/.build/avatar-engine-check"; mkdir -p "$OUT"
//   xcrun swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
//     -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
//     -enable-upcoming-feature MemberImportVisibility -D AVATAR_ENGINE_CHECK -module-name AvatarEngineCheck \
//     -o "$OUT/avatar-engine-check" "$ROOT"/ios/Ryoko/Avatar/Engine/*.swift "$ROOT/ios/Ryoko/Avatar/Tools/AvatarEngineCheck.swift" \
//   && "$OUT/avatar-engine-check" /tmp/bloub-ref/reference.json
//
// The reference replaces Math.round with the identity while sampling, so it carries
// unrounded numbers. The check replays every case (states alone, every transition in
// and out mid-fade, chained mid-fade changes, the default montage, every customiser
// shape and several expressions, shape/expression morphs, gaze targets), compares every
// number of every frame, plus the whole eye-fit table, the shapes, the profiles, the
// decor seeds and the montage helpers, and prints the largest error per group. It exits
// non-zero if any structure differs or any error exceeds the tolerance.

#if AVATAR_ENGINE_CHECK
import Foundation

@main
nonisolated enum AvatarEngineCheck {
    /// In viewBox units at bloub's scale (ball radius 100): 1e-6 of a unit is 1e-8 of
    /// the radius.
    static let tolerance = 1e-6

    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--write-reference-script" {
            do {
                try (referenceScript + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
                print("wrote \(args[2])")
            } catch {
                fail("could not write \(args[2]): \(error)")
            }
            return
        }
        guard args.count == 2 else {
            fail("usage: avatar-engine-check <reference.json> | --write-reference-script <path>")
        }
        let reference: Reference
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            reference = try JSONDecoder().decode(Reference.self, from: data)
        } catch {
            fail("could not read \(args[1]): \(error)")
        }
        var report = Report()
        checkCases(reference, &report)
        checkEyeFit(reference, &report)
        checkTables(reference, &report)
        checkCycles(reference, &report)
        report.print(commit: reference.bloubCommit)
        exit(report.passed ? 0 : 1)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    // MARK: Report

    struct Report {
        var maxError: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var order: [String] = []
        var failures: [String] = []

        var passed: Bool { failures.isEmpty && maxError.values.allSatisfy { $0 <= tolerance } }

        mutating func note(_ group: String, _ error: Double, count: Int = 1) {
            if maxError[group] == nil { order.append(group) }
            maxError[group] = max(maxError[group] ?? 0, error.isNaN ? .infinity : error)
            counts[group, default: 0] += count
        }

        mutating func failure(_ message: String) {
            if failures.count < 40 { failures.append(message) }
        }

        func print(commit: String) {
            Swift.print("bloub \(commit), tolerance \(tolerance) viewBox units (ball radius 100)")
            for group in order {
                let e = maxError[group] ?? 0
                let status = e <= tolerance ? "pass" : "FAIL"
                Swift.print("  \(status)  \(group.padding(toLength: 22, withPad: " ", startingAt: 0)) max error \(String(format: "%.3e", e))  (\(counts[group] ?? 0) checks)")
            }
            for f in failures { Swift.print("  FAIL  \(f)") }
            Swift.print(passed ? "PASS" : "FAILED")
        }
    }

    /// Compares two number lists; a length mismatch is a structural failure.
    static func compare(_ a: [Double], _ b: [Double], _ what: @autoclosure () -> String, _ group: String, _ report: inout Report) {
        guard a.count == b.count else {
            report.failure("\(what()): \(a.count) numbers in Swift, \(b.count) in bloub")
            report.note(group, .infinity)
            return
        }
        var e = 0.0
        for (x, y) in zip(a, b) { e = max(e, abs(x - y)) }
        report.note(group, e, count: a.count)
        if e > tolerance { report.failure("\(what()): off by \(e)") }
    }

    // MARK: Cases

    static func checkCases(_ reference: Reference, _ report: inout Report) {
        for c in reference.cases {
            guard var engine = makeEngine(c, reference.scale) else {
                report.failure("\(c.name): unknown state, shape or expression")
                continue
            }
            for op in c.ops { apply(op, to: &engine) }
            for s in c.samples {
                compare(engine.sample(s.t), s.frame, "\(c.name) @ \(s.t)", c.group, &report)
            }
        }
    }

    static func makeEngine(_ c: Case, _ scale: Double) -> Bloub.Engine? {
        guard let state = Bloub.StateID(rawValue: c.initial.state) else { return nil }
        let shape = c.initial.shape.flatMap(Bloub.ShapeID.init(rawValue:))?.shape
        let expr = c.initial.expr.flatMap(Bloub.ExpressionID.init(rawValue:))?.expression
        return Bloub.Engine(scale: scale, initial: state, shape: shape, expression: expr)
    }

    static func apply(_ op: Op, to engine: inout Bloub.Engine) {
        switch op.op {
        case "setState": engine.setState(Bloub.StateID(rawValue: op.id ?? "")!, now: op.now)
        case "reset": engine.reset(Bloub.StateID(rawValue: op.id ?? "")!, now: op.now)
        case "setShape": engine.setShape(op.shape.flatMap(Bloub.ShapeID.init(rawValue:))?.shape, now: op.now)
        case "setExpression": engine.setExpression(op.expr.flatMap(Bloub.ExpressionID.init(rawValue:))?.expression, now: op.now)
        case "setLook":
            let look = op.look.map {
                Bloub.Look(yaw: $0.yaw ?? .nan, pitch: $0.pitch, mix: $0.mix, spin: $0.spin, wander: $0.wander)
            }
            if let morph = op.morph {
                engine.setLook(look, now: op.now, morph: morph)
            } else {
                engine.setLook(look, now: op.now)
            }
        default: fail("unknown op \(op.op)")
        }
    }

    static func compare(_ f: Bloub.Frame, _ r: FrameRef, _ what: String, _ group: String, _ report: inout Report) {
        // body: the start point, then the three points of each cubic
        var body = [f.body[0].x, f.body[0].y]
        for seg in f.bodyCurve {
            body += [seg.control1.x, seg.control1.y, seg.control2.x, seg.control2.y, seg.to.x, seg.to.y]
        }
        compare(body, r.body, "\(what) body", group, &report)
        compare([f.bodyAlpha], [r.bodyAlpha], "\(what) bodyAlpha", group, &report)

        if f.eyes.count != r.eyes.count {
            report.failure("\(what): \(f.eyes.count) eyes in Swift, \(r.eyes.count) in bloub")
            report.note(group, .infinity)
        } else {
            for (i, (e, re)) in zip(f.eyes, r.eyes).enumerated() {
                let t = e.transform
                compare([e.capsule.halfWidth, e.capsule.halfHeight, e.capsule.cornerRadius], re.cap, "\(what) eye \(i) capsule", group, &report)
                compare([t.a, t.b, t.c, t.d, t.tx, t.ty], re.m, "\(what) eye \(i) matrix", group, &report)
                compare([e.alpha], [re.alpha], "\(what) eye \(i) alpha", group, &report)
            }
        }

        if f.dotsBehind != r.dotsBehind { report.failure("\(what): dotsBehind differs") }
        if f.dots.count != r.dots.count {
            report.failure("\(what): \(f.dots.count) dots in Swift, \(r.dots.count) in bloub")
            report.note(group, .infinity)
        } else {
            for (i, (d, rd)) in zip(f.dots, r.dots).enumerated() {
                compare([d.x, d.y, d.r, d.opacity], [rd.x, rd.y, rd.r, rd.opacity], "\(what) dot \(i)", group, &report)
                if (d.depth == nil) != (rd.depth == nil) || (d.rot == nil) != (rd.rot == nil) || (d.shape == nil) != (rd.shape == nil) {
                    report.failure("\(what) dot \(i): optional fields differ")
                }
                if let a = d.depth, let b = rd.depth { compare([a], [b], "\(what) dot \(i) depth", group, &report) }
                if let a = d.rot, let b = rd.rot { compare([a], [b], "\(what) dot \(i) rot", group, &report) }
                if let a = d.shape, let b = rd.shape {
                    compare(a.flatMap { [$0.x, $0.y] }, b, "\(what) dot \(i) shape", group, &report)
                }
            }
        }

        if f.arcs.count != r.arcs.count {
            report.failure("\(what): \(f.arcs.count) arcs in Swift, \(r.arcs.count) in bloub")
            report.note(group, .infinity)
        } else {
            for (a, ra) in zip(f.arcs, r.arcs) {
                if a.id != ra.id { report.failure("\(what): arc \(a.id) vs \(ra.id)") }
                compareRuns(a.front, ra.front, "\(what) arc \(a.id) front", group, &report)
                compareRuns(a.back, ra.back, "\(what) arc \(a.id) back", group, &report)
                let g = a.gradient
                compare([a.width, a.opacity, g.x1, g.y1, g.x2, g.y2], [ra.width, ra.opacity] + ra.grad, "\(what) arc \(a.id)", group, &report)
                if g.stops.map(\.hex) != ra.stops { report.failure("\(what) arc \(a.id): colours \(g.stops.map(\.hex)) vs \(ra.stops)") }
            }
        }

        for (name, disc, ref) in [("notif", f.notif, r.notif), ("notch", f.notch, r.notch)] {
            switch (disc, ref) {
            case (nil, nil): break
            case let (d?, ref?): compare([d.x, d.y, d.r], ref, "\(what) \(name)", group, &report)
            default: report.failure("\(what): \(name) present on one side only")
            }
        }
    }

    static func compareRuns(_ a: [[Bloub.Point]], _ b: [[Double]], _ what: String, _ group: String, _ report: inout Report) {
        guard a.count == b.count else {
            report.failure("\(what): \(a.count) runs in Swift, \(b.count) in bloub")
            report.note(group, .infinity)
            return
        }
        for (run, ref) in zip(a, b) { compare(run.flatMap { [$0.x, $0.y] }, ref, what, group, &report) }
    }

    // MARK: Tables

    static func checkEyeFit(_ reference: Reference, _ report: inout Report) {
        for entry in reference.eyefit {
            guard let shape = Bloub.ShapeID(rawValue: entry.shape), let state = Bloub.StateID(rawValue: entry.state) else {
                report.failure("eye fit: unknown \(entry.shape) / \(entry.state)")
                continue
            }
            let expr = entry.expr.flatMap(Bloub.ExpressionID.init(rawValue:))
            let o = Bloub.EyeFit.offset(shape: shape.shape, state: state, expression: expr)
            // offsets are in ball radii; compare in viewBox units like everything else
            compare([o.x * 100, o.y * 100], [entry.x * 100, entry.y * 100], "eye fit \(entry.shape) \(entry.state) \(entry.expr ?? "-")", "eye-fit table", &report)
        }
    }

    static func checkTables(_ reference: Reference, _ report: inout Report) {
        for shape in Bloub.ShapeID.allCases {
            guard let radii = reference.shapes[shape.rawValue] else {
                report.failure("shape \(shape.rawValue) missing from the reference")
                continue
            }
            compare(shape.shape.radii.map { $0 * 100 }, radii.map { $0 * 100 }, "shape \(shape.rawValue)", "shapes and profiles", &report)
        }
        for name in Bloub.ProfileName.allCases {
            compare(Bloub.profile(name), reference.profiles[name.rawValue] ?? [], "profile \(name.rawValue)", "shapes and profiles", &report)
        }
        let seeds: [(String, [Bloub.ArcSeed], [SeedRef])] = [
            ("rings", Bloub.rings, reference.seeds.rings),
            ("swoosh", Bloub.swoosh, reference.seeds.swoosh),
            ("comet", Bloub.cometRibbons, reference.seeds.comet),
        ]
        for (name, swift, ref) in seeds {
            guard swift.count == ref.count else {
                report.failure("\(name): \(swift.count) seeds vs \(ref.count)")
                continue
            }
            for (s, r) in zip(swift, ref) {
                compare([s.a, s.k, s.tilt, s.speed, s.phase, s.sweep, s.hue, s.hueSpan, s.width, s.cx, s.cy],
                        [r.a, r.k, r.tilt, r.speed, r.phase, r.sweep, r.hue, r.hueSpan, r.width, r.cx, r.cy],
                        "\(name) seed", "decor seeds", &report)
            }
        }
    }

    static func checkCycles(_ reference: Reference, _ report: inout Report) {
        let c = reference.cycles
        let group = "montage helpers"
        compare([Bloub.Cycles.minBlock], [c.minBlock], "MIN_BLOCK", group, &report)
        let blocks = Bloub.Cycles.defaultCycle().blocks
        if blocks.map(\.state.rawValue) != c.defaultCycle.map(\.state) { report.failure("default cycle order differs") }
        compare(blocks.map(\.duration), c.defaultCycle.map(\.duration), "default cycle durations", group, &report)
        if Bloub.sequence.map(\.rawValue) != c.sequence { report.failure("SEQUENCE differs") }
        for (id, value) in c.minDurations {
            compare([Bloub.Cycles.minDuration(of: Bloub.StateID(rawValue: id)!)], [value], "minDurationOf \(id)", group, &report)
        }
        for clamp in c.clamps {
            compare([Bloub.Cycles.clampDuration(Bloub.StateID(rawValue: clamp.state)!, clamp.seconds)], [clamp.result],
                    "clampDuration \(clamp.state) \(clamp.seconds)", group, &report)
        }
        for at in c.blockAt {
            let r = Bloub.Cycles.blockAt(blocks, at.t)
            if r.index != at.index { report.failure("blockAt \(at.t): block \(r.index) vs \(at.index)") }
            compare([r.elapsed], [at.elapsed], "blockAt \(at.t)", group, &report)
        }
    }

    // MARK: Reference format

    struct Reference: Decodable {
        var bloubCommit: String
        var scale: Double
        var cases: [Case]
        var eyefit: [EyeFitRef]
        var shapes: [String: [Double]]
        var profiles: [String: [Double]]
        var seeds: Seeds
        var cycles: CyclesRef
    }

    struct Case: Decodable {
        var name: String
        var group: String
        var initial: Initial
        var ops: [Op]
        var samples: [Sample]
    }

    struct Initial: Decodable {
        var state: String
        var shape: String?
        var expr: String?
    }

    struct Op: Decodable {
        var op: String
        var id: String?
        var shape: String?
        var expr: String?
        var look: LookRef?
        var now: Double
        var morph: Double?
    }

    /// JSON has no NaN: the refused target's `yaw: NaN` arrives as null.
    struct LookRef: Decodable {
        var yaw: Double?
        var pitch: Double
        var mix: Double
        var spin: Double
        var wander: Double
    }

    struct Sample: Decodable {
        var t: Double
        var frame: FrameRef
    }

    struct FrameRef: Decodable {
        var body: [Double]
        var bodyAlpha: Double
        var eyes: [EyeRef]
        var dots: [DotRef]
        var dotsBehind: Bool
        var arcs: [ArcRef]
        var notif: [Double]?
        var notch: [Double]?
    }

    struct EyeRef: Decodable {
        var cap: [Double]
        var m: [Double]
        var alpha: Double
    }

    struct DotRef: Decodable {
        var x: Double
        var y: Double
        var r: Double
        var opacity: Double
        var depth: Double?
        var rot: Double?
        var shape: [Double]?
    }

    struct ArcRef: Decodable {
        var id: String
        var front: [[Double]]
        var back: [[Double]]
        var width: Double
        var opacity: Double
        var grad: [Double]
        var stops: [String]
    }

    struct EyeFitRef: Decodable {
        var shape: String
        var state: String
        var expr: String?
        var x: Double
        var y: Double
    }

    struct SeedRef: Decodable {
        var a: Double
        var k: Double
        var tilt: Double
        var speed: Double
        var phase: Double
        var sweep: Double
        var hue: Double
        var hueSpan: Double
        var width: Double
        var cx: Double
        var cy: Double
    }

    struct Seeds: Decodable {
        var rings: [SeedRef]
        var swoosh: [SeedRef]
        var comet: [SeedRef]
    }

    struct CyclesRef: Decodable {
        var minBlock: Double
        var defaultCycle: [BlockRef]
        var sequence: [String]
        var minDurations: [String: Double]
        var clamps: [ClampRef]
        var blockAt: [BlockAtRef]
    }

    struct BlockRef: Decodable {
        var state: String
        var duration: Double
    }

    struct ClampRef: Decodable {
        var state: String
        var seconds: Double
        var result: Double
    }

    struct BlockAtRef: Decodable {
        var t: Double
        var index: Int
        var elapsed: Double
    }
}

// MARK: The reference script

extension AvatarEngineCheck {
    /// The TypeScript that dumps bloub's reference samples. Kept here, not as a .ts file,
    /// because everything under ios/Ryoko/ is copied into the app bundle.
    static let referenceScript = #"""
// Dumps reference samples from bloub's TypeScript engine, for the Swift exactness check
// (ios/Ryoko/Avatar/Tools/AvatarEngineCheck.swift). Usage:
//   /tmp/bloub-ref/node_modules/.bin/tsx dump.ts /tmp/bloub > reference.json
//
// bloub formats its output through r2() (2 decimals). To compare unrounded numbers,
// Math.round is swapped for the identity while sampling geometry, then restored for a
// second pass that reads the arc colours (whose hex formatting needs a real round).
import path from 'node:path'
import { execSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const root = process.argv[2] ?? '/tmp/bloub'
const bot = (f: string) => pathToFileURL(path.join(root, 'src/bot', f)).href
const { BotEngine } = await import(bot('engine.ts'))
const { STATES, SEQUENCE, POSES } = await import(bot('states.ts'))
const { SHAPES, SHAPE_BY_ID } = await import(bot('skins.ts'))
const { EXPRESSIONS, EXPRESSION_BY_ID } = await import(bot('expressions.ts'))
const { decalageDesYeux } = await import(bot('eyefit.ts'))
const { RINGS, SWOOSH, COMET_RIBBONS } = await import(bot('decor.ts'))
const { PROFILES } = await import(bot('profiles.ts'))
const cycles = await import(bot('cycles.ts'))

const SCALE = 100
const realRound = Math.round
const nums = (s: string): number[] => (s.match(/-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/gi) ?? []).map(Number)
const runs = (s: string): number[][] =>
  s.split('M').filter((r) => r.length > 0).map((r) => nums(r))

type Op =
  | { op: 'setState'; id: string; now: number }
  | { op: 'reset'; id: string; now: number }
  | { op: 'setShape'; shape: string | null; now: number }
  | { op: 'setExpression'; expr: string | null; now: number }
  | {
      op: 'setLook'
      look: { yaw: number; pitch: number; mix: number; spin: number; wander: number } | null
      now: number
      morph?: number
    }

interface CaseDef {
  name: string
  group: string
  initial: { state: string; shape?: string | null; expr?: string | null }
  ops: Op[]
  times: number[]
}

function build(c: CaseDef) {
  const e = new BotEngine(
    SCALE,
    c.initial.state,
    c.initial.shape ? SHAPE_BY_ID.get(c.initial.shape)!.radii : null,
    c.initial.expr ? EXPRESSION_BY_ID.get(c.initial.expr)! : null
  )
  for (const o of c.ops) {
    if (o.op === 'setState') e.setState(o.id, o.now)
    else if (o.op === 'reset') e.reset(o.id, o.now)
    else if (o.op === 'setShape') e.setShape(o.shape ? SHAPE_BY_ID.get(o.shape)!.radii : null, o.now)
    else if (o.op === 'setExpression') e.setExpression(o.expr ? EXPRESSION_BY_ID.get(o.expr)! : null, o.now)
    else if (o.op === 'setLook') {
      if (o.morph === undefined) e.setLook(o.look, o.now)
      else e.setLook(o.look, o.now, o.morph)
    }
  }
  return e
}

function frame(e: any, t: number) {
  Math.round = (v: number) => v
  let f: any
  try {
    f = e.sample(t)
  } finally {
    Math.round = realRound
  }
  const colours = e.sample(t)
  return {
    body: nums(f.bodyPath),
    bodyAlpha: f.bodyAlpha,
    eyes: f.eyes.map((y: any) => {
      const n = nums(y.d)
      return { cap: [-n[0]!, -n[8]!, n[2]!], m: nums(y.matrix), alpha: y.alpha }
    }),
    dots: f.dots.map((d: any) => ({
      x: d.x,
      y: d.y,
      r: d.r,
      opacity: d.opacity,
      depth: d.depth ?? null,
      rot: d.rot ?? null,
      shape: d.d ? nums(d.d) : null
    })),
    dotsBehind: f.dotsBehind,
    arcs: f.arcs.map((a: any, i: number) => ({
      id: a.id,
      front: runs(a.front),
      back: runs(a.back),
      width: a.width,
      opacity: a.opacity,
      grad: [a.grad.x1, a.grad.y1, a.grad.x2, a.grad.y2],
      stops: colours.arcs[i].grad.stops
    })),
    notif: f.notif ? [f.notif.x, f.notif.y, f.notif.r] : null,
    notch: f.notch ? [f.notch.x, f.notch.y, f.notch.r] : null
  }
}

const cases: CaseDef[] = []
const ids: string[] = STATES.map((s: any) => s.id)
const steady = [0, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1, 1.25, 1.5, 1.75, 2, 2.3, 2.6, 3, 3.5, 4.2, 7.3, 12.9]
const across = [0.9, 1, 1.02, 1.05, 1.1, 1.18, 1.27, 1.4, 1.6, 2, 2.8, 4.1]

// every state on its own, through its whole animation
for (const id of ids) {
  cases.push({ name: `${id} alone`, group: id, initial: { state: id }, ops: [], times: [...steady, POSES[id]] })
}
// every transition into and out of each state, sampled mid-fade
for (const id of ids) {
  if (id === 'idle') continue
  cases.push({ name: `idle -> ${id}`, group: id, initial: { state: 'idle' }, ops: [{ op: 'setState', id, now: 1 }], times: across })
  cases.push({ name: `${id} -> idle`, group: id, initial: { state: id }, ops: [{ op: 'setState', id: 'idle', now: 1 }], times: across })
}
// the full catalogue played as bloub's default montage
{
  const blocks = cycles.defaultCycle().blocks
  const ops: Op[] = []
  let at = 0
  for (const b of blocks) {
    ops.push({ op: 'setState', id: b.state, now: at })
    at += b.duration
  }
  const times = Array.from({ length: 160 }, (_, i) => i * 0.2137)
  cases.push({ name: 'default montage', group: 'montage', initial: { state: 'idle' }, ops, times })
}
// a change landing mid-fade blends from the frozen composite pose
cases.push({
  name: 'idle -> wide -> idle mid-fade',
  group: 'mid-fade',
  initial: { state: 'idle' },
  ops: [{ op: 'setState', id: 'wide', now: 0.5 }, { op: 'setState', id: 'idle', now: 0.6 }],
  times: [0.5, 0.55, 0.6, 0.62, 0.66, 0.75, 0.9, 1.2]
})
cases.push({
  name: 'chained mid-fade changes',
  group: 'mid-fade',
  initial: { state: 'idle' },
  ops: [
    { op: 'setState', id: 'wide', now: 0.5 },
    { op: 'setState', id: 'idle', now: 0.55 },
    { op: 'setState', id: 'egg', now: 0.6 },
    { op: 'setState', id: 'orbit', now: 0.65 },
    { op: 'setState', id: 'notify', now: 0.7 }
  ],
  times: [0.5, 0.53, 0.56, 0.6, 0.63, 0.66, 0.7, 0.75, 0.85, 1.0, 1.3]
})
cases.push({
  name: 'reset',
  group: 'mid-fade',
  initial: { state: 'idle' },
  ops: [{ op: 'setState', id: 'egg', now: 0.2 }, { op: 'reset', id: 'orbit', now: 0.3 }],
  times: [0.3, 0.5, 1.2, 2.9]
})
// every customiser shape, with several expressions, at rest and through base-body states
const someExpr = ['neutre', 'attentif', 'heureux', 'curieux', 'effraye', 'somnolent', 'confus']
for (const s of SHAPES) {
  for (const x of someExpr) {
    cases.push({
      name: `shape ${s.id} expr ${x}`,
      group: `shape ${s.id}`,
      initial: { state: 'idle', shape: s.id, expr: x },
      ops: [],
      times: [0.4, 1, 2.3, 5.7]
    })
  }
  cases.push({
    name: `shape ${s.id} through states`,
    group: `shape ${s.id}`,
    initial: { state: 'idle', shape: s.id, expr: 'attentif' },
    ops: [
      { op: 'setState', id: 'wink', now: 1 },
      { op: 'setState', id: 'wide', now: 2.6 },
      { op: 'setState', id: 'notify', now: 4.4 },
      { op: 'setState', id: 'swirl', now: 6.6 },
      { op: 'setState', id: 'thinking', now: 7.9 },
      { op: 'setState', id: 'idle', now: 10.5 }
    ],
    times: [0.9, 1.05, 1.2, 2.0, 2.7, 3.0, 4.5, 5.0, 6.7, 7.0, 7.95, 8.2, 10.55, 10.8, 11.5]
  })
}
// shape and expression morphs, gaze targets
cases.push({
  name: 'shape and expression morphs',
  group: 'morphs',
  initial: { state: 'idle', shape: 'cercle', expr: 'neutre' },
  ops: [
    { op: 'setShape', shape: 'galet', now: 1 },
    { op: 'setExpression', expr: 'attentif', now: 1.2 },
    { op: 'setShape', shape: 'capsule', now: 2 },
    { op: 'setExpression', expr: 'heureux', now: 2.1 },
    { op: 'setShape', shape: null, now: 3 },
    { op: 'setExpression', expr: null, now: 3.1 }
  ],
  times: [1, 1.1, 1.25, 1.4, 1.6, 2.05, 2.2, 2.4, 3.05, 3.2, 3.5]
})
cases.push({
  name: 'gaze targets',
  group: 'look',
  initial: { state: 'idle', shape: 'galet', expr: 'attentif' },
  ops: [
    { op: 'setLook', look: { yaw: -26, pitch: 10, mix: 1, spin: 0, wander: 0 }, now: 0.5 },
    { op: 'setLook', look: { yaw: 0, pitch: 4, mix: 0.6, spin: 360, wander: 0.4 }, now: 1.5, morph: 0.9 },
    { op: 'setLook', look: { yaw: Number.NaN, pitch: 0, mix: 1, spin: 0, wander: 0 }, now: 2.6 },
    { op: 'setLook', look: null, now: 3 }
  ],
  times: [0.5, 0.6, 0.8, 1.6, 1.9, 2.2, 2.7, 3.05, 3.1, 3.4]
})

const out = {
  bloubCommit: execSync('git rev-parse HEAD', { cwd: root }).toString().trim(),
  scale: SCALE,
  cases: cases.map((c) => {
    const e = build(c)
    return { ...c, samples: c.times.map((t) => ({ t, frame: frame(e, t) })) }
  }),
  eyefit: SHAPES.flatMap((s: any) =>
    ids.flatMap((state) =>
      [null, ...EXPRESSIONS.map((x: any) => x.id)].map((expr) => {
        const o = decalageDesYeux(s.radii, state, expr)
        return { shape: s.id, state, expr, x: o.x, y: o.y }
      })
    )
  ),
  shapes: Object.fromEntries(SHAPES.map((s: any) => [s.id, s.radii])),
  profiles: PROFILES,
  seeds: { rings: RINGS, swoosh: SWOOSH, comet: COMET_RIBBONS },
  cycles: {
    minBlock: cycles.MIN_BLOCK,
    defaultCycle: cycles.defaultCycle().blocks,
    sequence: SEQUENCE,
    minDurations: Object.fromEntries(ids.map((id) => [id, cycles.minDurationOf(id)])),
    clamps: ids.flatMap((id) =>
      [0.1, 0.44, 0.65, 1.234, 2.05, 7.77, 12].map((v) => ({ state: id, seconds: v, result: cycles.clampDuration(id, v) }))
    ),
    blockAt: [-3.3, 0, 0.5, 2.4, 9.99, 17.2, 31.1, 64.8, 200.05].map((t) => {
      const r = cycles.blockAt(cycles.defaultCycle().blocks, t)
      return { t, index: r.index, elapsed: r.elapsed }
    })
  }
}
process.stdout.write(JSON.stringify(out))
"""#
}
#endif
