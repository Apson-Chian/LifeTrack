import Foundation
import CoreLocation
import UIKit

enum AMapLauncher {
    static func canOpen() -> Bool {
        guard let url = URL(string: "iosamap://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func openNavigation(to coordinate: CLLocationCoordinate2D, name: String, style: NavigationStyle = .fastest) {
        var components = URLComponents()
        components.scheme = "iosamap"
        components.host = "navi"
        components.queryItems = [
            URLQueryItem(name: "sourceApplication", value: "LifeTrack"),
            URLQueryItem(name: "poiname", value: name),
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "dev", value: "0"),
            URLQueryItem(name: "style", value: style.rawValue)
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    enum NavigationStyle: String {
        case fastest = "0"
        case shortest = "2"
        case avoidCongestion = "4"
    }
}
