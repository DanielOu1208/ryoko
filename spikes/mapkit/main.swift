// D1 MapKit spike: what MapKit returns for Shanghai and Tokyo from outside CN/JP.
// Build: ./run.sh   (output goes to spikes/mapkit/out/, which is gitignored; never commit it)
import Foundation
import MapKit
import CoreLocation

func hasCJK(_ s: String?) -> Bool {
    guard let s else { return false }
    return s.unicodeScalars.contains { v in
        (0x4E00...0x9FFF).contains(v.value) || (0x3400...0x4DBF).contains(v.value) ||
        (0x3040...0x30FF).contains(v.value) || (0xF900...0xFAFF).contains(v.value) ||
        (0x20000...0x2A6DF).contains(v.value)
    }
}

func dump(_ item: MKMapItem, _ idx: Int, origin: CLLocation? = nil) {
    let c = item.location.coordinate
    var dist = ""
    if let origin { dist = String(format: " dist=%.0fm", item.location.distance(from: origin)) }
    print("  [\(idx)] name=\(item.name ?? "nil")  cjk=\(hasCJK(item.name))")
    print("      id=\(item.identifier?.rawValue ?? "nil")  altIds=\(item.alternateIdentifiers.count)")
    print("      cat=\(item.pointOfInterestCategory?.rawValue ?? "nil")  tz=\(item.timeZone?.identifier ?? "nil")")
    print(String(format: "      coord=%.6f,%.6f", c.latitude, c.longitude) + dist)
    print("      address.full=\(item.address?.fullAddress.replacingOccurrences(of: "\n", with: " | ") ?? "nil")  cjk=\(hasCJK(item.address?.fullAddress))")
    print("      address.short=\(item.address?.shortAddress ?? "nil")")
    if let r = item.addressRepresentations {
        print("      rep.full(singleLine)=\(r.fullAddress(includingRegion: true, singleLine: true) ?? "nil")")
        print("      rep.city=\(r.cityName ?? "nil")  cityCtx=\(r.cityWithContext ?? "nil")  region=\(r.regionName ?? "nil")/\(r.region?.identifier ?? "nil")")
    } else {
        print("      rep=nil")
    }
}

func region(_ c: CLLocationCoordinate2D, meters: Double) -> MKCoordinateRegion {
    MKCoordinateRegion(center: c, latitudinalMeters: meters, longitudinalMeters: meters)
}

func search(_ q: String, center: CLLocationCoordinate2D, meters: Double = 2000, required: Bool = true, poiOnly: Bool = true, show: Int = 8) async -> [MKMapItem] {
    let req = MKLocalSearch.Request()
    req.naturalLanguageQuery = q
    req.region = region(center, meters: meters)
    req.regionPriority = required ? .required : .default
    req.resultTypes = poiOnly ? .pointOfInterest : [.pointOfInterest, .address]
    print("\n== MKLocalSearch \"\(q)\" (\(Int(meters)) m, \(required ? "required" : "default"), \(poiOnly ? "POI" : "POI+address"))")
    do {
        let items = try await MKLocalSearch(request: req).start().mapItems
        print("  count=\(items.count)")
        let o = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for (i, it) in items.prefix(show).enumerated() { dump(it, i, origin: o) }
        return items
    } catch { print("  ERROR \(error)"); return [] }
}

func pois(center: CLLocationCoordinate2D, radius: Double, filter: MKPointOfInterestFilter? = nil, label: String, show: Int = 8) async {
    let req = MKLocalPointsOfInterestRequest(center: center, radius: radius)
    req.pointOfInterestFilter = filter
    print("\n== POI request \(label) r=\(Int(radius)) m")
    do {
        let items = try await MKLocalSearch(request: req).start().mapItems
        let cjk = items.filter { hasCJK($0.name) }.count
        let tz = Set(items.compactMap { $0.timeZone?.identifier })
        let ids = items.filter { $0.identifier != nil }.count
        print("  count=\(items.count) cjkNames=\(cjk) withId=\(ids) tzs=\(tz)")
        let o = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for (i, it) in items.prefix(show).enumerated() { dump(it, i, origin: o) }
    } catch { print("  ERROR \(error)") }
}

