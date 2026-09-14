import Testing
@testable import SpatialPlanner

@Suite struct RenderPlannerTests {
    // Speakers 2 m apart on the x axis; the listener sits at z > 0 facing -z toward them.
    let speakers = [Vec2(-1, 0), Vec2(1, 0)]

    func plan(_ planner: inout RenderPlanner, phone: Vec2, forward: Vec2? = nil, locked: Bool = true,
              time: Double = 0) -> RenderPlan {
        planner.plan(speakers: speakers, phone: phone, forward: forward, locked: locked, time: time)
    }

    @Test func centeredListenerIsNeutral() {
        var planner = RenderPlanner()
        let p = plan(&planner, phone: Vec2(0, 2))
        #expect(abs(p.speakers[0].delaySeconds) < 1e-9)
        #expect(abs(p.speakers[1].delaySeconds) < 1e-9)
        #expect(p.speakers[0].gain == 1 && p.speakers[1].gain == 1)
        #expect(p.assignment == .stereo(leftSpeaker: 0))
    }

    @Test func offCenterListenerAlignsArrivals() {
        var planner = RenderPlanner()
        let p = plan(&planner, phone: Vec2(-0.8, 1.5))
        let head = p.head!
        let rA = (speakers[0] - head).length, rB = (speakers[1] - head).length
        // Arrival = travel + delay must match for both speakers.
        let arrivalA = rA / 343 + p.speakers[0].delaySeconds
        let arrivalB = rB / 343 + p.speakers[1].delaySeconds
        #expect(abs(arrivalA - arrivalB) < 1e-9)
        #expect(p.speakers[0].delaySeconds > 0 && p.speakers[1].delaySeconds == 0)
        #expect(p.speakers[0].gain < 1 && p.speakers[1].gain == 1)
        #expect(abs(p.speakers[0].gain - rA / rB) < 1e-9)
    }

    @Test func handHeldPhoneOffsetsHeadBehindPhone() {
        var planner = RenderPlanner()
        let p = plan(&planner, phone: Vec2(0, 2), forward: Vec2(0, -1), locked: false)
        #expect(abs(p.head!.z - 2.35) < 1e-9)
    }

    @Test func turningAroundSwapsChannels() {
        var planner = RenderPlanner()
        #expect(plan(&planner, phone: Vec2(0, 2), forward: Vec2(0, -1), time: 0).assignment == .stereo(leftSpeaker: 0))
        let behind = plan(&planner, phone: Vec2(0, 2), forward: Vec2(0, 1), time: 0.1)
        #expect(behind.assignment == .stereo(leftSpeaker: 1))
        #expect(behind.speakers[1].channel == 0 && behind.speakers[0].channel == 1)
    }

    @Test func standingOnSpeakerAxisGoesMonoWithHysteresis() {
        var planner = RenderPlanner()
        // Far down the x axis, both speakers appear in the same direction.
        let onAxis = plan(&planner, phone: Vec2(6, 0.2), time: 0)
        #expect(onAxis.assignment == .mono)
        #expect(onAxis.speakers.allSatisfy { $0.channel == nil })
        // Slightly off-axis stays mono until the exit threshold is crossed.
        #expect(plan(&planner, phone: Vec2(6, 1.2), time: 5).assignment == .mono)
        #expect(plan(&planner, phone: Vec2(0, 2), time: 10).assignment == .stereo(leftSpeaker: 0))
    }

    @Test func noListenerKeepsNeutralRouting() {
        var planner = RenderPlanner()
        let p = planner.plan(speakers: speakers, phone: nil, forward: nil, locked: false, time: 0)
        #expect(p.speakers.map(\.delaySeconds) == [0, 0])
        #expect(p.speakers[0].channel == 0)
    }

    @Test func oneEuroSmoothsJitterButFollowsMotion() {
        var filter = OneEuroFilter()
        var t = 0.0
        var out = 0.0
        for i in 0..<200 {
            out = filter.filter(i % 2 == 0 ? 0.02 : -0.02, time: t)
            t += 1 / 30
        }
        #expect(abs(out) < 0.01)
        for _ in 0..<60 {
            out = filter.filter(1.0, time: t)
            t += 1 / 30
        }
        #expect(out > 0.95)
    }
}
