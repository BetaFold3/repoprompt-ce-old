import Charts
import SwiftUI

/// Native line/bar chart for rich presentations (rich presentation spec, A2/A6). Not yet wired into
/// the transcript. Line charts plot real instants on a UTC-labeled time axis and break lines at
/// missing values; bar charts group series by category on a zero baseline. One unit, linear scale.
struct RichPresentationChartView: View {
    enum Content: Equatable {
        /// `x` instants are strictly increasing; each series' `y` has one value per instant.
        case line(x: [Date], series: [Series])
        /// `x` categories are unique and in display order; each series' `y` has one value per category.
        case bar(x: [String], series: [Series])
    }

    struct Series: Equatable {
        let name: String
        let y: [Double?]
    }

    let content: Content
    let xLabel: String
    let unit: String

    private struct LinePoint: Identifiable {
        let id: String
        let series: String
        let segment: String
        let x: Date
        let y: Double
    }

    private struct BarPoint: Identifiable {
        let id: String
        let series: String
        let x: String
        let y: Double
    }

    var body: some View {
        chart
            .chartYAxisLabel(unit)
            .chartLegend(.visible)
            .frame(height: 300)
    }

    @ViewBuilder
    private var chart: some View {
        switch content {
        case let .line(x, series):
            Chart(Self.linePoints(x: x, series: series)) { point in
                LineMark(
                    x: .value(xLabel, point.x),
                    y: .value(unit, point.y),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(by: .value("Series", point.series))
                PointMark(x: .value(xLabel, point.x), y: .value(unit, point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .symbolSize(16)
                    .accessibilityLabel(point.series)
                    .accessibilityValue("\(point.x.formatted(Self.utcAxisFormat)) UTC: \(point.y.formatted()) \(unit)")
            }
            .chartXAxisLabel("\(xLabel) (UTC)")
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: Self.utcAxisFormat)
                }
            }
        case let .bar(x, series):
            Chart(Self.barPoints(x: x, series: series)) { point in
                BarMark(x: .value(xLabel, point.x), y: .value(unit, point.y))
                    .position(by: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .accessibilityLabel(point.series)
                    .accessibilityValue("\(point.x): \(point.y.formatted()) \(unit)")
            }
            .chartXAxisLabel(xLabel)
            .chartXScale(domain: x)
        }
    }

    private static let utcAxisFormat: Date.FormatStyle = {
        // The year keeps series that span years unambiguous.
        var style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute()
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return style
    }()

    /// Splits each series into contiguous non-null segments so a missing value breaks the line.
    private static func linePoints(x: [Date], series: [Series]) -> [LinePoint] {
        var points: [LinePoint] = []
        for (seriesIndex, item) in series.enumerated() {
            var segment = 0
            for (index, date) in x.enumerated() {
                guard index < item.y.count, let value = item.y[index] else {
                    segment += 1
                    continue
                }
                points.append(LinePoint(
                    id: "\(seriesIndex)-\(index)",
                    series: item.name,
                    segment: "\(seriesIndex)-\(segment)",
                    x: date,
                    y: value
                ))
            }
        }
        return points
    }

    private static func barPoints(x: [String], series: [Series]) -> [BarPoint] {
        var points: [BarPoint] = []
        for (seriesIndex, item) in series.enumerated() {
            for (index, category) in x.enumerated() {
                guard index < item.y.count, let value = item.y[index] else { continue }
                points.append(BarPoint(id: "\(seriesIndex)-\(index)", series: item.name, x: category, y: value))
            }
        }
        return points
    }
}
