import SwiftUI

#if arch(arm64)
/// The equalizer row shown while a workspace is prepared.
///
/// The lit blocks are the real progress — they advance from left to right as the
/// download and install run — and their heights bounce in real time like a
/// player's level meter, with the block at the frontier moving the most. Motion
/// stops when the window is in the background, and `Reduce Motion` renders the
/// settled row instead of an arbitrary frame.
struct CreateProgressMeter: View {
    let progress: Double
    let isOmarchy: Bool
    let isActive: Bool
    /// The workspace is ready: hold the finished row still while it fades.
    var isSettled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool { isActive && !isSettled && !reduceMotion && scenePhase == .active }

    /// Fire for Omarchy, ice for macOS, matching the workspace cards.
    private var accent: Color {
        isOmarchy
            ? Color(red: 1.0, green: 0.42, blue: 0.17)
            : Color(red: 0.42, green: 0.78, blue: 1.0)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            // Freezing the clock keeps the paused frame reproducible instead of
            // catching the bars mid-flight.
            let time = animates ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .bottom, spacing: VMCreateProgressMeterGeometry.gap) {
                ForEach(0 ..< VMCreateProgressMeterGeometry.barCount, id: \.self) { index in
                    let height = isSettled || !animates
                        ? VMCreateProgressMeterGeometry.restingHeight(
                            index: index, progress: progress, isReady: isSettled
                          )
                        : VMCreateProgressMeterGeometry.height(index: index, progress: progress, time: time)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(VMCreateProgressMeterGeometry.isLit(index: index, progress: progress)
                              ? accent
                              : Color(nsColor: .quaternaryLabelColor))
                        .frame(width: VMCreateProgressMeterGeometry.barWidth, height: height)
                        .opacity(VMCreateProgressMeterGeometry.isLit(index: index, progress: progress) ? 0.95 : 0.7)
                }
            }
            .frame(height: VMCreateProgressMeterGeometry.maximumHeight, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .offset(y: VMCreateProgressMeterGeometry.gap / 2)
            }
            .padding(.bottom, VMCreateProgressMeterGeometry.gap)
        }
        .frame(height: VMCreateProgressMeterGeometry.rowHeight)
        .accessibilityHidden(true)
    }
}
#endif
