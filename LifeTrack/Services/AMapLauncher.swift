import Foundation
import CoreLocation
import UIKit

enum AMapLauncher {
    static func canOpen() -> Bool {
        guard let url = URL(string: "iosamap://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func openRoutePlan(to coordinate: CLLocationCoordinate2D, name: String, mode: RouteMode = .driving) {
        var components = URLComponents()
        components.scheme = "iosamap"
        components.host = "path"
        components.queryItems = [
            URLQueryItem(name: "sourceApplication", value: "LifeTrack"),
            URLQueryItem(name: "dlat", value: String(coordinate.latitude)),
            URLQueryItem(name: "dlon", value: String(coordinate.longitude)),
            URLQueryItem(name: "dname", value: name),
            URLQueryItem(name: "dev", value: "0"),
            URLQueryItem(name: "t", value: mode.rawValue),
            URLQueryItem(name: "m", value: "0")
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    static func openNavigation(to coordinate: CLLocationCoordinate2D, name: String) {
        openRoutePlan(to: coordinate, name: name)
    }

    enum RouteMode: String {
        case driving = "0"
        case transit = "1"
        case walking = "2"
        case cycling = "3"
    }
}
