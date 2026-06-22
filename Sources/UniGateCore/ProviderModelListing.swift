import Foundation

public enum ProviderModelListing {
    public static func routeKeys(from catalog: ProviderCatalog, appType: String) -> [ModelRouteKey] {
        catalog.routeKeys.filter { $0.appType == appType }
    }
}