func reverse(_ loc: CLLocation, locale: String) async {
    print("\n== MKReverseGeocodingRequest preferredLocale=\(locale)")
    guard let req = MKReverseGeocodingRequest(location: loc) else { print("  init returned nil"); return }
    req.preferredLocale = Locale(identifier: locale)
    do {
        let items = try await req.mapItems
        print("  count=\(items.count)")
        for (i, it) in items.prefix(3).enumerated() { dump(it, i) }
    } catch { print("  ERROR \(error)") }
}

let args = CommandLine.arguments
let namesOnly = args.contains("--names-only")
print("preferredLanguages=\(Locale.preferredLanguages)  current=\(Locale.current.identifier)")

let jingan = CLLocationCoordinate2D(latitude: 31.2235, longitude: 121.4453)
let shinjuku = CLLocationCoordinate2D(latitude: 35.6896, longitude: 139.7006)

if let i = args.firstIndex(of: "--city"), i + 1 < args.count {
    // Follow-up: Taipei and Hong Kong. Throttle-friendly: pause between requests.
    struct Center { let name: String; let c: CLLocationCoordinate2D }
    let city = args[i + 1]
    var centers: [Center] = []
    var queries = ["50嵐", "50 Lan", "CoCo", "Starbucks", "星巴克", "bubble tea", "Heytea", "喜茶"]
    var locales = ["zh_Hant_TW", "en_US"]
    if city == "taipei" {
        centers = [Center(name: "Ximending", c: .init(latitude: 25.0422, longitude: 121.5079)),
                   Center(name: "Taipei 101", c: .init(latitude: 25.0340, longitude: 121.5645))]
    } else {
        centers = [Center(name: "Mong Kok", c: .init(latitude: 22.3193, longitude: 114.1694)),
                   Center(name: "Central", c: .init(latitude: 22.2819, longitude: 114.1580))]
        queries += ["Tsui Wah", "翠華"]
        locales = ["zh_Hant_HK", "en_US"]
    }
    func pause() async { try? await Task.sleep(nanoseconds: 1_400_000_000) }
    for ctr in centers {
        print("\n######## \(city.uppercased()) / \(ctr.name)")
        var teaHit: MKMapItem?
        for q in queries {
            let r = await search(q, center: ctr.c, show: 4)
            let o = CLLocation(latitude: ctr.c.latitude, longitude: ctr.c.longitude)
            print("  SUMMARY q=\(q) count=\(r.count) cjk=\(r.filter { hasCJK($0.name) }.count) within2km=\(r.filter { $0.location.distance(from: o) < 2000 }.count)")
            if teaHit == nil, ["50嵐", "50 Lan", "CoCo", "bubble tea", "Heytea", "喜茶"].contains(q), let f = r.first { teaHit = f }
            await pause()
        }
        await pois(center: ctr.c, radius: 150, label: "all", show: 6); await pause()
        await pois(center: ctr.c, radius: 300, label: "all", show: 0); await pause()
        let target = teaHit?.location ?? CLLocation(latitude: ctr.c.latitude, longitude: ctr.c.longitude)
        print("\n(reverse geocoding \(teaHit?.name ?? "the centre"))")
        for l in locales { await reverse(target, locale: l); await pause() }
        await pois(center: ctr.c, radius: 300, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom", show: 2); await pause()
        await pois(center: ctr.c, radius: 1500, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom", show: 0); await pause()
    }
    exit(0)
}
if args.contains("--set-before") {
    // Set the language in code before the first MapKit call (what an app could do at launch).
    UserDefaults.standard.set(["ja"], forKey: "AppleLanguages")
    print("set before first request: preferredLanguages=\(Locale.preferredLanguages)")
    _ = await search("Ichiran", center: shinjuku, show: 1)
    exit(0)
}
if args.contains("--switch") {
    // Can a running app flip the language for MapKit requests at runtime, or by re-fetching by identifier?
    let first = await search("Ichiran", center: shinjuku, show: 1)
    UserDefaults.standard.set(["ja"], forKey: "AppleLanguages")
    print("\nafter runtime set: preferredLanguages=\(Locale.preferredLanguages)")
    _ = await search("Ichiran", center: shinjuku, show: 1)
    if let id = first.first?.identifier {
        print("\n== MKMapItemRequest(mapItemIdentifier:) refetch")
        do { let it = try await MKMapItemRequest(mapItemIdentifier: id).mapItem; dump(it, 0) } catch { print("  ERROR \(error)") }
    }
    exit(0)
}

print("\n######## SHANGHAI (Jing'an Temple)")
var heytea = await search("Heytea", center: jingan)
_ = await search("喜茶", center: jingan)
if args.contains("--probe") {
    // Why does the Shanghai name search fail? Vary priority, size, result types and query.
    for (q, m, req, poi) in [("Heytea", 2000.0, false, true), ("Heytea", 5000.0, true, true), ("Heytea", 10000.0, false, false),
                            ("喜茶", 5000.0, false, false), ("HEYTEA 喜茶", 3000.0, false, true), ("喜茶 静安", 3000.0, false, false),
                            ("Starbucks", 2000.0, true, true), ("星巴克", 2000.0, true, true), ("coffee", 2000.0, true, true),
                            ("Jing'an Temple", 3000.0, false, false), ("静安寺", 3000.0, false, false), ("restaurant", 2000.0, true, true)] {
        let r = await search(q, center: jingan, meters: m, required: req, poiOnly: poi, show: 3)
        if heytea.isEmpty, (q.contains("Heytea") || q.contains("喜茶")), let f = r.first(where: { $0.addressRepresentations?.region?.identifier == "CN" && $0.location.distance(from: CLLocation(latitude: jingan.latitude, longitude: jingan.longitude)) < 5000 }) { heytea = [f] }
    }
}
if !namesOnly {
    await pois(center: jingan, radius: 300, label: "all")
    if let first = heytea.first {
        await reverse(first.location, locale: "zh_Hans_CN")
        await reverse(first.location, locale: "en_US")
    } else {
        print("\n(no Shanghai Heytea hit)")
    }
    // Always also reverse geocode the Jing'an Temple centre and the first nearby Starbucks.
    print("\n(reverse geocoding the Jing'an Temple centre)")
    let l = CLLocation(latitude: jingan.latitude, longitude: jingan.longitude)
    await reverse(l, locale: "zh_Hans_CN")
    await reverse(l, locale: "en_US")
    if let sb = await search("Starbucks", center: jingan, show: 1).first {
        print("\n(reverse geocoding the first Starbucks hit)")
        await reverse(sb.location, locale: "zh_Hans_CN")
        await reverse(sb.location, locale: "en_US")
    }
    await pois(center: jingan, radius: 300, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom")
    await pois(center: jingan, radius: 1500, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom")
}

print("\n######## TOKYO (Shinjuku Station)")
_ = await search("Ichiran", center: shinjuku)
_ = await search("一蘭", center: shinjuku)
let ramen = await search("ramen", center: shinjuku)
if !namesOnly {
    await pois(center: shinjuku, radius: 300, label: "all")
    if let first = ramen.first {
        await reverse(first.location, locale: "ja_JP")
        await reverse(first.location, locale: "en_US")
    }
    await pois(center: shinjuku, radius: 300, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom")
    await pois(center: shinjuku, radius: 1500, filter: MKPointOfInterestFilter(including: [.restroom]), label: "restroom")
}
print("\nDONE")
