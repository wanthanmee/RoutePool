# rp_login_signup

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Public live trip links

Live trip sharing uses Firebase Hosting and Cloud Functions. The tracking site is hosted separately and does not require the Flutter web build.

```powershell
firebase deploy --only functions,hosting
```

The share sheet creates a 256-bit random token for an active trip. Firestore stores only its SHA-256 hash; the link expires after two hours and stops working as soon as the trip ends. Anyone with the link can see the driver's recent location and active destinations, so share it only with trusted recipients. Passenger live locations are not included.

## Ride completion and cancellation

Drivers can cancel an assigned trip before it starts; its passenger bookings return to driver matching. During an active trip, the driver confirms each passenger's drop-off in route order. Confirming the final drop-off completes the trip and makes eligible passengers available to review the driver, so there is no separate End Ride action.
