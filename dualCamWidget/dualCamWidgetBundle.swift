import WidgetKit
import SwiftUI

@main
struct dualCamWidgetBundle: WidgetBundle {
    var body: some Widget {
        dualCamWidgetLiveActivity()
        DualCamControl()
        DualCamCircularWidget()
        DualCamRectangularWidget()
    }
}
