# RoutePool

RoutePool is a Flutter-based carpooling application designed to provide affordable, convenient, and environmentally friendly transportation in Penang, Malaysia.

The application connects passengers travelling in similar directions through intelligent ride matching, allowing them to share rides and split fares. Built with Flutter and Firebase, RoutePool features real-time GPS tracking, route optimization, automated fare calculation, driver verification, wallet management, and safety features to improve the overall carpooling experience.

## Key Features

- **Intelligent Ride Matching:** Matches passengers travelling along similar routes.
- **Real-Time GPS Tracking:** Allows passengers and drivers to monitor active trips.
- **Public Trip Sharing:** Generates temporary tracking links for trusted recipients.
- **Route Optimization:** Improves route planning and passenger pickup/drop-off sequences.
- **Automated Fare Calculation:** Calculates and splits fares between passengers.
- **Driver Verification:** Supports identity and vehicle document verification.
- **Wallet Management:** Provides wallet and transaction management.
- **Safety Features:** Includes emergency assistance and trip monitoring.
- **Ride History and Reviews:** Allows passengers to view completed trips and review drivers.

## Public Live Trip Links

Live trip sharing uses Firebase Hosting and Cloud Functions. The tracking site is hosted separately and does not require the Flutter web build.

Deploy the relevant Firebase services using:

```powershell
firebase deploy --only functions,hosting
```

The share sheet creates a 256-bit random token for an active trip. Firestore stores only its SHA-256 hash. The link expires after two hours and stops working as soon as the trip ends.

Anyone with the link can see the driver's recent location and active destinations, so share it only with trusted recipients. Passenger live locations are not included.

## Ride Completion and Cancellation

Drivers can cancel an assigned trip before it starts; its passenger bookings return to driver matching.

During an active trip, the driver confirms each passenger's drop-off in route order. Confirming the final drop-off completes the trip and makes eligible passengers available to review the driver. There is no separate End Ride action.

## Getting Started

To get started with Flutter development, refer to these resources:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)
- [Flutter documentation](https://docs.flutter.dev/)